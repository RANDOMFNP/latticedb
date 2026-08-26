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
