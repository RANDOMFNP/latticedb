# LatticeDB Next Release Notes

Use this file as the draft for the next release after `0.11.1`.

## Summary

Queued so far: `ORDER BY` can name a `RETURN` alias, and the write-ahead log no
longer grows without limit.

## Highlights

- The write-ahead log is checkpointed automatically as it grows, instead of only
  when the database closes. A long-running process previously accumulated frames
  without limit and paid for them again in recovery time; a 400-write run grew
  the log to 1.6 MB and never shrank it. The log now sawtooths and stays bounded
  by `auto_checkpoint.max_wal_frames`, 1000 frames by default. Set
  `auto_checkpoint` to null to manage checkpoints yourself.
- New `lattice backup <path> --file=<dest>` copies a database to another file
  without closing it. Pending writes are flushed first, so the copy is a complete
  database needing no log beside it, and it is written next to the destination
  and renamed into place so an interrupted backup leaves nothing that looks
  usable. Previously the only correct backup was to stop the process and copy the
  file; copying a live database silently produced something that failed at
  restore.
- New `lattice checkpoint <path>` flushes pending writes into the database file
  and resets the log, reporting pages flushed, checkpoint LSN, and whether the
  log was truncated. Useful before copying a database file, and as the
  consistent-snapshot point a future backup command needs.

- `ORDER BY` accepts an alias introduced by `RETURN`, as in
  `RETURN count(d) AS papers ORDER BY papers DESC`. Sorting is planned before
  projection, so the alias was not a column yet and the query failed with
  "Variable 'papers' is not defined". The planner now substitutes the expression
  the alias stands for. Naming something that is neither a bound variable nor an
  alias is still an error.

## API Notes

- New `storage/wal_reader.zig` reads a write-ahead log from outside the process
  that writes it, which the existing `WalIterator` cannot do because it needs a
  live `WalManager`. It verifies the header and every frame, reports a frame the
  writer has not published yet as `FrameNotYetDurable`, reports a truncation as
  `Rewound` so a follower does not carry on through frame numbers that no longer
  refer to the same records, and offers `readFrameRetrying` for the torn-read
  case. Groundwork for continuous backup; not yet wired to anything.

- New `Database.backup(dest_path)` copies the database to another path and
  reports bytes copied, pages, pages flushed, and duration. It refuses to run
  while a transaction is open.
- New `Database.checkpoint(mode)` returns checkpoint statistics rather than
  discarding them. `checkpointWal` remains as a void wrapper.

- None yet.

## Upgrade Notes

- None yet.

## Validation Notes

- `zig build test` and `zig build integration-test` passed.
- Python, TypeScript, and Go binding suites passed.
