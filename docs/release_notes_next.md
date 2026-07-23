# LatticeDB Next Release Notes

Use this file as the draft for the next release after `0.9.6`.

## Summary

This development cycle hardens write ownership, vector persistence, storage
reclamation, and the project quality gates. It also ships durable explicit
property equality indexes through the C, Python, and TypeScript APIs and teaches
the Cypher planner to use them for independent inline equality patterns.

## Highlights

- Database handles now enforce one active read-write transaction. A second
  writer receives the public contention error until the first commits or rolls
  back; read-only transactions may remain active.
- Vector replacement and HNSW rebuild paths reuse storage, reclaim stale and
  orphaned records, and reject corrupt persisted vector chains or HNSW state.
- Explicit node and edge property indexes are durable, maintained by direct and
  transactional mutations, rebuilt during recovery, and usable through direct
  lookup APIs or inline Cypher equality patterns.
- B+Tree deletes merge compatible sibling leaves, repair the leaf chain,
  collapse single-leaf roots, and return redundant pages to the freelist.
- Continuous fuzz targets and strict Python type checking are restored as
  executable quality gates.

## API Notes

- New C APIs create/drop scoped node and edge property indexes and perform
  required-index equality lookup. Python exposes snake-case equivalents;
  TypeScript exposes camel-case equivalents.
- Indexed lookup never silently scans. It reports the binding's unsupported
  error when the requested index definition is absent and requires a positive
  result limit.
- Schema index creation/drop is rejected while a write transaction is active.
- Database close ownership is consistent across bindings: a successful close
  consumes the native handle, while a failed close leaves it available for a
  retry instead of silently discarding ownership.
- The previously advertised but unavailable `lattice compact` command has been
  removed from parsing and help output.

## Upgrade Notes

- Zig 0.16.0 is now the declared minimum in `build.zig.zon`, matching CI,
  release workflows, and contributor documentation.
- Applications that attempted overlapping write transactions on one handle
  must serialize them and handle the public contention error.
- Property index creation scans existing matching records and adds maintenance
  work to subsequent mutations in that scope; create only indexes that serve a
  real lookup path.

## Validation Notes

- `zig build test`: 737 passed and 5 skipped, including focused
  page-reclamation coverage.
- Integration tests: 199 passed.
- Crash/recovery tests: 32 passed.
- Fuzz target tests: 65 passed.
- Python tests: 121 passed, with strict `mypy` passing for binding sources.
- TypeScript tests: 90 passed, plus build and lint.
