# LatticeDB 0.10.0 Release Notes

## Summary

`0.10.0` hardens write ownership, vector persistence, B+Tree deletion, physical
storage reclamation, and the project quality gates. It also ships durable
explicit property equality indexes through the C, Python, TypeScript, and Go
APIs and teaches the Cypher planner to use them for eligible inline and `WHERE`
equality patterns.

## Highlights

- Database handles now enforce one active read-write transaction. A second
  writer receives the public contention error until the first commits or rolls
  back; read-only transactions may remain active.
- Vector replacement and HNSW rebuild paths reuse storage, reclaim stale and
  orphaned records, and reject corrupt persisted vector chains or HNSW state.
- Explicit node and edge property indexes are durable, maintained by direct and
  transactional mutations, rebuilt during recovery, and usable through direct
  lookup APIs or inline and `WHERE` Cypher equality patterns.
- B+Tree deletes rebalance from the leaf through every internal level, merge or
  redistribute byte-variable pages, repair separator keys and the leaf chain,
  repeatedly collapse redundant roots, and return redundant pages to the
  freelist.
- `lattice compact <path>` now checkpoints the database and safely truncates
  contiguous free pages from the physical file tail. Interior free pages remain
  available for normal online reuse.
- Continuous fuzz targets and strict Python type checking are restored as
  executable quality gates.

## API Notes

- New C APIs create/drop scoped node and edge property indexes and perform
  required-index equality lookup. Python exposes snake-case equivalents;
  TypeScript and Go expose camel-case equivalents.
- Indexed lookup never silently scans. It reports the binding's unsupported
  error when the requested index definition is absent and requires a positive
  result limit.
- The Cypher planner recognizes direct and reversed label/property equality
  predicates in the `WHERE` immediately following `MATCH`, including eligible
  predicates inside conjunctions. It retains the ordinary filter as a semantic
  guard and does not unsafely narrow `OR` branches.
- Schema index creation/drop is rejected while a write transaction is active.
- Database close ownership is consistent across bindings: a successful close
  consumes the native handle, while a failed close leaves it available for a
  retry instead of silently discarding ownership.
- Physical compaction is rejected for read-only handles or while any
  transaction is active. The database header is synced before the file tail is
  truncated so an interrupted compaction remains recoverable.

## Upgrade Notes

- Zig 0.16.0 is now the declared minimum in `build.zig.zon`, matching CI,
  release workflows, and contributor documentation.
- Applications that attempted overlapping write transactions on one handle
  must serialize them and handle the public contention error.
- Property index creation scans existing matching records and adds maintenance
  work to subsequent mutations in that scope; create only indexes that serve a
  real lookup path.

## Validation Notes

- `zig build test` passed, including the 4 KiB and 32 KiB
  conversation-storage matrices.
- `zig build integration-test` passed all 199 integration tests.
- `zig build crash-test` and `zig build fuzz` passed on Linux and macOS.
- Container integration passed on Ubuntu 22.04, Ubuntu 24.04, Debian 12, and
  Fedora 41.
- Python: 121 tests passed; strict `mypy` and the CI `ruff` source check passed.
- TypeScript: 90 tests passed; build and lint passed.
- Go: the cgo binding suite and the portable engine conformance suite passed
  against the Zig 0.16 shared library.
