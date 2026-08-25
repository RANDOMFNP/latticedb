# LatticeDB 0.11.1 Release Notes

## Summary

`0.11.1` is a packaging-metadata release. It contains no code changes. The
Python package pointed at the GitHub repository as its homepage, so that is the
link PyPI showed first, and its documentation link pointed at the marketing site
rather than the documentation site.

Registry metadata is taken from the uploaded artifacts and cannot be amended
after a release, which is why correcting it needs a version of its own.

## Highlights

- The PyPI listing links to <https://latticedb.org> as its homepage, and to
  <https://docs.latticedb.org> for documentation. The repository and issue
  tracker are still linked, as Repository and Issues.

## API Notes

- None. No source, binding, or behaviour changes.

## Upgrade Notes

- Nothing to do. `0.11.1` is identical to `0.11.0` apart from package metadata,
  so there is no reason to upgrade except to land on the current version.

## Validation Notes

- `zig build test` passed, including the 4 KiB and 32 KiB conversation-storage
  matrices.
- `zig build integration-test` passed all integration tests.
- Python, TypeScript, and Go binding suites passed.
- Container integration has not been run locally; it needs Linux and is covered
  by CI.
