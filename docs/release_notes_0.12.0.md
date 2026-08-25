# LatticeDB 0.12.0 Release Notes

## Summary

LatticeDB can now keep a continuously updated copy of a database somewhere else,
and restore from it to a point in time. Getting there turned up a durability bug
worth reading about on its own: writes issued as plain Cypher queries were not
reaching the write-ahead log.

## The durability fix

A query that changed data and was not handed a transaction ran straight against
the pages. Nothing about it reached the write-ahead log.

That is not a corner case. A bare query is what the command line sends and what
every client library sends for `db.query`, so it is how almost every write
actually arrives. Measured on fifty writes each way, the explicit transaction API
produced fifty log frames and the equivalent Cypher produced none.

Two consequences followed. Such a write had no crash atomicity, because there was
no log record to recover from. And it was invisible to anything reading the log,
which is how backup and replication see changes at all.

A writing query now opens a transaction of its own, committed once its rows have
been built and abandoned if anything fails. A query given a transaction is
unaffected, because the caller has already said where the boundary goes.

This is a behaviour change on the hot path for every mutating query. It brings
the engine in line with what the documentation already described, and it is
strictly safer than what it replaces, but it is worth knowing about before you
upgrade.

## Highlights

- **New `lattice replicate <path> --to=<directory>`** ships a database's changes
  into a directory. The first pass writes a full snapshot and every pass after it
  copies only the write-ahead log frames that have appeared since, which is what
  makes running it often cheap. Add `--follow` and `--interval=<seconds>` to
  leave it running. A pass with nothing to ship says so and exits successfully,
  so it is safe on a timer.

- **New `lattice restore <directory> --output=<path>`** rebuilds a database from
  what replication shipped. It copies the snapshot, replays the changes shipped
  after it, and folds the result into a single file you can open, copy, or move
  on its own. Pass `--at="2026-08-25T14:00:00Z"` for a moment in the past, and
  `--force` to overwrite an existing file.

  Point-in-time resolution is a replication pass, not a single write. You get the
  state as of the last pass at or before the moment you asked for, so whatever
  interval you replicate on is also how precisely you can rewind. The command
  reports the moment it actually restored to rather than repeating the one you
  asked for.

- **New `Database.replicateTo(dest_dir)`** does the same work from inside your
  own process, which is the form to use while an application is running.
  LatticeDB does not lock a database across processes, so `lattice replicate`
  must not be pointed at a database something else has open.

- **New [Backup and Replication](../book/src/guides/backup-and-replication.md)
  guide** covering when to use each of these, and the mistake that costs people
  their data: copying a database file while it is open.

The following were queued after 0.11.1 and ship here as well.

- **The write-ahead log is checkpointed automatically as it grows**, instead of
  only when the database closes. A long-running process previously accumulated
  frames without limit and paid for them again in recovery time; a 400-write run
  grew the log to 1.6 MB and never shrank it. The log now sawtooths and stays
  bounded by `auto_checkpoint.max_wal_frames`, a thousand frames by default. Set
  `auto_checkpoint` to null to manage checkpoints yourself.

- **New `lattice backup <path> --file=<dest>`** copies a database to another file
  without closing it. Pending writes are flushed first, so the copy is a complete
  database needing no log beside it, and it is written next to the destination
  and renamed into place so an interrupted backup leaves nothing that looks
  usable. Previously the only correct backup was to stop the process and copy the
  file, and copying a live database silently produced something that failed at
  restore.

- **New `lattice checkpoint <path>`** flushes pending writes into the database
  file and resets the log, reporting pages flushed, checkpoint LSN, and whether
  the log was truncated. It is useful before copying a database file, and on a
  database that has been open a long time under heavy writes when you would
  rather choose the moment the flush happens.

- **`ORDER BY` accepts an alias introduced by `RETURN`**, as in
  `RETURN count(d) AS papers ORDER BY papers DESC`. Sorting is planned before
  projection, so the alias was not a column yet and the query failed with
  "Variable 'papers' is not defined". The planner now substitutes the expression
  the alias stands for. Naming something that is neither a bound variable nor an
  alias is still an error.

## API Notes

- `Database.replicateTo(dest_dir)` runs one replication pass and reports the
  generation, whether it started a new one, frames and bytes shipped, snapshot
  size, and duration. Shipping nothing is a normal outcome rather than an error.

- New `storage/replicate.zig` owns the destination format: a manifest, a snapshot
  per generation, and frame segments named for the range they cover. The manifest
  records every generation and, within each, every segment with its frame range
  and the moment it landed.

- New `storage/restore.zig` rebuilds a database from a destination. It reuses the
  ordinary recovery path rather than reimplementing replay, so a restore cannot
  drift away from what recovery does after a crash.

- `checkpoint_seq` in the file header, present since the format was written and
  never used, now counts resets of the write-ahead log. It is made durable before
  the reset it describes, so a counter that has not caught up can only cost a
  follower an extra snapshot rather than let it miss one.

- `compat.fs.Cwd` gains `makePath`, `deleteTree`, and `rename`.

- New `storage/wal_reader.zig` reads a write-ahead log from outside the process
  that writes it, which the existing `WalIterator` cannot do because it needs a
  live `WalManager`. It verifies the header and every frame, reports a frame the
  writer has not published yet as `FrameNotYetDurable`, reports a reset as
  `Rewound` so a follower does not carry on through frame numbers that no longer
  refer to the same records, and offers `readFrameRetrying` for the torn-read
  case.

- New `Database.backup(dest_path)` copies the database to another path and
  reports bytes copied, pages, pages flushed, and duration. It refuses to run
  while a transaction is open.

- `Database.checkpoint(mode)` returns checkpoint statistics rather than
  discarding them. `checkpointWal` remains as a void wrapper.

## Upgrade Notes

- **Writing queries now take a transaction.** If your code holds an open write
  transaction and separately calls `db.query("CREATE ...")` without passing that
  transaction, the query now fails rather than writing outside the transaction's
  boundary. Pass the transaction, or do the write inside it.

- **Databases written by older versions are read normally.** `checkpoint_seq` is
  zero in existing files and starts counting from there, so an existing database
  simply begins its replication history at the first pass.

- **Replication destinations have no compatibility promise yet.** The manifest
  format is versioned and a destination written by a different version is
  refused rather than misread. Re-run replication into an empty directory after
  upgrading rather than reusing one written by a pre-release build.

## Known Limitations

- `lattice replicate` opens the database, and there is no cross-process locking,
  so it must not run against a database another process has open. Use
  `replicateTo` from inside the application for that case.

- Replicating directly to object storage is not supported. The destination layout
  was designed for it — whole files, written once, named rather than modified —
  so a directory can be copied to a bucket by any tool you already use.

## Validation Notes

- `zig build test`, `zig build integration-test`, and `zig build crash-test`
  passed.
- The durability fix and the restore round trip were each checked against a
  deliberately broken build to confirm the tests fail when the behaviour is
  removed, rather than passing for unrelated reasons.
- End-to-end command-line runs covered a replication pass with nothing to ship, a
  generation change after a checkpoint, restoring the newest state, and restoring
  to a moment inside an earlier generation.
