# Backup and Replication

A database on one disk is one disk failure away from gone. This guide covers the
three things LatticeDB gives you to prevent that: taking a copy, keeping a copy
continuously up to date, and getting a database back from one.

If you have used [Litestream](https://litestream.io) with SQLite, the shape here
will be familiar. The goal is the same: one machine, one writer, a few minutes of
tolerable downtime, and no desire to lose the last hour of work when the disk
dies.

## The rule that comes first

**Do not back up a database by copying the file while it is open.**

This is the mistake that costs people their data, and it costs them quietly. The
write-ahead log holds committed changes that are not in the main file yet, so:

- Copying only the main file gives you a database that opens and then fails when
  you query it.
- Copying both files catches them at two different instants and gives you a pair
  that fails on open.

Neither announces itself at copy time. You find out when you need the backup,
which is the worst possible moment. Use one of the commands below, or stop the
process first.

## Taking one copy

`backup` copies a running database to another file:

```bash
lattice backup social.lattice --file=/backups/social-2026-08-25.lattice
```

From your own code, the same thing is a method on the database:

```zig
const stats = try db.backup("/backups/social-2026-08-25.lattice");
```

Pending writes are folded into the file before the copy starts, so what you get
is a complete database on its own. It needs no log beside it, and you can open it
directly.

Two things to know. The copy captures the database as of the moment it starts, so
writes that land while it runs are not included. And it refuses to run while a
transaction is open, because a copy taken while writes land underneath it is torn
in ways no later check would catch.

This is the right tool for a nightly snapshot. It is the wrong tool for "I do not
want to lose the last hour", because an hour is exactly how much you lose.

## Keeping a copy up to date

`replicate` ships changes into a directory. The first pass copies the whole
database, and every pass after that copies only what has changed since:

```bash
lattice replicate social.lattice --to=/mnt/backup/social
```

Run it on an interval and the destination trails your database by roughly that
interval:

```bash
lattice replicate social.lattice --to=/mnt/backup/social --follow --interval=30
```

A pass with nothing to ship is normal, says so, and exits successfully, so this
is safe to put on a timer without filling your logs with things that look like
failures.

### Why later passes are cheap

Every change is written to the write-ahead log before it reaches the database
file. Replication copies frames out of that log, so a pass has to move only what
was actually written, not the whole database again.

### Generations

Every so often LatticeDB folds pending changes into the database file and starts
the log over. By default this happens once the log reaches a thousand frames, and
again whenever the database closes.

When the log starts over, frame numbering restarts from zero. Frame 40 before the
reset and frame 40 after it are completely different changes, so replication
cannot simply keep counting. Instead it starts a **generation**: a fresh full
snapshot, followed by the changes that came after it.

You will see this in the destination:

```text
/mnt/backup/social/manifest.json
/mnt/backup/social/gen-0000000001/snapshot.lattice
/mnt/backup/social/gen-0000000001/frames/0000000012-0000000016.frames
/mnt/backup/social/gen-0000000002/snapshot.lattice
```

Older generations are kept rather than cleaned up, because restoring to a moment
inside one still needs its frames. If you want to reclaim the space, deleting a
whole `gen-` directory costs you the ability to restore to any moment inside it
and nothing else.

### Replicating a database your application is using

`lattice replicate` opens the database, and a database can only be open in one
process at a time. Point it at a database your application has open and it will
refuse to start, rather than corrupt anything:

```text
Error: social.lattice is open in another process. Close it first, or pass
--no-lock if you are certain nothing is writing to it.
```

That makes the command right for a database nothing else is using. For the case
people most often want, which is replicating while an application runs, call
`replicateTo` on the handle your application already has:

```zig
// Somewhere on a timer inside your application.
const stats = try db.replicateTo("/mnt/backup/social");
```

This lives on the database rather than in a separate process for a concrete
reason. A generation opens with a snapshot, a snapshot has to be taken with no
writes in flight, and only the handle that owns the database can arrange that.
Reading the log from another process is perfectly safe; taking the snapshot is
not.

Do not reach for `--no-lock` to work around this. It exists for filesystems where
locking does not work, and it does not make two processes safe — it only removes
the thing that was going to tell you they were not.

## Getting a database back

`restore` turns a replication directory back into a database:

```bash
lattice restore /mnt/backup/social --output=recovered.lattice
```

```text
Restored /mnt/backup/social to recovered.lattice
  Generation:      1
  Segments:        2
  Frames replayed: 20
  Bytes written:   73728
  Restored to:     2026-08-25T22:44:18Z
  Duration:        468 ms
```

It copies the snapshot, replays the changes shipped after it, and folds the
result into a single file. What you get back is a database you can open, copy, or
move, with nothing beside it that has to be kept together with it.

Restore will not write over an existing file unless you pass `--force`, because
the thing most likely to be sitting at the output path is a database somebody
still wants.

### Going back to an earlier moment

```bash
lattice restore /mnt/backup/social --output=recovered.lattice --at="2026-08-25T14:00:00Z"
```

Times are read as UTC, so a restore means the same thing wherever you run it. A
bare date works too and means midnight.

What you get is the state as of the last replication pass at or before the moment
you asked for, not the state at that exact instant. If you replicate every thirty
seconds, you can rewind to within thirty seconds. That is why the output reports
the moment it actually restored to instead of repeating the one you asked for:
those two are rarely the same, and the difference is the thing you need to know.

### Why restore reuses recovery

Restore does not have its own replay logic. It rebuilds a log from what was
shipped and then opens the database, which replays it exactly the way recovery
replays a log after a crash.

That is deliberate. Replaying log records is subtle, and a second implementation
would drift away from the real one over time. If recovery has a bug, restore
should have the same bug rather than a different one.

## Choosing a strategy

| What you want | What to use |
|---------------|-------------|
| A copy before an upgrade or a risky migration | `lattice backup` |
| A nightly snapshot | `lattice backup` from cron |
| To lose no more than a few seconds of work | `replicateTo` on a timer in your application |
| To mirror a database nothing else has open | `lattice replicate --follow` |
| To undo a bad migration or a bad delete | `lattice restore --at=...` |

## What this is not

This is backup and restore. It is not high availability, and it is not
clustering. There is no failover, no leader election, and no second writer. A
restored database is a database you open yourself, on purpose, after deciding
that you need it.

Replicating to object storage such as S3 is not supported yet. The destination
layout was designed with it in mind — whole files, written once, named rather
than modified, with a manifest listing them — so a directory you replicate to
today can be copied to a bucket by any tool you already trust.

## Related reading

- [Transactions and Durability](./transactions.md) for what "committed" means
- [The `lattice` Command](../getting-started/cli.md) for every option these
  commands take
