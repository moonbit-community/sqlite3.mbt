///|
test "extended error codes retain the SQLite constraint subtype" {
  let code = Ref(0)
  let database = @ffi.sqlite3_open_v2(b":memory:", 0x10006, code)
  assert_eq(code.val, 0)
  defer @ffi.sqlite3_close(database) |> ignore
  for
    (sql, expected) in [
      ("CREATE TABLE t(value UNIQUE)", 101),
      ("INSERT INTO t VALUES (1)", 101),
      ("INSERT INTO t VALUES (1)", 19),
    ] {
    let code = Ref(0)
    let tail = Ref(-1)
    let statement = @ffi.sqlite3_prepare16_v2(database, sql, tail, code)
    defer @ffi.sqlite3_finalize(statement) |> ignore
    assert_eq(code.val, 0)
    assert_eq(@ffi.sqlite3_step(statement), expected)
  }
  assert_eq(@ffi.sqlite3_errcode(database), 19)
  assert_eq(@ffi.sqlite3_extended_errcode(database), 2067)
}
