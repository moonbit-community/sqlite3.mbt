///|
async test "prepare_next preserves bounded UTF-16 views and parameter binding" {
  for asynchronous in [false, true] {
    let connection = @sqlite3.Connection::open(":memory:")
    let prefix = "\u0000🌙 ignored "
    let sql = "; /* lead */ SELECT ?1 AS [a;b]; SELECT '月🌙;'; -- tail"
    let backing = prefix + sql + "\u0000 SELECT 999"
    let input = backing[prefix.length():prefix.length() + sql.length()]
    let first = if asynchronous {
      connection.prepare_next_async(input)
    } else {
      connection.prepare_next(input)
    }
    guard first is Some((statement, remainder)) else {
      fail("missing statement")
    }
    assert_eq(remainder, " SELECT '月🌙;'; -- tail")
    assert_eq(remainder.data(), backing)
    statement.bind(index=1, 42L)
    assert_true(statement.step())
    let value : Int64 = statement.column(index=0)
    assert_eq(value, 42L)
    statement.finalize()

    let second = if asynchronous {
      connection.prepare_next_async(remainder)
    } else {
      connection.prepare_next(remainder)
    }
    guard second is Some((statement, remainder)) else {
      fail("missing statement")
    }
    assert_eq(remainder, " -- tail")
    assert_true(statement.step())
    let value : String = statement.column(index=0)
    assert_eq(value, "月🌙;")
    statement.finalize()
    let end = if asynchronous {
      connection.prepare_next_async(remainder)
    } else {
      connection.prepare_next(remainder)
    }
    assert_true(end is None)
    connection.close()
  }
}

///|
async test "prepare_next distinguishes empty input from invalid SQL" {
  for asynchronous in [false, true] {
    let connection = @sqlite3.Connection::open(":memory:")
    for sql in ["", " ; ; ", "-- comment", "/* outer /* inner */ ;"] {
      let result = try {
        if asynchronous {
          connection.prepare_next_async(sql[:])
        } else {
          connection.prepare_next(sql[:])
        }
      } catch {
        error => fail("empty input \{sql} (async=\{asynchronous}): \{error}")
      }
      assert_true(result is None)
    }
    for
      (sql, expected) in [
        ("SELECT FROM", @sqlite3.ErrorCode::Error),
        ("/*", @sqlite3.ErrorCode::Error),
        ("SELECT 1;\u0000SELECT 2", @sqlite3.ErrorCode::Misuse),
      ] {
      try {
        if asynchronous {
          connection.prepare_next_async(sql[:])
        } else {
          connection.prepare_next(sql[:])
        }
      } catch {
        @sqlite3.SqliteError(code~, msg~, ..) => {
          assert_eq(code, expected)
          assert_true(msg.length() > 0)
        }
        error => raise error
      } noraise {
        result => {
          if result is Some((statement, _)) {
            statement.finalize()
          }
          fail("expected invalid input to fail")
        }
      }
    }
    // Preparing the first statement must not parse the remainder prematurely.
    let result = if asynchronous {
      connection.prepare_next_async("SELECT 'a'';b'; SELECT FROM")
    } else {
      connection.prepare_next("SELECT 'a'';b'; SELECT FROM")
    }
    guard result is Some((statement, rest)) else { fail("missing statement") }
    assert_eq(rest, " SELECT FROM")
    assert_true(statement.step())
    let value : String = statement.column(index=0)
    assert_eq(value, "a';b")
    statement.finalize()
    connection.close()
    try {
      if asynchronous {
        connection.prepare_next_async("")
      } else {
        connection.prepare_next("")
      }
    } catch {
      @sqlite3.SqliteError(code=Misuse, ..) => ()
      error => raise error
    } noraise {
      _ => fail("expected closed connection to fail even for empty input")
    }
  }
}

///|
async test "prepare_next cancellation releases statements and handles empty input" {
  let connection = @sqlite3.Connection::open_async(":memory:")
  for sql in ["SELECT 42; SELECT 43", " -- comment"] {
    let started = @async.Semaphore(1, initial_value=0)
    let proceed = @async.Semaphore(1, initial_value=0)
    @async.with_task_group() <| group => {
      let task = group.spawn(allow_failure=true) <| () => {
        @async.protect_from_cancel() <| () => {
          started.release()
          proceed.acquire()
        }
        let result = connection.prepare_next_async(sql[:])
        if result is Some((statement, _)) {
          statement.finalize()
        }
        fail("expected cancellation after prepare completed")
      }
      started.acquire()
      task.cancel()
      proceed.release()
      task.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        error => raise error
      }
    }
  }
  // Closing would report SQLITE_BUSY if a cancelled prepare leaked a statement.
  connection.close()
}
