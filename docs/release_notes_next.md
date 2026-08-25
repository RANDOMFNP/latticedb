# LatticeDB Next Release Notes

Use this file as the draft for the next release after `0.11.1`.

## Summary

Queued so far: `ORDER BY` can name a `RETURN` alias.

## Highlights

- `ORDER BY` accepts an alias introduced by `RETURN`, as in
  `RETURN count(d) AS papers ORDER BY papers DESC`. Sorting is planned before
  projection, so the alias was not a column yet and the query failed with
  "Variable 'papers' is not defined". The planner now substitutes the expression
  the alias stands for. Naming something that is neither a bound variable nor an
  alias is still an error.

## API Notes

- None yet.

## Upgrade Notes

- None yet.

## Validation Notes

- `zig build test` and `zig build integration-test` passed.
- Python, TypeScript, and Go binding suites passed.
