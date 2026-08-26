# LatticeDB Next Release Notes

Use this file as the draft for the next release after `0.13.0`.

## Summary

A database can be handed out as bytes and opened from bytes, which is what makes
it practical to keep many small databases in object storage.

## Highlights

- **New `serialize` and `deserialize`.** A database can be turned into a block of
  bytes and opened again from one. The bytes are a database file: write them
  anywhere and they open.

  This is the piece people need for a database per case, per tenant, or per
  document, kept in S3 or Azure Blob Storage and pulled down when needed:

  ```python
  blob = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
  db = latticedb.deserialize(blob)
  db.query("CREATE (n:Note {text: 'found something'})")
  s3.put_object(Bucket=bucket, Key=key, Body=db.serialize(), IfMatch=etag)
  ```

  It is cheap because a database here is one file, so serialising it is reading
  that file. Engines that spread a database across a catalog, indexes, and a log
  have to invent a container format and keep it in step with themselves.

- **The engine does no networking for this, deliberately.** Your application
  already has a storage client, credentials, and a retry policy somebody chose.
  An engine that reimplemented those would do a worse job of something you
  already have, and would have to hold your cloud credentials to do it.

- Available in every binding: `Database.serialize()` everywhere, plus
  `latticedb.deserialize` in Python, `deserialize` in TypeScript,
  `latticedb.Deserialize` in Go, and `lattice_serialize` / `lattice_deserialize`
  in C.

- **New in-memory databases.** Open `:memory:` and the database has no files
  behind it at all:

  ```python
  db = latticedb.Database(":memory:")
  ```

  It works through the command line and all three bindings with no changes to any
  of them, because every one of them already passes a path string straight
  through. That was the argument for making it a path rather than an option.

  `deserialize` uses the same backend, so a database pulled out of object storage
  never becomes a file on the way in — which is what somebody running one of
  these per request, or on a read-only filesystem, actually asked for.

- **`deserialize` can point at your bytes instead of copying them.** Pass
  `copy=False` in Python or `copy = false` in TypeScript and a freshly loaded
  database costs about half what it used to. Each page becomes a copy of its own
  the first time it is written, so reading a database and changing a little of it
  keeps one copy of nearly all of it, and your buffer is never modified.

  The bytes have to outlive the database, and the binding holds a reference for
  you so there is nothing to keep alive by hand. Go and Java do not get this
  option, and that is a language rule rather than an oversight: Go may not let C
  retain a pointer into its heap at all, and pinning a Java array for the life of
  a database would hold up the collector for exactly as long.

- **Small in-memory databases cost much less than they did.** The page cache is
  sized to the database rather than to a fixed budget, since a cache larger than
  the data it holds has frames it can never fill. Measured on a hundred-kilobyte
  database, overhead falls from about sixteen megabytes to a quarter of one.

  The floor under that sizing was measured rather than guessed: four frames were
  enough to complete a deep traversal, a filtered scan, a full-text search, and a
  bulk write over a fifteen-hundred node graph. It is set at sixty-four, sixteen
  times that, because the measurement was single threaded.

## API Notes

- `Database.serialize(allocator)` returns the database as bytes. Pending writes
  are folded in first, so the result needs no write-ahead log beside it, and it
  is refused while a transaction is open for the same reason `backup` is.

- `Database.deserialize(allocator, bytes, options)` opens a database from bytes.
  The bytes are copied, so callers may release them immediately. Until databases
  can live in memory it materialises a file, which the returned handle owns and
  removes when it closes, so a workflow that runs per request leaves nothing
  behind.

- Bytes that are not a database are refused. Without that check an empty or
  truncated download would be written out, opened, and silently turned into a
  brand new empty database, because opening a zero-length file is how a database
  gets created. That would have reported success and lost everything.

- `lattice_serialize` hands back an owned buffer released with
  `lattice_free_bytes`; `lattice_deserialize` takes the bytes and an options
  struct.

- New `storage/memory_vfs.zig`. A database holds its storage backend by value, so
  nothing has to be kept alive alongside the handle. Memory files are stored as
  page-sized chunks rather than one growing buffer: a contiguous buffer is
  reallocated as it grows, which moves every byte, and anything holding a borrowed
  slice would be left pointing at freed memory.

- Opening `:memory:` implies creating it. There is never a previous in-memory
  database to find, so requiring `create` would be a formality every caller had to
  remember.

- Locks always succeed in memory. A lock keeps a second process off a database,
  and no other process can reach memory this one owns.

- New `lattice_deserialize_borrowed`, and `DeserializeOptions.borrow_bytes` in
  Zig. Borrowing is a separate entry point rather than a flag on the options
  struct, because it carries an obligation about how long the bytes must live and
  that deserves to be visible where it is called.

## Upgrade Notes

- Nothing changes for existing code.

## Validation Notes

- `zig build test`, `zig build integration-test`, and `zig build crash-test`
  passed, as did the Python, TypeScript, and Go suites.
- The round-trip tests were checked against a build with the flushing step
  removed and against one that never deletes the materialised file, to confirm
  they fail when the behaviour is removed.
- The round trip was exercised by hand from C, Python, TypeScript, and Go against
  a running database, including releasing the serialized bytes before using the
  deserialized handle.
- `:memory:` was exercised by hand through the command line and all three
  bindings, checking in each that a write, a read, and a serialize work and that
  no file appears on disk.
- The in-memory tests were checked against a build where `:memory:` falls through
  to the real filesystem, and against one where every in-memory database shares a
  filesystem, to confirm they fail when the behaviour is removed.
- Borrowing was checked the same way, against a build that quietly copies instead
  and against one whose writes reach through into the caller's buffer. Both
  properties are asserted directly: that borrowing allocates less than copying,
  and that the caller's bytes come back unchanged after forty writes.
