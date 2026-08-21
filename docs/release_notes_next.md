# LatticeDB Next Release Notes

Use this file as the draft for the next release after `0.10.0`.

## Summary

This release fixes query correctness. Boolean operators bound more tightly than
comparison, which made almost every compound `WHERE` clause fail; the
subtraction and negation operators were unreachable because the parser matched a
token the lexer never produces; and every left-pointing relationship pattern
returned no rows at all. It also corrects `lattice info`, which described the
handle's configuration rather than the database file.

## Highlights

- `AND`, `OR`, and `XOR` now bind correctly relative to comparison operators.
  Previously `WHERE a > 1 AND b = 2` parsed as `a > (1 AND b = 2)` and failed
  with `invalid_operator_types`. Every compound predicate joining two
  comparisons was affected, including the examples in the Cypher documentation.
  Wrapping each comparison in parentheses was the only way to write one.
- Subtraction and unary negation work. `10 - 2`, `10 - 2 - 3`, and `-5` all
  previously failed to parse. The lexer emits `dash` for `-`, but the expression
  parser matched `minus`, which nothing ever produces, so both operators were
  dead code.
- Left-pointing relationship patterns work. `MATCH (a)<-[:KNOWS]-(b)`,
  `MATCH (a)<-[r]-(b)`, and `MATCH (a)<--(b)` previously matched nothing at all,
  silently, on any graph. The expand operator picked its edge iterator from a
  flag that only tracks the second half of an undirected traversal, so a plain
  incoming expand read an empty list and produced no rows. Undirected and
  variable-length patterns were unaffected, which is why the gap survived: half
  the traversal syntax returned wrong answers rather than errors.
- `lattice info` reports whether the database file has a vector index and
  full-text search, instead of reporting the default configuration of the handle
  used to open it. It previously said `Vector: disabled` for every database, and
  `FTS: enabled` even for one created with `--no-fts`.

## API Notes

- New `Database.hasPersistedVectorIndex()` and `Database.hasPersistedFtsIndex()`
  report what a database file contains rather than how the current handle was
  opened. Both read the file header.
- Python's `Node.get_property` and `Edge.get_property` now document that they
  read the object's local property dictionary and do not go to storage. Nodes
  returned by `Transaction.get_node` carry an empty dictionary, so reading a
  stored property still requires `Transaction.get_property`. This is a
  documentation change; the behaviour is unchanged.

## Upgrade Notes

- Queries that added parentheses purely to work around the precedence bug
  continue to work unchanged; the parentheses are now redundant rather than
  required.
- Any code that avoided compound `WHERE` clauses or subtraction in Cypher can be
  simplified, as can any workaround that rewrote a left-pointing pattern as a
  right-pointing one with the endpoints swapped.
- `lattice info` output changes for existing databases. Scripts that parse
  `vector_enabled` or `fts_enabled` from the JSON or CSV output will now see the
  file's real state, which means `vector_enabled` becomes true for databases
  that have a vector index rather than always being false.

## Validation Notes

- `zig build test` passed, including the 4 KiB and 32 KiB conversation-storage
  matrices.
- `zig build fuzz` passed.
- TypeScript: 90 tests passed. Go binding and Go conformance suites passed.
- Container integration has not been run locally; it needs Linux and is covered
  by CI.
- `zig build integration-test` passed all 199 integration tests.
- `zig build crash-test` passed.
- Python: 121 tests passed.
- One integration assertion was corrected. `database_test.zig` expected a
  disjunction over an indexed property to return zero rows, which only held
  because the malformed parse evaluated to false for every row. It now expects
  the two rows that actually match. The surrounding comment claimed the block
  proved the planner selects the property index by hiding rows from the label
  index; that is not what it proved, because `LabelScan` resolves nodes through
  `getNodesByLabelIdInTxn`, which walks visible nodes and reads each node's own
  label list rather than consulting `label_index`. The comment now says so.
