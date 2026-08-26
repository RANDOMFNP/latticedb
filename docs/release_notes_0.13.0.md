# LatticeDB 0.13.0 Release Notes

## Summary

A database can now only be open in one process at a time, enforced with a lock on
the file rather than left to convention.

## Highlights

- **Opening a database takes a lock on the file.** A read-write handle takes it
  exclusively and a read-only handle shares it, so a second writer is refused,
  and a reader is refused while a writer holds the database. Any number of
  readers can share a database nobody is writing.

  Two processes writing one database file corrupt it, and the damage surfaces
  long after the moment that caused it. Opening now fails at the point of the
  mistake instead, with a message that says what to do:

  ```text
  Error: social.lattice is open in another process. Close it first, or pass
  --no-lock if you are certain nothing is writing to it.
  ```

  The lock is taken on the open file rather than recorded in one, so it is
  released whenever the process goes away, including when it crashes. There is no
  stale lock to clear by hand.

- **Readers are excluded from a database being written**, which is the part most
  likely to surprise. It is not a limitation of the lock but a fact it reports: a
  reader in another process cannot see the writer's buffered pages, and a
  read-only handle does not open the write-ahead log at all, so what it would read
  is a stale file that a checkpoint may be rewriting underneath it.

- **New `--no-lock` flag on every command**, and a `lock` open option behind it,
  for filesystems where locking does not work. It does not make concurrent access
  safe; it removes the thing that was going to tell you it was not.

- **`lattice replicate` now refuses to run against a database another process has
  open**, instead of relying on the documentation telling you not to.

## API Notes

- New `DatabaseError.DatabaseLocked` and `OpenOptions.lock`.

- New `lattice_open_options_v4` and `lattice_open_v4` in the C API, adding a
  `lock` field. The existing structs and entry points are unchanged, so nothing
  compiled against them needs to move.

- Every binding can turn the lock off and reports the new error: Python gains a
  `lock=` argument and `LatticeDatabaseLockedError`, TypeScript gains a `lock`
  option and `LatticeErrorCode.DatabaseLocked`, and Go gains `DisableLock` and
  `ErrorDatabaseLocked`.

  Go phrases it as a negative because a Go bool cannot tell an omitted field from
  a deliberate `false`, and locking has to stay on when the caller says nothing.
  A `Lock bool` field would have defaulted to no locking, which is the opposite of
  what an unset field should mean. `DisableWAL` already solved this there and this
  follows it.

- New `LATTICE_ERROR_DATABASE_LOCKED` (`-16`). It is deliberately distinct from
  `LATTICE_ERROR_LOCK_TIMEOUT` (`-8`), which reports a second writer inside your
  own process. Conflating the two would leave callers unable to tell "wait for my
  own transaction" apart from "another program owns this file".

- `vfs.File` gains `tryLock`, which takes a lock only if it is free. Opening waits
  for nothing: a caller who cannot have the database wants to be told, not to hang
  until some other process happens to exit.

## Upgrade Notes

- **Read-only commands now fail while an application holds the database.**
  `lattice count`, `info`, `schema`, `dump`, `export`, `labels`, `types`, and
  `check` previously ran and returned results that could be stale or, during a
  checkpoint, structurally inconsistent. They now refuse. Run them when the
  database is free, or pass `--no-lock` if you accept the answer may be wrong.

- **Opening the same database twice in one process now fails.** The lock is held
  per open file rather than per process, so a program that opened two handles to
  one database was already at risk and now finds out.

## Validation Notes

- `zig build test`, `zig build integration-test`, and `zig build crash-test`
  passed, as did the Python, TypeScript, and container CLI suites.
- The locking tests were checked against a build with locking disabled to confirm
  they fail when the behaviour is removed.
- Cross-process behaviour was verified with two real processes rather than two
  handles in one, covering a refused writer, a refused reader, `--no-lock`, and
  the lock being released when the holding process exits.
