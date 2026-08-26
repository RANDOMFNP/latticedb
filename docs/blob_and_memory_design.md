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

**Somewhere to put the bytes.** Getting them to S3, R2, Azure Blob, or GCS. This
looks like the expensive part and mostly is not ours to pay, for reasons below.

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

## How the bytes should reach the cloud

This is the decision that shapes everything else, and the first draft of this
document got it wrong. It led with implementing SigV4 and SharedKey in the
engine. That is the wrong place to start, and the reason is not effort.

**Ask who is in the loop.** Both people who asked for this have applications. Those
applications already have a cloud SDK, already have credentials, and already have
a retry policy their operations team has opinions about. An engine that
implements SigV4 is reimplementing, worse, something the caller already has — and
taking custody of long-lived cloud credentials to do it. A database that holds
credentials is a different security proposition from one that does not, and it is
not a change to make in exchange for saving the caller four lines.

There is one case where nobody is in the loop: `lattice replicate` shipping to a
bucket with no application running. That case genuinely needs the engine to speak
to the network. It is also the case nobody has asked for yet.

So the design is three layers, and the value is heavily concentrated in the first.

### Layer 0 — bytes in, bytes out

```zig
try db.serializeTo(writer);                        // stream out
var db = try Database.deserializeFrom(reader, .{}); // stream in
```

No networking, no credentials, no providers. The application does its own I/O
with the SDK it already trusts:

```python
blob = s3.get_object(Bucket=b, Key=k)["Body"].read()
db = latticedb.deserialize(blob)
# ... mutate ...
s3.put_object(Bucket=b, Key=k, Body=db.serialize(), IfMatch=etag)
```

This completely serves both requests. It is also where conditional writes belong
for this workflow: the caller already holds the ETag and already knows what to do
when the condition fails, which is application logic we would only be guessing at.

Reader and writer based rather than `[]u8` based, so the same code streams to a
socket, a file, or a buffer without the whole database existing twice in memory.
The `[]u8` convenience wrappers sit on top for the languages that want them.

### Layer 1 — a URL and some headers

For when the engine should move the bytes but must not hold credentials, the
application presigns a request and hands over the result:

```zig
try db.uploadTo(.{ .url = presigned_put_url, .headers = extra });
```

The engine parses the URI, sets the method and headers, streams the body, and
reads the response status and ETag. That is the whole implementation. It has no
provider-specific code at all, because a presigned S3 URL, an R2 presigned URL,
an Azure SAS URL, and a GCS signed URL are all just URLs. A provider that appears
in five years works on the day it ships.

`std.http.Client` already streams request bodies, which is the real argument for
this layer over doing it in the application. Uploading a large database through
Layer 0 means materialising it as a buffer, handing that to the SDK, and probably
copying it again. Here the peak cost is one page. For the per-case databases
being asked about that does not matter; for a database that is actually large it
is the difference between working and running out of memory.

The cost is that presigned URLs expire and cannot express `list`.

### Layer 2 — native signers

Only for the headless case: `lattice replicate s3://bucket/path` with no
application anywhere. This is where SigV4, SharedKey, credential chains,
instance metadata, and per-provider quirks live, and it is the layer that should
wait until somebody needs it.

If it is built, one SigV4 implementation reaches S3, Cloudflare R2, and Google
Cloud Storage through its S3-compatible XML API with HMAC keys. That last one
matters: the native Google path needs OAuth2 with service-account JWTs signed
RS256, and `std.crypto` exposes RSA only inside certificate and TLS verification,
not as a signing API. Taking the S3-compatible route avoids writing RSA signing
from scratch, which is not a thing to do casually in a database. Azure needs a
second signer, but SharedKey is also HMAC-SHA256 over a canonicalised string.

No third-party dependency in any of it — the HTTP client is already in the tree
for embeddings, and `std.crypto` has the hashing. It still belongs behind a build
flag, because an embedded database that puts cloud support in every binary has
given something up.

### What replication needs

Replication's outstanding object-storage phase is the one real customer for
Layer 2, since a `--follow` loop writes objects whose names it decides as it goes
and no application is there to presign them. A `BlobStore` interface with a
directory-backed implementation comes first regardless, so that provider bugs and
logic bugs stay separable, and so the existing destination code has something to
become rather than sitting beside a parallel implementation.

### What serialize actually is

`serialize` is `backup` writing to a stream instead of a path, so it inherits the
behaviour that is already tested: pending writes are folded in first, and it
refuses while a transaction is open. Until Phase 2 lands, `deserializeFrom`
writes to a temporary file and opens that, which is not elegant but is correct
and useful immediately.

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

**Phase 1 — Serialization.**
`serializeTo` and `deserializeFrom` over readers and writers, with buffer
conveniences on top, and the bindings to use them. No networking. This is the
whole of what was asked for and should ship on its own.

**Phase 1b — Presigned transfer.**
Upload and download against a caller-supplied URL and headers, streaming, with
the response ETag returned. No provider-specific code.

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
