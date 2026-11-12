# Changelog

## 0.2.5 (Unreleased)

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
