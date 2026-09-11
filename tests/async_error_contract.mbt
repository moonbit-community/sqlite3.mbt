// Used by scripts/test-wasm-errors.py with injected FFI failures. The public
// operations and the runtime still execute their real lifecycle and cleanup.
// Keep cases sequential: the injected fault state belongs to the Wasm instance.

///|
async test "async I/O error contract" {
  // open translates pipe creation and worker errors
  for fault in [-1, 1] {
    @ffi.sqlite3_test_fail_after(fault)
    try @sqlite3.Connection::open_async(":memory:") catch {
      @sqlite3.SqliteError(code=IoErr, msg~, ..) =>
        assert_true(msg.length() > 0)
      error => fail("expected SqliteError(IoErr), got \{error}")
    } noraise {
      connection => {
        connection.close()
        fail("expected injected open failure")
      }
    }
    // A failed open must not leave its executor or completion reader alive.
    let connection = @sqlite3.Connection::open_async(":memory:")
    connection.close()
  }

  // prepare translates pipe creation and worker errors
  for fault in [-1, 1] {
    let connection = @sqlite3.Connection::open(":memory:")
    defer connection.close()
    @ffi.sqlite3_test_fail_after(fault)
    try connection.prepare_async("SELECT 42") catch {
      @sqlite3.SqliteError(code=IoErr, msg~, ..) =>
        assert_true(msg.length() > 0)
      error => fail("expected SqliteError(IoErr), got \{error}")
    } noraise {
      statement => {
        statement.finalize()
        fail("expected injected prepare failure")
      }
    }
    let statement = connection.prepare_async("SELECT 42")
    defer statement.finalize()
    assert_eq(statement.step_async(), @sqlite3.StepResult::Row)
    let value : Int64 = statement.column(index=0)
    assert_eq(value, 42L)
  }

  // step translates pipe creation and worker errors
  for fault in [-1, 1] {
    let connection = @sqlite3.Connection::open(":memory:")
    defer connection.close()
    let statement = connection.prepare("SELECT 42")
    defer statement.finalize()
    @ffi.sqlite3_test_fail_after(fault)
    try statement.step_async() catch {
      @sqlite3.SqliteError(code=IoErr, msg~, ..) =>
        assert_true(msg.length() > 0)
      error => fail("expected SqliteError(IoErr), got \{error}")
    } noraise {
      _ => fail("expected injected step failure")
    }
    // Both the connection job count and statement's in-flight flag must reset.
    statement.reset()
    assert_eq(statement.step_async(), @sqlite3.StepResult::Row)
    let value : Int64 = statement.column(index=0)
    assert_eq(value, 42L)
  }

  // rejected prepare translates disposal worker errors
  {
    let connection = @sqlite3.Connection::open(":memory:")
    defer connection.close()
    // The first completion belongs to prepare; the second is its discard job.
    @ffi.sqlite3_test_fail_after(2)
    try connection.prepare_async("SELECT 1; SELECT 2") catch {
      @sqlite3.SqliteError(code=IoErr, msg~, ..) =>
        assert_true(msg.length() > 0)
      error => fail("expected SqliteError(IoErr), got \{error}")
    } noraise {
      statement => {
        statement.finalize()
        fail("expected injected disposal failure")
      }
    }
    let statement = connection.prepare_async("SELECT 42")
    defer statement.finalize()
    assert_eq(statement.step_async(), @sqlite3.StepResult::Row)
  }

  // A cancelled open also disposes of its unclaimed result on the worker.
  @ffi.sqlite3_test_fail_after(2)
  let started = @async.Semaphore(1, initial_value=0)
  let continue_open = @async.Semaphore(1, initial_value=0)
  let caught_io_error = Ref(false)
  @async.with_task_group() <| group => {
    let task = group.spawn(allow_failure=true) <| () => {
      @async.protect_from_cancel() <| () => {
        started.release()
        continue_open.acquire()
      }
      try @sqlite3.Connection::open_async(":memory:") catch {
        @sqlite3.SqliteError(code=IoErr, ..) => caught_io_error.val = true
        error => fail("expected SqliteError(IoErr), got \{error}")
      } noraise {
        connection => {
          connection.close()
          fail("expected injected disposal failure")
        }
      }
    }
    started.acquire()
    task.cancel()
    continue_open.release()
    task.wait() catch {
      error if @async.is_cancellation_error(error) => ()
      error => raise error
    }
  }
  assert_true(caught_io_error.val)
}
