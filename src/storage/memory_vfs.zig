//! A filesystem that lives in memory.
//!
//! Everything in the storage layer reaches disk through the `Vfs` interface, so
//! swapping in this one gives a database with no files behind it at all. That is
//! what `:memory:` opens, and what a database deserialized from bytes runs on:
//! pull a small database out of object storage, work on it, hand the bytes back,
//! and never touch the local disk.
//!
//! ## Chunks rather than one buffer
//!
//! A file is a list of page-sized chunks, not a single growing allocation.
//!
//! The reason is not allocation churn, though this avoids that too. A contiguous
//! buffer has to be reallocated when the file grows, and a reallocation moves
//! every byte to a new address. Anything holding a borrowed slice from before —
//! which is the whole basis of lending bytes to a caller or to the buffer pool —
//! would be left pointing at freed memory. Chunked storage is what makes lending
//! possible, so it is here from the start rather than retrofitted later.
//!
//! ## Locking
//!
//! Locks always succeed, deliberately rather than by omission. A lock exists to
//! stop a second process treading on a database, and no other process can reach
//! memory this one owns. There is nothing to exclude.

const std = @import("std");
const vfs_mod = @import("vfs.zig");

const Allocator = std.mem.Allocator;
const VfsError = vfs_mod.VfsError;
const OpenFlags = vfs_mod.OpenFlags;
const LockMode = vfs_mod.LockMode;

/// Size of one chunk. Matches the default page size, so a page read or write
/// lands inside a single chunk rather than straddling two.
pub const CHUNK_SIZE: usize = 4096;

/// One page-sized piece of a file.
///
/// A chunk either owns its bytes or points into a buffer somebody else owns. A
/// database seeded from a caller's blob starts out entirely borrowed, and each
/// chunk becomes owned the first time something writes to it. A workload that
/// opens a database, reads it, and changes a little of it therefore holds one
/// copy of nearly everything rather than two.
const Chunk = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    fn bytes(self: Chunk) []const u8 {
        return switch (self) {
            .borrowed => |b| b,
            .owned => |o| o,
        };
    }
};

/// The bytes of one file, held as page-sized pieces.
const Contents = struct {
    allocator: Allocator,
    chunks: std.ArrayListUnmanaged(Chunk),
    /// Length of the file, which is not the same as the space its chunks
    /// provide: the last chunk is usually partly unused.
    len: u64,

    fn init(allocator: Allocator) Contents {
        return .{ .allocator = allocator, .chunks = .empty, .len = 0 };
    }

    fn deinit(self: *Contents) void {
        for (self.chunks.items) |chunk| {
            // Borrowed chunks belong to the caller and are not ours to release.
            switch (chunk) {
                .owned => |o| self.allocator.free(o),
                .borrowed => {},
            }
        }
        self.chunks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Turn a borrowed chunk into one of our own, so it can be written to.
    ///
    /// Copy-on-write at page granularity. Until this runs the bytes belong to
    /// whoever handed them over and must not be modified.
    fn makeOwned(self: *Contents, index: usize) VfsError![]u8 {
        switch (self.chunks.items[index]) {
            .owned => |o| return o,
            .borrowed => |b| {
                const copy = self.allocator.alloc(u8, CHUNK_SIZE) catch {
                    return VfsError.Unexpected;
                };
                @memset(copy, 0);
                @memcpy(copy[0..b.len], b);
                self.chunks.items[index] = .{ .owned = copy };
                return copy;
            },
        }
    }

    /// Make sure a chunk exists for every byte below `needed`.
    fn reserve(self: *Contents, needed: u64) VfsError!void {
        const want = (needed + CHUNK_SIZE - 1) / CHUNK_SIZE;
        while (self.chunks.items.len < want) {
            const chunk = self.allocator.alloc(u8, CHUNK_SIZE) catch {
                return VfsError.Unexpected;
            };
            // Zeroed, because a file grown past its end reads as zeroes rather
            // than as whatever the allocator last had there.
            @memset(chunk, 0);
            self.chunks.append(self.allocator, .{ .owned = chunk }) catch {
                self.allocator.free(chunk);
                return VfsError.Unexpected;
            };
        }
    }

    /// Point this file at bytes somebody else owns.
    ///
    /// The buffer has to outlive the file, which is the caller's problem to
    /// arrange and is why this is not the default.
    fn borrowWhole(self: *Contents, data: []const u8) VfsError!void {
        var at: usize = 0;
        while (at < data.len) {
            const take = @min(CHUNK_SIZE, data.len - at);
            self.chunks.append(self.allocator, .{ .borrowed = data[at..][0..take] }) catch {
                return VfsError.Unexpected;
            };
            at += take;
        }
        self.len = data.len;
    }

    fn readAt(self: *const Contents, offset: u64, buf: []u8) usize {
        if (offset >= self.len) return 0;

        const available = self.len - offset;
        const want = @min(@as(u64, buf.len), available);

        var done: u64 = 0;
        while (done < want) {
            const at = offset + done;
            const chunk_index: usize = @intCast(at / CHUNK_SIZE);
            const within: usize = @intCast(at % CHUNK_SIZE);
            const chunk = self.chunks.items[chunk_index].bytes();
            // A borrowed tail chunk can be shorter than a full chunk, so a read
            // that runs past its end stops there.
            if (within >= chunk.len) break;
            const take = @min(
                @min(CHUNK_SIZE - within, chunk.len - within),
                @as(usize, @intCast(want - done)),
            );
            @memcpy(buf[@intCast(done)..][0..take], chunk[within..][0..take]);
            done += take;
        }
        return @intCast(done);
    }

    fn writeAt(self: *Contents, offset: u64, data: []const u8) VfsError!void {
        if (data.len == 0) return;
        try self.reserve(offset + data.len);

        var done: usize = 0;
        while (done < data.len) {
            const at = offset + done;
            const chunk_index: usize = @intCast(at / CHUNK_SIZE);
            const within: usize = @intCast(at % CHUNK_SIZE);
            const put = @min(CHUNK_SIZE - within, data.len - done);
            // Writing is what converts a borrowed chunk to one of our own.
            const chunk = try self.makeOwned(chunk_index);
            @memcpy(chunk[within..][0..put], data[done..][0..put]);
            done += put;
        }

        // Writing past the end extends the file, which is how a database file
        // grows a page at a time.
        if (offset + data.len > self.len) self.len = offset + data.len;
    }

    fn truncate(self: *Contents, new_size: u64) VfsError!void {
        if (new_size > self.len) {
            try self.reserve(new_size);
            self.len = new_size;
            return;
        }

        self.len = new_size;

        // Give back chunks that are now entirely past the end. The chunk holding
        // the new last byte is kept, since part of it is still in use.
        const keep = (new_size + CHUNK_SIZE - 1) / CHUNK_SIZE;
        while (self.chunks.items.len > keep) {
            const chunk = self.chunks.pop() orelse break;
            switch (chunk) {
                .owned => |o| self.allocator.free(o),
                .borrowed => {},
            }
        }

        // Whatever is left above the new end reads as zeroes if the file grows
        // back, rather than as the data that used to be there. Clearing it means
        // writing, so a borrowed chunk becomes ours first.
        if (keep > 0 and new_size % CHUNK_SIZE != 0) {
            const within: usize = @intCast(new_size % CHUNK_SIZE);
            const chunk = try self.makeOwned(keep - 1);
            @memset(chunk[within..], 0);
        }
    }
};

/// A filesystem held entirely in memory.
///
/// Owns every file in it, so dropping the VFS drops the databases stored there.
/// One of these per database keeps two in-memory databases from seeing each
/// other's files.
pub const MemoryVfs = struct {
    allocator: Allocator,
    files: std.StringHashMapUnmanaged(*Contents),
    mutex: @import("compat").Mutex,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator, .files = .empty, .mutex = .{} };
    }

    pub fn deinit(self: *Self) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn vfs(self: *Self) vfs_mod.Vfs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = vfs_mod.Vfs.VTable{
        .open = vfsOpen,
        .delete = vfsDelete,
        .exists = vfsExists,
    };

    fn vfsOpen(ptr: *anyopaque, path: []const u8, flags: OpenFlags) VfsError!vfs_mod.File {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.openFile(path, flags);
    }

    fn vfsDelete(ptr: *anyopaque, path: []const u8) VfsError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.deleteFile(path);
    }

    fn vfsExists(ptr: *anyopaque, path: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.fileExists(path);
    }

    pub fn openFile(self: *Self, path: []const u8, flags: OpenFlags) VfsError!vfs_mod.File {
        self.mutex.lock();
        defer self.mutex.unlock();

        var contents = self.files.get(path);

        if (contents == null) {
            if (!flags.create) return VfsError.FileNotFound;
            contents = try self.createLocked(path);
        } else if (flags.exclusive) {
            return VfsError.AlreadyExists;
        } else if (flags.truncate) {
            try contents.?.truncate(0);
        }

        const handle = self.allocator.create(MemoryFile) catch return VfsError.Unexpected;
        handle.* = .{
            .allocator = self.allocator,
            .owner = self,
            .contents = contents.?,
            .writable = flags.write,
        };
        return handle.file();
    }

    fn createLocked(self: *Self, path: []const u8) VfsError!*Contents {
        const key = self.allocator.dupe(u8, path) catch return VfsError.Unexpected;
        errdefer self.allocator.free(key);

        const contents = self.allocator.create(Contents) catch return VfsError.Unexpected;
        errdefer self.allocator.destroy(contents);
        contents.* = Contents.init(self.allocator);

        self.files.put(self.allocator, key, contents) catch return VfsError.Unexpected;
        return contents;
    }

    pub fn deleteFile(self: *Self, path: []const u8) VfsError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.files.fetchRemove(path) orelse return VfsError.FileNotFound;

        // An open handle still points at these contents, so this frees them only
        // when nothing holds one. The engine deletes a log only after closing it.
        entry.value.deinit();
        self.allocator.destroy(entry.value);
        self.allocator.free(entry.key);
    }

    pub fn fileExists(self: *Self, path: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.files.contains(path);
    }

    /// Bytes this filesystem has allocated for itself, not counting anything it
    /// has borrowed. This is what an in-memory database actually costs.
    pub fn byteCount(self: *Self) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total: u64 = 0;
        var it = self.files.valueIterator();
        while (it.next()) |contents| {
            for (contents.*.chunks.items) |chunk| {
                switch (chunk) {
                    .owned => total += CHUNK_SIZE,
                    .borrowed => {},
                }
            }
        }
        return total;
    }

    /// Point a file at bytes somebody else owns, without copying them.
    ///
    /// Each page becomes a copy of its own the first time something writes to
    /// it, so a database that is read and lightly edited holds one copy of
    /// nearly all of itself instead of two.
    ///
    /// **`data` has to outlive every file in this filesystem.** That is a real
    /// obligation and the reason this is separate from `writeWholeFile`: the
    /// bytes are not copied, so releasing them early leaves the database reading
    /// freed memory.
    pub fn borrowWholeFile(self: *Self, path: []const u8, data: []const u8) VfsError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var contents = self.files.get(path);
        if (contents == null) contents = try self.createLocked(path);
        try contents.?.truncate(0);
        try contents.?.borrowWhole(data);
    }

    /// Replace a file's contents wholesale. Used to seed a database from bytes
    /// before opening it.
    pub fn writeWholeFile(self: *Self, path: []const u8, bytes: []const u8) VfsError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var contents = self.files.get(path);
        if (contents == null) contents = try self.createLocked(path);
        try contents.?.truncate(0);
        try contents.?.writeAt(0, bytes);
    }
};

/// One open handle onto a file in a `MemoryVfs`.
pub const MemoryFile = struct {
    allocator: Allocator,
    owner: *MemoryVfs,
    contents: *Contents,
    writable: bool,

    const Self = @This();

    pub fn file(self: *Self) vfs_mod.File {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = vfs_mod.File.VTable{
        .read = fileRead,
        .write = fileWrite,
        .sync = fileSync,
        .truncate = fileTruncate,
        .size = fileSize,
        .close = fileClose,
        .lock = fileLock,
        .tryLock = fileTryLock,
        .unlock = fileUnlock,
    };

    fn fileRead(ptr: *anyopaque, offset: u64, buf: []u8) VfsError!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.owner.mutex.lock();
        defer self.owner.mutex.unlock();
        return self.contents.readAt(offset, buf);
    }

    fn fileWrite(ptr: *anyopaque, offset: u64, data: []const u8) VfsError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!self.writable) return VfsError.PermissionDenied;
        self.owner.mutex.lock();
        defer self.owner.mutex.unlock();
        return self.contents.writeAt(offset, data);
    }

    fn fileSync(ptr: *anyopaque) VfsError!void {
        // Nothing to flush. The bytes are already as durable as they are ever
        // going to be, which is to say not at all.
        _ = ptr;
    }

    fn fileTruncate(ptr: *anyopaque, new_size: u64) VfsError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!self.writable) return VfsError.PermissionDenied;
        self.owner.mutex.lock();
        defer self.owner.mutex.unlock();
        return self.contents.truncate(new_size);
    }

    fn fileSize(ptr: *anyopaque) VfsError!u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.owner.mutex.lock();
        defer self.owner.mutex.unlock();
        return self.contents.len;
    }

    fn fileClose(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // The contents belong to the VFS and outlive the handle, so closing
        // releases the handle and nothing else.
        self.allocator.destroy(self);
    }

    fn fileLock(ptr: *anyopaque, mode: LockMode) VfsError!void {
        _ = ptr;
        _ = mode;
    }

    fn fileTryLock(ptr: *anyopaque, mode: LockMode) VfsError!bool {
        _ = ptr;
        _ = mode;
        // Always granted. A lock exists to keep a second process off a database,
        // and no other process can reach memory this one owns.
        return true;
    }

    fn fileUnlock(ptr: *anyopaque) void {
        _ = ptr;
    }
};
