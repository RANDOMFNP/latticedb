//! Rebuilding a database from what replication shipped.
//!
//! A destination holds, for each generation, a snapshot of the database taken
//! when the generation opened and the write-ahead log frames that arrived after
//! it. Restoring means putting those two things back together: copy the
//! snapshot, rebuild a log beside it out of the segments, and then open the
//! result so ordinary recovery replays them.
//!
//! Reusing recovery is deliberate. Replaying log records is subtle, and a
//! restore that reimplemented it would drift away from the real thing over time.
//! If recovery has a bug, restore should have the same bug rather than a
//! different one.
//!
//! ## Choosing a moment
//!
//! Each segment records when it was shipped and each generation records when its
//! snapshot was taken, so a restore can ask for a moment rather than only for
//! the newest state. The answer is the newest generation opened at or before the
//! target, plus every segment of it shipped at or before the target.
//!
//! The resolution is a replication pass, not a single write. Asking for 14:32
//! gives the state as of the last pass that finished at or before 14:32, so the
//! interval you replicate on is also the precision you can recover to. That is
//! worth saying plainly rather than implying a precision that is not there.

const std = @import("std");
const wal_mod = @import("wal.zig");
const replicate_mod = @import("replicate.zig");
const compat = @import("compat");

pub const RestoreError = error{
    /// The destination has no manifest, so there is nothing to restore from.
    NoBackup,
    /// The manifest is from a version this build does not understand.
    UnsupportedManifest,
    /// No generation had been taken yet at the requested moment.
    NothingAtThatTime,
    /// A snapshot or segment named by the manifest is missing or unreadable.
    MissingData,
    /// The output path already exists, and overwriting it was not asked for.
    OutputExists,
    IoError,
    OutOfMemory,
};

/// What a restore produced.
pub const RestoreStats = struct {
    /// Generation the restore came from.
    generation: u64,
    /// When that generation's snapshot was taken, in milliseconds.
    snapshot_at_ms: i64,
    /// Segments replayed on top of the snapshot.
    segments_applied: usize,
    /// Frames in those segments.
    frames_applied: u64,
    /// The moment the restored database actually corresponds to, which is when
    /// the last applied segment was shipped, or the snapshot if none applied.
    restored_to_ms: i64,
    /// Bytes written to the output path.
    bytes_written: u64,
    duration_ns: u64,
};

pub const Options = struct {
    /// Restore the state as of this moment, in milliseconds since the epoch.
    /// Null asks for the newest state available.
    at_ms: ?i64 = null,
    /// Replace the output path if something is already there.
    overwrite: bool = false,
};

fn copyFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
) RestoreError!u64 {
    const source = compat.fs.cwd().openFile(source_path, .{}) catch {
        return RestoreError.MissingData;
    };
    defer source.close();

    const dest = compat.fs.cwd().createFile(dest_path, .{ .truncate = true }) catch {
        return RestoreError.IoError;
    };
    defer dest.close();

    const buffer = allocator.alloc(u8, 1 << 20) catch return RestoreError.OutOfMemory;
    defer allocator.free(buffer);

    var offset: u64 = 0;
    while (true) {
        const read = source.preadAll(buffer, offset) catch return RestoreError.IoError;
        if (read == 0) break;
        dest.pwriteAll(buffer[0..read], offset) catch return RestoreError.IoError;
        offset += read;
        if (read < buffer.len) break;
    }

    dest.sync() catch return RestoreError.IoError;
    return offset;
}

/// Write a log header describing a log of `frame_count` frames.
///
/// Recovery replays everything from `checkpoint_lsn` onwards, and the snapshot
/// already holds everything up to the moment the generation opened. Setting the
/// checkpoint LSN to zero therefore replays exactly the shipped frames, which is
/// precisely what the snapshot is missing.
fn writeWalHeader(
    file: anytype,
    frame_size: u32,
    frame_count: u64,
    database_uuid: [16]u8,
) RestoreError!void {
    var header = wal_mod.WalHeader{
        .frame_size = frame_size,
        .database_uuid = database_uuid,
    };
    header.frame_count = frame_count;
    header.checkpoint_lsn = 0;
    header.checksum = header.calculateHeaderChecksum();

    var buffer: [wal_mod.WAL_HEADER_SIZE]u8 = undefined;
    @memset(&buffer, 0);
    const bytes = std.mem.asBytes(&header);
    @memcpy(buffer[0..bytes.len], bytes);

    file.pwriteAll(&buffer, 0) catch return RestoreError.IoError;
}

/// Read the database UUID out of a restored snapshot, so the rebuilt log can
/// claim to belong to it. A log whose UUID disagrees is refused on open, which
/// is the check that stops a log being replayed into the wrong database.
fn snapshotUuid(path: []const u8) RestoreError![16]u8 {
    const file = compat.fs.cwd().openFile(path, .{}) catch return RestoreError.MissingData;
    defer file.close();

    const page = @import("page.zig");
    var buffer: [@sizeOf(page.FileHeader)]u8 = undefined;
    const read = file.preadAll(&buffer, 0) catch return RestoreError.IoError;
    if (read != buffer.len) return RestoreError.MissingData;

    const header = std.mem.bytesAsValue(page.FileHeader, &buffer).*;
    return header.file_uuid;
}

/// Replay the rebuilt log into the database file and clear it.
fn foldInWal(allocator: std.mem.Allocator, output_path: []const u8) RestoreError!void {
    const database = @import("database.zig");

    const db = database.Database.open(allocator, output_path, .{}) catch {
        return RestoreError.MissingData;
    };
    defer db.close();

    _ = db.checkpoint(.truncate) catch return RestoreError.IoError;
}

/// Remove the log beside a restored database.
///
/// Once the log has been folded in it holds nothing but a header, and leaving it
/// there turns a restore into a pair of files somebody has to know to keep
/// together. The database recreates it when it is next opened.
fn removeWal(allocator: std.mem.Allocator, output_path: []const u8) void {
    const wal_path = std.fmt.allocPrint(allocator, "{s}-wal", .{output_path}) catch return;
    defer allocator.free(wal_path);
    compat.fs.cwd().deleteFile(wal_path) catch {};
}

/// Restore a database from `source_dir` to `output_path`.
///
/// The output is a complete database on its own once this returns. A log is
/// rebuilt beside it while the frames are replayed and then folded in, so
/// nothing is left for the caller to tidy up.
pub fn restore(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    output_path: []const u8,
    options: Options,
) RestoreError!RestoreStats {
    const start_ns = compat.nanoTimestamp();

    var manifest = (replicate_mod.readManifest(allocator, source_dir) catch |err| switch (err) {
        replicate_mod.ReplicateError.UnsupportedManifest => return RestoreError.UnsupportedManifest,
        replicate_mod.ReplicateError.OutOfMemory => return RestoreError.OutOfMemory,
        else => return RestoreError.IoError,
    }) orelse return RestoreError.NoBackup;
    defer manifest.deinit(allocator);

    const gen = manifest.generationFor(options.at_ms) orelse return RestoreError.NothingAtThatTime;

    if (!options.overwrite) {
        if (compat.fs.cwd().access(output_path, .{})) |_| {
            return RestoreError.OutputExists;
        } else |_| {}
    }

    const wal_path = std.fmt.allocPrint(allocator, "{s}-wal", .{output_path}) catch {
        return RestoreError.OutOfMemory;
    };
    defer allocator.free(wal_path);

    // Anything left over from an earlier attempt would be replayed into this
    // one, so it goes before the snapshot lands.
    compat.fs.cwd().deleteFile(wal_path) catch {};

    const snapshot_source = replicate_mod.snapshotPath(allocator, source_dir, gen.number) catch {
        return RestoreError.OutOfMemory;
    };
    defer allocator.free(snapshot_source);

    var stats = RestoreStats{
        .generation = gen.number,
        .snapshot_at_ms = gen.opened_at_ms,
        .segments_applied = 0,
        .frames_applied = 0,
        .restored_to_ms = gen.opened_at_ms,
        .bytes_written = try copyFile(allocator, snapshot_source, output_path),
        .duration_ns = 0,
    };

    // Segments are contiguous by construction, so applying them in order gives
    // an unbroken run of frames starting where the snapshot left off.
    var frames: u64 = 0;
    var applied: usize = 0;
    for (gen.segments) |seg| {
        if (options.at_ms) |target| {
            if (seg.shipped_at_ms > target) break;
        }
        frames += seg.to - seg.from;
        applied += 1;
        stats.restored_to_ms = seg.shipped_at_ms;
    }

    if (frames > 0) {
        const database_uuid = try snapshotUuid(output_path);

        const wal = compat.fs.cwd().createFile(wal_path, .{ .truncate = true }) catch {
            return RestoreError.IoError;
        };
        defer wal.close();

        // Frames are packed from position zero rather than kept at the numbers
        // they had in the original log. The first frame a generation ships is
        // rarely frame zero, and leaving a gap below it would mean a stretch of
        // empty positions that recovery would read, fail to checksum, and treat
        // as a damaged log. Recovery walks frames by position and never looks at
        // the number written inside one, so packing them costs nothing.
        const buffer = allocator.alloc(u8, manifest.frame_size) catch {
            return RestoreError.OutOfMemory;
        };
        defer allocator.free(buffer);

        var position: u64 = 0;
        for (gen.segments[0..applied]) |seg| {
            const seg_path = replicate_mod.segmentPath(
                allocator,
                source_dir,
                gen.number,
                seg.from,
                seg.to,
            ) catch return RestoreError.OutOfMemory;
            defer allocator.free(seg_path);

            const segment = compat.fs.cwd().openFile(seg_path, .{}) catch {
                return RestoreError.MissingData;
            };
            defer segment.close();

            var n = seg.from;
            while (n < seg.to) : (n += 1) {
                const at = (n - seg.from) * @as(u64, manifest.frame_size);
                const read = segment.preadAll(buffer, at) catch return RestoreError.IoError;
                if (read != buffer.len) return RestoreError.MissingData;

                const offset = wal_mod.WAL_HEADER_SIZE + position * @as(u64, manifest.frame_size);
                wal.pwriteAll(buffer, offset) catch return RestoreError.IoError;
                position += 1;
            }
        }

        // Written last, so the log only claims frames that are already on disk.
        try writeWalHeader(wal, manifest.frame_size, position, database_uuid);
        wal.sync() catch return RestoreError.IoError;
    }

    // Opening the database replays the log the ordinary way, and checkpointing
    // folds the result into the file and clears it. What the caller is left with
    // is one file they can copy, move, or open, rather than a pair they have to
    // keep together without being told so.
    try foldInWal(allocator, output_path);
    removeWal(allocator, output_path);

    stats.segments_applied = applied;
    stats.frames_applied = frames;
    stats.duration_ns = @intCast(compat.nanoTimestamp() - start_ns);
    return stats;
}
