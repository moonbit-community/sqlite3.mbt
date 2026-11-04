///|
async test "execute_batch handles migration triggers and drains result rows" {
  for asynchronous in [false, true] {
    let connection = @sqlite3.Connection::open(":memory:")
    let sql =
      #|CREATE TABLE src(v TEXT);
      #|CREATE TABLE audit(v TEXT);
      #|CREATE TRIGGER src_audit AFTER INSERT ON src BEGIN
      #|  INSERT INTO audit VALUES (new.v);
      #|  INSERT INTO audit VALUES (new.v || '!');
      #|END;
      #|INSERT INTO src VALUES ('a;b') RETURNING v;
      #|SELECT v FROM audit;
      #|/* outer /* inner */ INSERT INTO src VALUES ('c'';d');
      #|-- trailing comment
    if asynchronous {
      connection.execute_batch_async(sql)
    } else {
      connection.execute_batch(sql)
    }
    let statement = connection.prepare("SELECT v FROM audit ORDER BY rowid")
    let rows : Array[String] = []
    while statement.step() {
      rows.push(statement.column(index=0))
    }
    assert_eq(rows, ["a;b", "a;b!", "c';d", "c';d!"])
    statement.finalize()
    connection.close()
  }
}

///|
async test "execute_batch handles empty scripts and rejects NUL before execution" {
  for asynchronous in [false, true] {
    let connection = @sqlite3.Connection::open(":memory:")
    for sql in ["", " ; -- comment\n /* done */ ;"] {
      if asynchronous {
        connection.execute_batch_async(sql)
      } else {
        connection.execute_batch(sql)
      }
    }
    let sql = "CREATE TABLE forbidden(v);\u0000SELECT 1"
    try {
      if asynchronous {
        connection.execute_batch_async(sql)
      } else {
        connection.execute_batch(sql)
      }
    } catch {
      @sqlite3.SqliteError(code=Misuse, ..) => ()
      error => raise error
    } noraise {
      _ => fail("expected NUL to fail")
    }
    let statement = connection.prepare(
      "SELECT count(*) FROM sqlite_schema WHERE name = 'forbidden'",
    )
    assert_true(statement.step())
    let count : Int64 = statement.column(index=0)
    assert_eq(count, 0L)
    statement.finalize()
    connection.close()
    try {
      if asynchronous {
        connection.execute_batch_async("")
      } else {
        connection.execute_batch("")
      }
    } catch {
      @sqlite3.SqliteError(code=Misuse, ..) => ()
      error => raise error
    } noraise {
      _ => fail("expected closed connection to fail")
    }
  }
}

///|
async test "execute_batch stops on prepare and step errors without leaking statements" {
  for asynchronous in [false, true] {
    for
      (failure, expected) in [
        ("INSERT INTO entries VALUES (1)", @sqlite3.ErrorCode::Constraint),
        ("SELECT FROM", @sqlite3.ErrorCode::Error),
      ] {
      let connection = @sqlite3.Connection::open(":memory:")
      let sql = "CREATE TABLE entries(v UNIQUE); INSERT INTO entries VALUES (1); " +
        failure +
        "; INSERT INTO entries VALUES (2);"
      try {
        if asynchronous {
          connection.execute_batch_async(sql)
        } else {
          connection.execute_batch(sql)
        }
      } catch {
        @sqlite3.SqliteError(code~, msg~, ..) => {
          assert_eq(code, expected)
          if code == Constraint {
            assert_true(msg.contains("UNIQUE constraint failed"))
          } else {
            assert_true(msg.contains("syntax error"))
          }
        }
        error => raise error
      } noraise {
        _ => fail("expected batch to fail")
      }
      let statement = connection.prepare("SELECT v FROM entries")
      assert_true(statement.step())
      let value : Int64 = statement.column(index=0)
      assert_eq(value, 1L)
      assert_eq(statement.step(), false)
      statement.finalize()
      connection.close()
    }
  }
}

///|
async test "execute_batch leaves transaction ownership with the caller" {
  for asynchronous in [false, true] {
    let connection = @sqlite3.Connection::open(":memory:")
    connection.execute_batch("CREATE TABLE entries(v UNIQUE); BEGIN;")
    if asynchronous {
      connection.execute_batch_async("INSERT INTO entries VALUES (1)")
    } else {
      connection.execute_batch("INSERT INTO entries VALUES (1)")
    }
    // A successful batch must not commit an existing transaction.
    connection.execute_batch("ROLLBACK")
    let sql = "BEGIN; INSERT INTO entries VALUES (2); INSERT INTO entries VALUES (2); COMMIT;"
    try {
      if asynchronous {
        connection.execute_batch_async(sql)
      } else {
        connection.execute_batch(sql)
      }
    } catch {
      @sqlite3.SqliteError(code=Constraint, ..) => ()
      error => raise error
    } noraise {
      _ => fail("expected duplicate to fail")
    }
    // A failed batch must neither reach COMMIT nor roll back on the caller's behalf.
    let pending = connection.prepare("SELECT v FROM entries")
    assert_true(pending.step())
    let value : Int64 = pending.column(index=0)
    assert_eq(value, 2L)
    pending.finalize()
    connection.execute_batch("ROLLBACK")
    let empty = connection.prepare("SELECT count(*) FROM entries")
    assert_true(empty.step())
    let count : Int64 = empty.column(index=0)
    assert_eq(count, 0L)
    empty.finalize()
    connection.close()
  }
}

///|
async test "execute_batch cancellation skips the remainder and releases its statement" {
  let connection = @sqlite3.Connection::open_async(":memory:")
  let sql =
    #|WITH RECURSIVE counter(value) AS (
    #|  VALUES(1)
    #|  UNION ALL
    #|  SELECT value + 1 FROM counter WHERE value < 1000000
    #|)
    #|SELECT sum(value) FROM counter;
    #|CREATE TABLE after_cancel(v);
  try @async.with_timeout(1, () => connection.execute_batch_async(sql)) catch {
    @async.TimeoutError => ()
    error => raise error
  } noraise {
    _ => fail("expected cancellation")
  }
  let statement = connection.prepare(
    "SELECT count(*) FROM sqlite_schema WHERE name = 'after_cancel'",
  )
  assert_true(statement.step())
  let count : Int64 = statement.column(index=0)
  assert_eq(count, 0L)
  statement.finalize()
  connection.execute_batch_async("CREATE TABLE after_reuse(v)")
  connection.close()
}
