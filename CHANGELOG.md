# Changelog

## Unreleased

## 0.2.5 - 2026-11-12

### Changed

- Remove the `moonbitlang/core/lexbuf` dependency while preserving trailing
  whitespace, semicolon, and comment handling in `Connection::prepare` and
  `Connection::prepare_async`.

## 0.2.4

### Added

- Add `Connection::prepare_next` and `Connection::prepare_next_async` to prepare
  one SQL statement and return its unconsumed remainder for script execution.

### Changed

- Update `moonbitlang/async` from `0.22.4` to `0.22.7`.

## 0.2.3

### Changed

- Update `moonbitlang/async` from `0.21.2` to `0.22.4`.

## 0.2.2

### Added

- Add `Connection::open_async`, `Connection::prepare_async`, and
  `Statement::step_async` for native and Wasm targets, using
  `moonbitlang/async` `0.21.2`.
- Add `StepResult` to distinguish rows from completion and report the affected
  row count for asynchronous writes.

### Fixed

- Serialize connection operations so execution, error messages, and change
  counts remain consistent when synchronous and asynchronous calls share a
  connection.
- Release unclaimed connections and statements when asynchronous operations are
  cancelled or prepared statements are rejected.

## 0.2.1

### Added

- Add `Statement::reset`, with optional binding cleanup, to reuse prepared
  statements.
- Add `Statement::column_count` and `Statement::column_name` for result metadata.
- Add `Connection::changes` to read the affected row count.

## 0.2.0

### Added

- Add `Value` for dynamically typed SQLite values, including SQL `NULL`.
- Support binding `StringView` and `BytesView` without copying their selected
  ranges into standalone strings or byte arrays first.

### Changed

- Replace numeric errors with `SqliteError(code~, extended~, msg~)`, using
  `ErrorCode` and `ExtendedCode` to preserve SQLite diagnostics.
- Make column reads raise `SqliteError` for invalid indexes, missing current
  rows, or closed and finalized handles.

### Removed

- Remove public `SQLITE_*` constants and `Connection::get_errmsg`; use the
  structured error fields instead.
- Remove `Statement::step_once`; use `Statement::step` and check its result.
- Remove `Column` support for `Int`; read SQLite integers as `Int64`.

### Fixed

- Preserve the original SQLite storage class when typed and dynamic column reads
  are mixed within a row.
- Report text and BLOB conversion allocation failures without mistaking an older
  connection error for a new failure.

## 0.1.7

### Added

- Add a Wasm backend through moonrun's SQLite host APIs, including in-memory and
  file-backed databases subject to host filesystem permissions.

### Changed

- Use UTF-16LE SQLite APIs for SQL and text on native targets.
- Require explicit `Connection::close` and `Statement::finalize` on every
  backend; copies share resource state and reject use after release.
- Require `Connection::prepare` to contain exactly one statement, allowing
  trailing whitespace, semicolons, and comments while rejecting empty SQL,
  embedded NULs, and additional statements.

## 0.1.6

### Changed

- Migrate module metadata to `moon.mod` and update trait implementations,
  error declarations, and generated interfaces for MoonBit compiler changes.

## 0.1.5

### Added

- Expand the README with tested examples for prepared statements, text and BLOB
  values, error handling, and resource management.

### Changed

- Update the native backend configuration for MoonBit build tooling.

## 0.1.4

### Changed

- Add the package description to module metadata.

## 0.1.3

### Added

- Support `String` through `Bind` and `Column` as SQLite `TEXT`.

### Changed

- Wrap native SQLite handles in internal FFI objects with automatic finalizers.

### Removed

- Remove `Statement::bind_string_as_blob` and `Statement::column_blob_as_string`;
  use normal `String` or `Bytes` binding and column access instead.

## 0.1.2

### Changed

- Rename the module from `myfreess/sqlite3` to `moonbit-community/sqlite3`.
- Move the package to the repository root and make bound values positional
  arguments while retaining the labeled parameter index.

### Fixed

- Free the temporary connection reference after reading the opened handle.

## 0.1.1

### Changed

- Replace the `tonyfettes/encoding` dependency with core UTF-8 encoding support.
- Update native FFI borrow annotations for MoonBit compiler compatibility.

## 0.1.0

### Added

- Introduce native SQLite bindings for opening connections, preparing statements,
  binding values, stepping through results, and reading columns.
- Bundle SQLite `3.49.1` so the native package does not require a system SQLite
  installation.
