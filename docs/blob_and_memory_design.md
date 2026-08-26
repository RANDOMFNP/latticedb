# Blob Storage and In-Memory Databases

Two people have asked for the same shape of thing: many small graph databases
rather than one large one, kept in object storage, pulled down per unit of work,
mutated, and pushed back. One of them wants to skip the local filesystem
entirely and work in memory, the way SQLite's `:memory:` and its
`serialize`/`deserialize` pair let you.

This is the design for supporting that.

## Why this is cheap for us and expensive for others

The same request has been made of Kùzu, where it is hard, because a database
there is a catalog, metadata, data, index, and WAL spread across several files.
Serializing means inventing a container format for all of them and keeping it in
step with the engine.

A LatticeDB database is one file. Serializing it is reading that file. That is
not a clever trick, it is the whole reason the single-file format was worth
having, and it is the strongest answer we have to "why not Kùzu".

Better still, `Database.backup` already does most of the work. It flushes pending
writes into the file and copies it, producing something standalone that opens
with no write-ahead log beside it. That is exactly the blob somebody wants to put
in a bucket. Somebody could build this workflow on 0.13.0 today with a temporary
directory, and it would work.

## What is actually being asked for

Three separable pieces, worth naming because they have very different costs.

**Bytes in, bytes out.** Serialize a database to a buffer, and open a database
from one. Almost free, because of the above.

**Somewhere to put the bytes.** Talking to S3, R2, Azure Blob, and GCS. This is
the part that looks expensive and turns out to be less so than it appears.

**Never touching the disk.** Running the whole engine against memory, so a
per-case database never becomes a file. This is the genuinely tricky one.

## What the engine already supports

Verified against the source rather than assumed, because the answer decides how
much of this is design and how much is plumbing.

The storage layer is already clean with respect to the filesystem. `wal.zig`,
`page_manager.zig`, `buffer_pool.zig`, `btree.zig`, `recovery.zig`, and
`checkpoint.zig` make **no direct filesystem calls at all** — every byte moves
through the `Vfs` interface. Nothing is memory-mapped, so there is no path that
assumes a real file underneath.

The `Vfs` vtable already covers what an alternative backend needs: `open`,
`delete`, and `exists`, plus per-file `read`, `write`, `sync`, `truncate`,
`size`, `close`, and the locking calls.

Only two places in the engine reach around it, both in `database.zig`: a
`deleteFile` on the log during one recovery case, and the `rename` that makes
`backup` atomic.

There is already an HTTP client with TLS in the tree, used by the embedding
client to reach Ollama and OpenAI, wrapped as `compat.httpClient`. `std.crypto`
provides HMAC-SHA256 and SHA-256.

The one real gap is that `Database.open` hardcodes its VFS: the field is a
concrete `PosixVfs` held by value and assigned during open, so there is no way to
hand the engine a different one.

## Phase 1 — Blob storage

Doing this first is the right order, and not only because it is easier. The
replication design's outstanding phase is object storage, and it needs exactly
the same thing: somewhere to put named, immutable objects. One abstraction
finishes both.

### Four providers, two signatures

The instinct that this means four SDKs is worth resisting, because it is not
what the work requires.

- **AWS S3** uses SigV4, which is a chain of HMAC-SHA256 operations over a
  canonicalised request. `std.crypto` has everything it needs.
- **Cloudflare R2** is S3-compatible. The same signer works against a different
  endpoint.
- **Google Cloud Storage** supports S3-compatible access through its XML API with
  HMAC keys, which the same signer also covers. This matters a great deal: the
  native GCS path would mean OAuth2 with service-account JWTs signed RS256, and
  `std.crypto` exposes RSA only inside certificate and TLS verification, not as a
  signing API we could call. Taking the S3-compatible route sidesteps writing RSA
  signing from scratch, which is not a thing to do casually in a database.
- **Azure Blob Storage** needs its own signer, but SharedKey is also HMAC-SHA256
  over a canonicalised string. It is a second signer, not a second SDK.

So the work is one SigV4 implementation covering three providers, one SharedKey
implementation covering the fourth, and one HTTP path shared by all of them. That
is a meaningfully smaller job than it first looks, and it introduces no
third-party dependency, because it is all `std`.

### The interface

```zig
pub const BlobStore = struct {
    get: fn (key: []const u8, allocator) ![]u8,
    put: fn (key: []const u8, bytes: []const u8, cond: Condition) !PutResult,
    delete: fn (key: []const u8) !void,
    list: fn (prefix: []const u8, allocator) ![]ObjectInfo,
};
```

A `FileBlobStore` backed by a directory comes first and is what the tests run
against, so provider bugs and logic bugs stay separable. Replication's existing
destination code becomes a user of this rather than a parallel implementation.

### Conditional writes are part of version one

The failure this architecture invites is not in the engine. Two workers pull the
same object, both mutate it, both push, and the second silently erases the first.
Nothing reports an error and nothing looks wrong until someone notices missing
data.

Every provider offers some form of conditional write keyed on an entity tag or
generation number. `put` therefore takes a condition — write only if absent,
write only if unchanged, or overwrite — and returns the new tag. The exact header
each provider wants must be confirmed against current documentation rather than
assumed, since this area has changed recently, but the shape of the interface
does not depend on which header it is.

Making this optional and adding it later would mean shipping a data-loss
footgun and calling it a feature.

### Scope

In: `get`, `put`, `delete`, `list`; SigV4 and SharedKey; credentials from
environment variables and explicit configuration; retry with backoff on the
retryable status codes; conditional writes.

Out, for now: instance metadata and workload identity credential chains, and
multipart upload. Single-request uploads cap out around 5 GB, which is far above
"a small graph database per case", and the limit should be documented rather than
engineered around before anyone has hit it.

The whole thing sits behind a build flag. An embedded database that drags cloud
support into every binary has given something up, and people running on a laptop
should not pay for this.

### Serialize and deserialize

Independent of any provider, and the part that unblocks both people who asked:

```zig
const bytes = try db.serialize(allocator);   // checkpoint, then hand back the file
defer allocator.free(bytes);

var db = try Database.openFromBytes(allocator, bytes, .{});
```

`serialize` is `backup` writing to a buffer instead of a path, so it inherits the
existing behaviour: pending writes are folded in first, and it refuses while a
transaction is open. Until Phase 2 lands, `openFromBytes` writes to a temporary
file and opens that, which is not elegant but is correct and useful immediately.

## Phase 2 — In-memory databases

### The plumbing

Three things, none of them deep:

1. `Database` holds a `Vfs` interface value rather than a concrete `PosixVfs`,
   and `OpenOptions` grows a way to supply one. The supplied VFS has to outlive
   the database, since the interface is a fat pointer to something the caller
   owns.
2. A `MemoryVfs` implementing the twelve vtable entries. Locking becomes a
   no-op that always succeeds, deliberately rather than accidentally: there is no
   second process to exclude from memory this process owns.
3. The two bypasses in `database.zig` route through the VFS.

With those, `openFromBytes` stops needing a temporary file and `serialize`
becomes a copy out of memory.

Worth deciding explicitly: an in-memory database should default to
`enable_wal = false`. A log exists so that a crash cannot lose committed data,
and a process holding the only copy of a database in its own heap loses
everything when it dies regardless. The blob write is the durability boundary,
and the log would only cost allocations. It should remain switchable for anyone
who wants the atomicity of multi-statement transactions within a session.

### The double-buffering problem

The buffer pool reads pages into frames it owns. Against a `MemoryVfs` the bytes
are already in memory, so each page exists twice: once in the memory file, once
in the pool. Peak cost is roughly the database size plus the pool size.

For the per-case databases both requesters describe this is unlikely to matter.
It matters at a gigabyte, and it is worth fixing properly rather than pretending
it is not there.

**What not to do.** The obvious fix is to point buffer-pool frames directly at
the memory file's bytes. Done naively this is wrong, because a dirty page would
then be modified in place in the "file", which breaks the ordering the
write-ahead log depends on: the log record has to be durable before the page
changes. With the log off that objection disappears, but a fix that is only
correct in one configuration is a trap for whoever changes the configuration
later.

**The approach.** Add an optional capability to the VFS rather than a special
case in the buffer pool:

```zig
/// Borrow a read-only view of a byte range, or null when the backing store
/// cannot lend one. Callers must copy before mutating.
borrowRead: ?*const fn (ptr, offset: u64, len: usize) ?[]const u8,
```

`PosixVfs` leaves this null and nothing changes for it. `MemoryVfs` returns a
slice into its own storage. The buffer pool borrows for **clean reads** and copies
on first write, which is copy-on-write at page granularity: a read-heavy workload
— which is what "load a case, query it, put it back" mostly is — keeps one copy of
almost everything, and only genuinely modified pages are duplicated. The log
ordering is untouched, because the moment a page becomes dirty it is a private
copy again.

For that to work, `MemoryVfs` should store the file as a list of page-sized
chunks rather than one contiguous buffer. A growing contiguous buffer reallocates
and invalidates every outstanding borrow, which turns a lending scheme into a
use-after-free. Chunked storage also removes the copy on every file growth.

**The sequencing.** Ship Phase 2 with plain copying first. It is correct, it is
simple, and it makes the feature usable. Add borrowing afterwards, with a
benchmark that shows the peak memory it saves. Doing invasive surgery on the
buffer pool before anyone has measured a problem is how databases acquire subtle
corruption, and the buffer pool is on every hot path in the engine.

## Phasing

**Phase 1 — Blob storage and serialization.**
`BlobStore` with a directory-backed implementation, SigV4 for S3, R2, and GCS,
SharedKey for Azure, conditional writes, and `serialize`/`openFromBytes` via a
temporary file. Replication's object-storage phase is finished by the same work.

**Phase 2 — In-memory databases.**
Pluggable VFS, `MemoryVfs`, the two bypasses removed, and `serialize` and
`openFromBytes` with no filesystem involved. Copying, not borrowing.

**Phase 3 — Zero-copy pages.**
`borrowRead`, chunked memory storage, copy-on-write in the buffer pool, gated on
a benchmark that demonstrates the saving.

Phase 1 is worth having on its own even if the rest never happens, since it is
what both requests actually need.

## What stays out

Credentials management beyond reading configuration. Bring your own credentials.

Coordination between workers over one blob. The conditional write is the tool;
deciding what to do when it fails is application logic, and a database that
invented a leasing protocol would be guessing at requirements.

Anything resembling a distributed database. This is copying files to a bucket and
back, and it should keep looking like that.

## Open questions

- **Should `serialize` compress?** Page-shaped data compresses well and blob
  storage charges for bytes, but a compressed blob is no longer a database file
  somebody can open directly, which is a real part of the appeal. Probably an
  option, defaulting to off.
- **Should `openFromBytes` take ownership of the buffer?** Borrowing avoids a copy
  of the whole database, at the cost of a lifetime rule that is easy to get wrong
  from a garbage-collected language through the C API.
- **How does this interact with the file lock?** An in-memory database has no
  file to lock and no second process to exclude. A blob pulled to a temporary
  path does, and two workers pulling the same object to the same path on one
  machine is a case the lock would usefully catch.
- **Does `list` belong in the interface?** Restore needs it to find generations.
  The blob workflow does not need it at all, and it is the operation whose
  semantics vary most between providers.
