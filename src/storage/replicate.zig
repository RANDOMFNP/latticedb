//! Shipping a database's changes to somewhere else, one pass at a time.
//!
//! A pass copies whatever write-ahead log frames have appeared since the last
//! one into a destination directory. Run it on a timer and the destination
//! trails the database by however long the gap is.
//!
//! ## Generations
//!
//! Frame numbering restarts whenever the log is reset, which happens on every
//! checkpoint that truncates. Frame 40 before a reset and frame 40 after it are
//! different records, so a follower that kept counting would ship the second
//! believing it had the first. Everything between two resets is therefore a
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
//! <dest>/gen-0000000001/frames/0000000012-0000000016.frames
//! ```
//!
//! Frames are batched into segment files rather than written one per file. Each
//! segment records the range it covers and when it was shipped, and each
//! generation records when its snapshot was taken. That is what lets a restore
//! ask for a moment in the past rather than only for the newest state.

const std = @import("std");
const wal_mod = @import("wal.zig");
const wal_reader_mod = @import("wal_reader.zig");
const vfs_mod = @import("vfs.zig");
const compat = @import("compat");

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

/// A run of frames shipped by one pass.
pub const Segment = struct {
    /// First frame in the segment.
    from: u64,
    /// One past the last frame, so `to - from` is how many it holds.
    to: u64,
    /// When the pass that wrote this finished, in milliseconds since the epoch.
    /// A restore can pick any moment, but what it lands on is the last pass at
    /// or before it, so the replication interval is the real precision.
    shipped_at_ms: i64,
    /// Size of the segment file.
    bytes: u64,
};

/// One span between two resets of the write-ahead log.
pub const Generation = struct {
    number: u64,
    /// The database's reset counter while this generation was current.
    checkpoint_seq: u32,
    /// When the snapshot was taken, in milliseconds since the epoch.
    opened_at_ms: i64,
    /// Frames already folded into the snapshot. Shipping starts here rather
    /// than at zero, because everything below it is in the snapshot already.
    snapshot_frames: u64,
    /// Frames of this generation shipped so far.
    frames_shipped: u64,
    /// Checksum of frame zero, used as a second opinion on identity.
    fingerprint: u32,
    /// Whether a fingerprint was captured. A generation that opened with an
    /// empty log has no frame zero to look at yet.
    has_fingerprint: bool,
    segments: []Segment,
};

/// What a destination holds.
pub const Manifest = struct {
    version: u32 = MANIFEST_VERSION,
    /// Hex of the database UUID, so a destination cannot be pointed at the
    /// wrong database without it being noticed.
    database_uuid: [32]u8,
    /// Frame size the log was written with, so a restore can rebuild a log
    /// header without needing the original database present.
    frame_size: u32,
    /// Every generation held here, oldest first. The last one is current.
    generations: []Generation,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        for (self.generations) |gen| allocator.free(gen.segments);
        allocator.free(self.generations);
        self.* = undefined;
    }

    /// The generation being shipped into right now.
    pub fn current(self: *const Manifest) ?*Generation {
        if (self.generations.len == 0) return null;
        return &self.generations[self.generations.len - 1];
    }

    /// The generation a restore should start from for a given moment, or the
    /// newest one when no moment is given.
    ///
    /// The right choice is the newest generation opened at or before the target.
    /// An older one does not carry the changes made since it was taken, and a
    /// newer one had not been taken yet.
    pub fn generationFor(self: *const Manifest, at_ms: ?i64) ?*const Generation {
        if (self.generations.len == 0) return null;
        const target = at_ms orelse return &self.generations[self.generations.len - 1];

        var chosen: ?*const Generation = null;
        for (self.generations) |*gen| {
            if (gen.opened_at_ms <= target) chosen = gen;
        }
        return chosen;
    }
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
        // The buffer is exactly the right size, so this cannot fail. Falling
        // back to zeroes beats propagating an error that cannot happen.
        @memset(&out, '0');
    };
    return out;
}

/// Build the path of a generation's directory.
pub fn generationDir(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
    generation: u64,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/gen-{d:0>10}", .{ dest_dir, generation });
}

/// Build the path of one segment file.
pub fn segmentPath(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
    generation: u64,
    from: u64,
    to: u64,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/gen-{d:0>10}/frames/{d:0>10}-{d:0>10}.frames",
        .{ dest_dir, generation, from, to - 1 },
    );
}

/// Build the path of a generation's snapshot.
pub fn snapshotPath(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
    generation: u64,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/gen-{d:0>10}/snapshot.lattice",
        .{ dest_dir, generation },
    );
}

fn objectField(obj: std.json.ObjectMap, name: []const u8) ReplicateError!std.json.Value {
    return obj.get(name) orelse ReplicateError.UnsupportedManifest;
}

fn intField(obj: std.json.ObjectMap, name: []const u8, comptime T: type) ReplicateError!T {
    return switch (try objectField(obj, name)) {
        .integer => |v| std.math.cast(T, v) orelse ReplicateError.UnsupportedManifest,
        else => ReplicateError.UnsupportedManifest,
    };
}

fn boolField(obj: std.json.ObjectMap, name: []const u8) ReplicateError!bool {
    return switch (try objectField(obj, name)) {
        .bool => |v| v,
        else => ReplicateError.UnsupportedManifest,
    };
}

/// Read the manifest at `dest_dir`, or null if the destination is empty.
///
/// The caller owns the result and must call `deinit` on it.
pub fn readManifest(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
) ReplicateError!?Manifest {
    const path = std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dest_dir}) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(path);

    const file = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const body = file.readToEndAlloc(allocator, 16 * 1024 * 1024) catch {
        return ReplicateError.IoError;
    };
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return ReplicateError.UnsupportedManifest;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return ReplicateError.UnsupportedManifest,
    };

    if (try intField(root, "version", u32) != MANIFEST_VERSION) {
        return ReplicateError.UnsupportedManifest;
    }

    var manifest = Manifest{
        .database_uuid = undefined,
        .frame_size = try intField(root, "frame_size", u32),
        .generations = &.{},
    };

    const uuid_value = switch (try objectField(root, "database_uuid")) {
        .string => |v| v,
        else => return ReplicateError.UnsupportedManifest,
    };
    if (uuid_value.len != 32) return ReplicateError.UnsupportedManifest;
    @memcpy(&manifest.database_uuid, uuid_value[0..32]);

    const gens_value = switch (try objectField(root, "generations")) {
        .array => |a| a,
        else => return ReplicateError.UnsupportedManifest,
    };

    const generations = allocator.alloc(Generation, gens_value.items.len) catch {
        return ReplicateError.OutOfMemory;
    };
    var built: usize = 0;
    errdefer {
        for (generations[0..built]) |gen| allocator.free(gen.segments);
        allocator.free(generations);
    }

    for (gens_value.items) |gen_value| {
        const gen_obj = switch (gen_value) {
            .object => |o| o,
            else => return ReplicateError.UnsupportedManifest,
        };

        const segs_value = switch (try objectField(gen_obj, "segments")) {
            .array => |a| a,
            else => return ReplicateError.UnsupportedManifest,
        };

        const segments = allocator.alloc(Segment, segs_value.items.len) catch {
            return ReplicateError.OutOfMemory;
        };
        errdefer allocator.free(segments);

        for (segs_value.items, 0..) |seg_value, i| {
            const seg_obj = switch (seg_value) {
                .object => |o| o,
                else => return ReplicateError.UnsupportedManifest,
            };
            segments[i] = .{
                .from = try intField(seg_obj, "from", u64),
                .to = try intField(seg_obj, "to", u64),
                .shipped_at_ms = try intField(seg_obj, "shipped_at_ms", i64),
                .bytes = try intField(seg_obj, "bytes", u64),
            };
        }

        generations[built] = .{
            .number = try intField(gen_obj, "generation", u64),
            .checkpoint_seq = try intField(gen_obj, "checkpoint_seq", u32),
            .opened_at_ms = try intField(gen_obj, "opened_at_ms", i64),
            .snapshot_frames = try intField(gen_obj, "snapshot_frames", u64),
            .frames_shipped = try intField(gen_obj, "frames_shipped", u64),
            .fingerprint = try intField(gen_obj, "fingerprint", u32),
            .has_fingerprint = try boolField(gen_obj, "has_fingerprint"),
            .segments = segments,
        };
        built += 1;
    }

    manifest.generations = generations;
    return manifest;
}

/// Append formatted text to a growing buffer.
///
/// The manifest is small and written all at once, so building it in memory and
/// then moving it into place as a whole is both simpler and what makes the write
/// atomic.
fn appendFmt(
    body: *std.array_list.Managed(u8),
    comptime fmt: []const u8,
    args: anytype,
) ReplicateError!void {
    const chunk = std.fmt.allocPrint(body.allocator, fmt, args) catch {
        return ReplicateError.OutOfMemory;
    };
    defer body.allocator.free(chunk);
    body.appendSlice(chunk) catch return ReplicateError.OutOfMemory;
}

fn writeManifest(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
    manifest: Manifest,
) ReplicateError!void {
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();

    try appendFmt(&body,
        \\{{
        \\  "version": {d},
        \\  "database_uuid": "{s}",
        \\  "frame_size": {d},
        \\  "generations": [
        \\
    , .{ manifest.version, manifest.database_uuid, manifest.frame_size });

    for (manifest.generations, 0..) |gen, gi| {
        try appendFmt(&body,
            \\    {{
            \\      "generation": {d},
            \\      "checkpoint_seq": {d},
            \\      "opened_at_ms": {d},
            \\      "snapshot_frames": {d},
            \\      "frames_shipped": {d},
            \\      "fingerprint": {d},
            \\      "has_fingerprint": {},
            \\      "segments": [
            \\
        , .{
            gen.number,
            gen.checkpoint_seq,
            gen.opened_at_ms,
            gen.snapshot_frames,
            gen.frames_shipped,
            gen.fingerprint,
            gen.has_fingerprint,
        });

        for (gen.segments, 0..) |seg, si| {
            try appendFmt(
                &body,
                "        {{\"from\": {d}, \"to\": {d}, \"shipped_at_ms\": {d}, \"bytes\": {d}}}{s}\n",
                .{
                    seg.from,
                    seg.to,
                    seg.shipped_at_ms,
                    seg.bytes,
                    if (si + 1 < gen.segments.len) "," else "",
                },
            );
        }

        try appendFmt(
            &body,
            "      ]\n    }}{s}\n",
            .{if (gi + 1 < manifest.generations.len) "," else ""},
        );
    }

    body.appendSlice("  ]\n}\n") catch return ReplicateError.OutOfMemory;

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
        const file = compat.fs.cwd().createFile(temp_path, .{ .truncate = true }) catch {
            return ReplicateError.IoError;
        };
        defer file.close();
        file.pwriteAll(body.items, 0) catch return ReplicateError.IoError;
        file.sync() catch return ReplicateError.IoError;
    }

    compat.fs.cwd().rename(temp_path, final_path) catch return ReplicateError.IoError;
}

/// Decide whether the destination is still following the same generation.
fn sameGeneration(
    gen: *const Generation,
    checkpoint_seq: u32,
    reader: *wal_reader_mod.WalReader,
) bool {
    // The reset counter is the authority. It advances before the log is reset
    // and lives in the database file, so it survives both the reset itself and
    // the writer process going away.
    if (checkpoint_seq != gen.checkpoint_seq) return false;

    // Fewer frames than already shipped can only mean the log was reset.
    if (reader.frame_count < gen.frames_shipped) return false;

    // Frame zero is a second opinion, and costs one read. It catches a
    // destination paired with a database whose counter happens to agree.
    if (!gen.has_fingerprint) return true;
    if (reader.frame_count == 0) return true;
    return frameZeroChecksum(reader) == gen.fingerprint;
}

fn frameZeroChecksum(reader: *wal_reader_mod.WalReader) ?u32 {
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
    dest_dir: []const u8,
    generation: u64,
    from: u64,
    to: u64,
) ReplicateError!u64 {
    const gen_dir = generationDir(allocator, dest_dir, generation) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(gen_dir);

    const frames_dir = std.fmt.allocPrint(allocator, "{s}/frames", .{gen_dir}) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(frames_dir);
    compat.fs.cwd().makePath(frames_dir) catch return ReplicateError.IoError;

    const final_path = segmentPath(allocator, dest_dir, generation, from, to) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(final_path);

    const temp_path = std.fmt.allocPrint(allocator, "{s}.partial", .{final_path}) catch {
        return ReplicateError.OutOfMemory;
    };
    defer allocator.free(temp_path);

    var written: u64 = 0;
    {
        const file = compat.fs.cwd().createFile(temp_path, .{ .truncate = true }) catch {
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
    compat.fs.cwd().rename(temp_path, final_path) catch return ReplicateError.IoError;
    return written;
}

/// Run one replication pass for `db` into `dest_dir`.
///
/// Takes a snapshot and opens a new generation when the destination is empty or
/// the log has been reset since the last pass. Otherwise ships whatever frames
/// have appeared. Doing nothing is a normal outcome and not an error.
pub fn replicate(
    db: anytype,
    dest_dir: []const u8,
) ReplicateError!ReplicateStats {
    const allocator = db.allocator;
    const start_ns = compat.nanoTimestamp();

    if (db.wal == null) return ReplicateError.NoWal;

    compat.fs.cwd().makePath(dest_dir) catch return ReplicateError.IoError;

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

    var manifest = (try readManifest(allocator, dest_dir)) orelse Manifest{
        .database_uuid = uuid_hex,
        .frame_size = reader.frame_size,
        .generations = &.{},
    };
    defer manifest.deinit(allocator);

    if (!std.mem.eql(u8, &manifest.database_uuid, &uuid_hex)) {
        return ReplicateError.UuidMismatch;
    }

    var stats = ReplicateStats{
        .generation = 0,
        .started_generation = false,
        .frames_shipped = 0,
        .bytes_shipped = 0,
        .snapshot_bytes = 0,
        .duration_ns = 0,
    };

    const checkpoint_seq = db.page_manager.getHeader().checkpoint_seq;
    const continuing = if (manifest.current()) |gen|
        sameGeneration(gen, checkpoint_seq, &reader)
    else
        false;

    if (!continuing) {
        const number = if (manifest.current()) |gen| gen.number + 1 else 1;

        const gen_dir = generationDir(allocator, dest_dir, number) catch {
            return ReplicateError.OutOfMemory;
        };
        defer allocator.free(gen_dir);
        compat.fs.cwd().makePath(gen_dir) catch return ReplicateError.IoError;

        const snapshot_path = snapshotPath(allocator, dest_dir, number) catch {
            return ReplicateError.OutOfMemory;
        };
        defer allocator.free(snapshot_path);

        const backup_stats = db.backup(snapshot_path) catch return ReplicateError.IoError;
        stats.snapshot_bytes = backup_stats.bytes_copied;
        stats.started_generation = true;

        // The backup checkpointed, which may have published more frames.
        reader.refresh() catch {};

        const grown = allocator.realloc(manifest.generations, manifest.generations.len + 1) catch {
            return ReplicateError.OutOfMemory;
        };
        manifest.generations = grown;

        // Everything currently in the log is folded into the snapshot already,
        // so shipping starts above it rather than at zero.
        const fingerprint = frameZeroChecksum(&reader);
        manifest.generations[grown.len - 1] = .{
            .number = number,
            .checkpoint_seq = db.page_manager.getHeader().checkpoint_seq,
            .opened_at_ms = compat.milliTimestamp(),
            .snapshot_frames = reader.frame_count,
            .frames_shipped = reader.frame_count,
            .fingerprint = fingerprint orelse 0,
            .has_fingerprint = fingerprint != null,
            .segments = &.{},
        };
    } else {
        reader.refresh() catch {};
    }

    const gen = manifest.current().?;
    stats.generation = gen.number;

    if (reader.frame_count > gen.frames_shipped) {
        const from = gen.frames_shipped;
        const to = reader.frame_count;
        stats.bytes_shipped = try shipSegment(allocator, &reader, dest_dir, gen.number, from, to);
        stats.frames_shipped = to - from;

        const grown = allocator.realloc(gen.segments, gen.segments.len + 1) catch {
            return ReplicateError.OutOfMemory;
        };
        gen.segments = grown;
        gen.segments[grown.len - 1] = .{
            .from = from,
            .to = to,
            .shipped_at_ms = compat.milliTimestamp(),
            .bytes = stats.bytes_shipped,
        };

        // Only claim the frames once the segment holding them is on disk.
        gen.frames_shipped = to;

        if (!gen.has_fingerprint) {
            if (frameZeroChecksum(&reader)) |fp| {
                gen.fingerprint = fp;
                gen.has_fingerprint = true;
            }
        }
    }

    try writeManifest(allocator, dest_dir, manifest);

    stats.duration_ns = @intCast(compat.nanoTimestamp() - start_ns);
    return stats;
}
