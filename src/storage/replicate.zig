//! Shipping a database's changes to somewhere else, one pass at a time.
//!
//! A pass copies whatever write-ahead log frames have appeared since the last
//! one into a destination directory. Run it on a timer and the destination
//! trails the database by however long the gap is.
//!
//! ## Generations
//!
//! Frame numbering restarts whenever the log is truncated, which happens on
//! every checkpoint. Frame 40 before a checkpoint and frame 40 after it are
//! different records, so a follower that keeps counting would ship the second
//! believing it had the first. Everything between two truncations is therefore a
//! **generation**: it opens with a full snapshot of the database and continues as
//! a run of frames.
//!
//! The database file header carries `checkpoint_seq`, which advances every time
//! the log is reset and is made durable before the reset happens. That is the
//! generation boundary, so a pass that finds a different value than the one
//! recorded at the destination knows to start over from a fresh snapshot.
//!
//! It has to live in the database file rather than the log, because the log is
//! precisely what a reset throws away, and because a follower has to survive the
//! writer process restarting. That second case is not hypothetical: closing a
//! database checkpoints it, so two runs of a command-line tool can fold an
//! arbitrary amount of change into the database file leaving no trace in the log
//! at all. A signal read out of the log would see an empty log both times and
//! conclude, wrongly, that nothing had happened.
//!
//! Frame zero's checksum is recorded as well and checked alongside it. The
//! counter is the authority; the fingerprint is a second opinion that costs one
//! read and catches a destination paired with the wrong database file.
//!
//! ## Why the snapshot is taken from inside the process
//!
//! A snapshot has to be consistent, which means no writes may land while it is
//! read. There is no cross-process locking, so a separate replicator process
//! cannot arrange that. `Database.backup` can, because it runs on the handle that
//! owns the database, so replication is a method on the database rather than an
//! outside observer.
//!
//! ## Layout
//!
//! ```text
//! <dest>/manifest.json
//! <dest>/gen-0000000001/snapshot.lattice
//! <dest>/gen-0000000001/frames/0000000000-0000000063.frames
//! ```
//!
//! Frames are batched into segment files rather than written one per file.

const std = @import("std");
const wal_mod = @import("wal.zig");
const wal_reader_mod = @import("wal_reader.zig");
const vfs_mod = @import("vfs.zig");

pub const ReplicateError = error{
    /// The destination belongs to a different database.
    UuidMismatch,
    /// The destination holds a manifest this build does not understand.
    UnsupportedManifest,
    /// The database has no write-ahead log, so there is nothing to follow.
    NoWal,
    IoError,
    OutOfMemory,
};

pub const MANIFEST_VERSION: u32 = 1;

/// What the destination knows about the database it is following.
pub const Manifest = struct {
    version: u32 = MANIFEST_VERSION,
    /// Hex of the database UUID, so a destination cannot be pointed at the
    /// wrong database without it being noticed.
    database_uuid: [32]u8,
    /// Which generation the destination is currently holding.
    generation: u64,
    /// Frames of that generation already shipped.
    frames_shipped: u64,
    /// Checksum of frame zero when the generation opened, used to notice a
    /// truncation that the frame count alone would hide.
    generation_fingerprint: u32,
    /// Whether a fingerprint was actually captured. A generation that opened
    /// with an empty log has nothing to fingerprint yet.
    has_fingerprint: bool,
    /// The database's reset counter when the generation opened. A different
    /// value means the log has been reset since, so frame numbers from before
    /// no longer refer to the same records.
    checkpoint_seq: u32,
};

/// What one pass did.
pub const ReplicateStats = struct {
    /// Generation the destination is on after this pass.
    generation: u64,
    /// True if this pass opened a new generation and wrote a snapshot.
    started_generation: bool,
    /// Frames copied during this pass.
    frames_shipped: u64,
    /// Bytes of frame data written.
    bytes_shipped: u64,
    /// Bytes of snapshot written, zero unless a generation opened.
    snapshot_bytes: u64,
    duration_ns: u64,
};

fn uuidToHex(uuid: [16]u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{uuid}) catch {
        // The buffer is exactly the right size, so this cannot fail; fall back
        // to zeroes rather than propagating an impossible error.
        @memset(&out, '0');
    };
    return out;
}

/// Read the manifest at `dest_dir`, or null if the destination is empty.
pub fn readManifest(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
) ReplicateError!?Manifest {
    const path = std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dest_dir}) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(path);

    const file = @import("compat").fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    var buf: [1024]u8 = undefined;
    const read = file.preadAll(&buf, 0) catch return ReplicateError.IoError;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, buf[0..read], .{}) catch {
        return ReplicateError.UnsupportedManifest;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return ReplicateError.UnsupportedManifest,
    };

    const version = switch (root.get("version") orelse return ReplicateError.UnsupportedManifest) {
        .integer => |v| @as(u32, @intCast(v)),
        else => return ReplicateError.UnsupportedManifest,
    };
    if (version != MANIFEST_VERSION) return ReplicateError.UnsupportedManifest;

    var manifest = Manifest{
        .database_uuid = undefined,
        .generation = 0,
        .frames_shipped = 0,
        .generation_fingerprint = 0,
        .has_fingerprint = false,
        .checkpoint_seq = 0,
    };

    const uuid_value = switch (root.get("database_uuid") orelse return ReplicateError.UnsupportedManifest) {
        .string => |v| v,
        else => return ReplicateError.UnsupportedManifest,
    };
    if (uuid_value.len != 32) return ReplicateError.UnsupportedManifest;
    @memcpy(&manifest.database_uuid, uuid_value[0..32]);

    manifest.generation = switch (root.get("generation") orelse return ReplicateError.UnsupportedManifest) {
        .integer => |v| @intCast(v),
        else => return ReplicateError.UnsupportedManifest,
    };
    manifest.frames_shipped = switch (root.get("frames_shipped") orelse return ReplicateError.UnsupportedManifest) {
        .integer => |v| @intCast(v),
        else => return ReplicateError.UnsupportedManifest,
    };
    manifest.generation_fingerprint = switch (root.get("generation_fingerprint") orelse std.json.Value{ .integer = 0 }) {
        .integer => |v| @intCast(v),
        else => 0,
    };
    manifest.has_fingerprint = switch (root.get("has_fingerprint") orelse std.json.Value{ .bool = false }) {
        .bool => |v| v,
        else => false,
    };
    manifest.checkpoint_seq = switch (root.get("checkpoint_seq") orelse return ReplicateError.UnsupportedManifest) {
        .integer => |v| @intCast(v),
        else => return ReplicateError.UnsupportedManifest,
    };

    return manifest;
}

fn writeManifest(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
    manifest: Manifest,
) ReplicateError!void {
    const body = std.fmt.allocPrint(allocator,
        \\{{
        \\  "version": {d},
        \\  "database_uuid": "{s}",
        \\  "generation": {d},
        \\  "frames_shipped": {d},
        \\  "generation_fingerprint": {d},
        \\  "has_fingerprint": {},
        \\  "checkpoint_seq": {d}
        \\}}
        \\
    , .{
        manifest.version,
        manifest.database_uuid,
        manifest.generation,
        manifest.frames_shipped,
        manifest.generation_fingerprint,
        manifest.has_fingerprint,
        manifest.checkpoint_seq,
    }) catch return ReplicateError.OutOfMemory;
    defer allocator.free(body);

    const temp_path = std.fmt.allocPrint(allocator, "{s}/manifest.json.partial", .{dest_dir}) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(temp_path);

    const final_path = std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dest_dir}) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(final_path);

    // The manifest is what makes everything else interpretable, so it is written
    // whole and moved into place rather than updated where it sits.
    {
        const file = @import("compat").fs.cwd().createFile(temp_path, .{ .truncate = true }) catch {
            return ReplicateError.IoError;
        };
        defer file.close();
        file.pwriteAll(body, 0) catch return ReplicateError.IoError;
        file.sync() catch return ReplicateError.IoError;
    }

    @import("compat").fs.cwd().rename(temp_path, final_path) catch return ReplicateError.IoError;
}

/// Decide whether the destination is still following the same generation.
fn sameGeneration(
    manifest: Manifest,
    checkpoint_seq: u32,
    reader: *wal_reader_mod.WalReader,
) bool {
    // The reset counter is the authority. It advances before the log is
    // truncated and lives in the database file, so it survives both the reset
    // itself and the writer process going away.
    if (checkpoint_seq != manifest.checkpoint_seq) return false;

    // Fewer frames than already shipped can only mean the log was reset.
    if (reader.frame_count < manifest.frames_shipped) return false;

    // Frame zero is a second opinion, and costs one read. It catches a
    // destination paired with a database whose counter happens to agree.
    if (!manifest.has_fingerprint) return true;
    if (reader.frame_count == 0) return true;

    const frame = reader.readFrame(0) catch return false;
    const header = std.mem.bytesAsValue(
        wal_mod.WalFrameHeader,
        frame.raw[0..@sizeOf(wal_mod.WalFrameHeader)],
    ).*;
    return header.checksum == manifest.generation_fingerprint;
}

fn fingerprintOf(reader: *wal_reader_mod.WalReader) ?u32 {
    if (reader.frame_count == 0) return null;
    const frame = reader.readFrame(0) catch return null;
    const header = std.mem.bytesAsValue(
        wal_mod.WalFrameHeader,
        frame.raw[0..@sizeOf(wal_mod.WalFrameHeader)],
    ).*;
    return header.checksum;
}

/// Copy frames `[from, to)` into one segment file under the generation.
fn shipSegment(
    allocator: std.mem.Allocator,
    reader: *wal_reader_mod.WalReader,
    gen_dir: []const u8,
    from: u64,
    to: u64,
) ReplicateError!u64 {
    const frames_dir = std.fmt.allocPrint(allocator, "{s}/frames", .{gen_dir}) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(frames_dir);
    @import("compat").fs.cwd().makePath(frames_dir) catch return ReplicateError.IoError;

    const segment_path = std.fmt.allocPrint(
        allocator,
        "{s}/{d:0>10}-{d:0>10}.frames",
        .{ frames_dir, from, to - 1 },
    ) catch return ReplicateError.OutOfMemory;
    defer allocator.free(segment_path);

    const temp_path = std.fmt.allocPrint(allocator, "{s}.partial", .{segment_path}) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(temp_path);

    var written: u64 = 0;
    {
        const file = @import("compat").fs.cwd().createFile(temp_path, .{ .truncate = true }) catch {
            return ReplicateError.IoError;
        };
        defer file.close();

        var n = from;
        while (n < to) : (n += 1) {
            // A frame caught mid-write fails its checksum and passes a moment
            // later, so a few attempts separate timing from damage.
            const frame = reader.readFrameRetrying(n, 4, 1_000_000) catch {
                return ReplicateError.IoError;
            };
            file.pwriteAll(frame.raw, written) catch return ReplicateError.IoError;
            written += frame.raw.len;
        }

        file.sync() catch return ReplicateError.IoError;
    }

    // A segment only becomes visible once every frame in it is on disk.
    @import("compat").fs.cwd().rename(temp_path, segment_path) catch return ReplicateError.IoError;
    return written;
}

/// Run one replication pass for `db` into `dest_dir`.
///
/// Takes a snapshot and opens a new generation when the destination is empty or
/// the log has been truncated since the last pass. Otherwise ships whatever
/// frames have appeared. Doing nothing is a normal outcome and not an error.
pub fn replicate(
    db: anytype,
    dest_dir: []const u8,
) ReplicateError!ReplicateStats {
    const allocator = db.allocator;
    const start_ns = @import("compat").nanoTimestamp();

    if (db.wal == null) return ReplicateError.NoWal;

    @import("compat").fs.cwd().makePath(dest_dir) catch return ReplicateError.IoError;

    const wal_path = std.fmt.allocPrint(allocator, "{s}-wal", .{db.path}) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(wal_path);

    var posix = vfs_mod.PosixVfs.init(allocator);
    const vfs = posix.vfs();

    var reader = wal_reader_mod.WalReader.open(allocator, vfs, wal_path, null) catch {
        return ReplicateError.IoError;
    };
    defer reader.close();

    const uuid_hex = uuidToHex(reader.database_uuid);
    const existing = try readManifest(allocator, dest_dir);

    if (existing) |m| {
        if (!std.mem.eql(u8, &m.database_uuid, &uuid_hex)) {
            return ReplicateError.UuidMismatch;
        }
    }

    var manifest = existing orelse Manifest{
        .database_uuid = uuid_hex,
        .generation = 0,
        .frames_shipped = 0,
        .generation_fingerprint = 0,
        .has_fingerprint = false,
        .checkpoint_seq = 0,
    };

    var stats = ReplicateStats{
        .generation = manifest.generation,
        .started_generation = false,
        .frames_shipped = 0,
        .bytes_shipped = 0,
        .snapshot_bytes = 0,
        .duration_ns = 0,
    };

    const continuing = existing != null and
        sameGeneration(manifest, db.page_manager.getHeader().checkpoint_seq, &reader);

    if (!continuing) {
        // Open a new generation: snapshot first, then treat everything already in
        // the log as covered by it, because the snapshot is taken after a full
        // checkpoint and so already contains those changes.
        manifest.generation = if (existing == null) 1 else manifest.generation + 1;
        manifest.database_uuid = uuid_hex;

        const gen_dir = std.fmt.allocPrint(
            allocator,
            "{s}/gen-{d:0>10}",
            .{ dest_dir, manifest.generation },
        ) catch return ReplicateError.OutOfMemory;
        defer allocator.free(gen_dir);
        @import("compat").fs.cwd().makePath(gen_dir) catch return ReplicateError.IoError;

        const snapshot_path = std.fmt.allocPrint(allocator, "{s}/snapshot.lattice", .{gen_dir}) catch {
            return ReplicateError.OutOfMemory;
        };
        defer allocator.free(snapshot_path);

        const backup_stats = db.backup(snapshot_path) catch return ReplicateError.IoError;
        stats.snapshot_bytes = backup_stats.bytes_copied;
        stats.started_generation = true;

        // The backup checkpointed, which may have published more frames.
        reader.refresh() catch {};

        manifest.frames_shipped = reader.frame_count;
        if (fingerprintOf(&reader)) |fp| {
            manifest.generation_fingerprint = fp;
            manifest.has_fingerprint = true;
        } else {
            manifest.generation_fingerprint = 0;
            manifest.has_fingerprint = false;
        }
    } else {
        reader.refresh() catch {};
    }

    stats.generation = manifest.generation;

    if (reader.frame_count > manifest.frames_shipped) {
        const gen_dir = std.fmt.allocPrint(
            allocator,
            "{s}/gen-{d:0>10}",
            .{ dest_dir, manifest.generation },
        ) catch return ReplicateError.OutOfMemory;
        defer allocator.free(gen_dir);

        const from = manifest.frames_shipped;
        const to = reader.frame_count;
        stats.bytes_shipped = try shipSegment(allocator, &reader, gen_dir, from, to);
        stats.frames_shipped = to - from;

        // Only claim the frames once the segment holding them is on disk.
        manifest.frames_shipped = to;

        if (!manifest.has_fingerprint) {
            if (fingerprintOf(&reader)) |fp| {
                manifest.generation_fingerprint = fp;
                manifest.has_fingerprint = true;
            }
        }
    }

    // Recorded last, because taking the snapshot resets the log and so advances
    // the counter. The next pass compares against the database as it stood at
    // the end of this one.
    manifest.checkpoint_seq = db.page_manager.getHeader().checkpoint_seq;

    try writeManifest(allocator, dest_dir, manifest);

    stats.duration_ns = @intCast(@import("compat").nanoTimestamp() - start_ns);
    return stats;
}
