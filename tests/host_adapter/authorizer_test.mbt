///|
extern "c" fn authorizer() -> @ffi.Sqlite3Authorizer = "sqlite3_test_authorizer"

///|
extern "c" fn authorizer_context() -> @ffi.Sqlite3AuthorizerContext = "sqlite3_test_authorizer_context"

///|
fn open_database() -> @ffi.Sqlite3 raise {
  let code = Ref(0)
  let database = @ffi.sqlite3_open_v2(b":memory:", 0x10006, code)
  assert_eq(code.val, 0)
  database
}

///|
test "native authorizer receives its context and can be cleared" {
  let database = open_database()
  defer @ffi.sqlite3_close(database) |> ignore
  assert_eq(
    @ffi.sqlite3_set_authorizer(
      database,
      authorizer=authorizer(),
      context=authorizer_context(),
    ),
    0,
  )
  let tail = Ref(-1)
  let code = Ref(0)
  let query = @ffi.sqlite3_prepare16_v2(database, "SELECT 42", tail, code)
  assert_eq(code.val, 0)
  assert_eq(@ffi.sqlite3_step(query), 100)
  assert_eq(@ffi.sqlite3_finalize(query), 0)
  let rejected = @ffi.sqlite3_prepare16_v2(
    database, "ATTACH DATABASE ':memory:' AS extra", tail, code,
  )
  assert_eq(code.val, 23)
  assert_eq(@ffi.sqlite3_errcode(database), 23)
  @ffi.sqlite3_finalize(rejected) |> ignore
  assert_eq(@ffi.sqlite3_set_authorizer(database), 0)
  let allowed = @ffi.sqlite3_prepare16_v2(
    database, "ATTACH DATABASE ':memory:' AS extra", tail, code,
  )
  defer @ffi.sqlite3_finalize(allowed) |> ignore
  assert_eq(code.val, 0)
  assert_eq(@ffi.sqlite3_step(allowed), 101)
}

///|
async test "native authorizer works on the SQLite prepare worker" {
  let database = open_database()
  defer @ffi.sqlite3_close(database) |> ignore
  assert_eq(
    @ffi.sqlite3_set_authorizer(
      database,
      authorizer=authorizer(),
      context=authorizer_context(),
    ),
    0,
  )
  let code = Ref(0)
  let executor = @ffi.sqlite3_executor_create(code)
  assert_eq(code.val, 0)
  defer @ffi.sqlite3_executor_release(executor)
  let job = @ffi.sqlite3_prepare_job(
    executor, database, "ATTACH DATABASE ':memory:' AS extra", code,
  )
  defer job.release()
  assert_eq(code.val, 0)
  job.wait()
  let (result, extended, _, _) = job.result()
  assert_eq(result, 23)
  assert_eq(extended, 23)
}
