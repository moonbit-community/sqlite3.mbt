///|
fn open_memory() -> @sqlite3.Connection raise @sqlite3.SqliteError {
  @sqlite3.Connection::open(":memory:")
}

///|
test "transaction commit persists changes" {
  let conn = open_memory()
  let _ = conn.execute("CREATE TABLE t (id INTEGER)")
  let txn = conn.transaction()
  let _ = conn.execute("INSERT INTO t VALUES (1)")
  let _ = conn.execute("INSERT INTO t VALUES (2)")
  txn.commit()
  assert_eq(conn.query("SELECT COUNT(*) AS n FROM t")[0].get_int(index=0), 2L)
  conn.close()
}

///|
test "transaction rollback restores prior state" {
  let conn = open_memory()
  let _ = conn.execute("CREATE TABLE t (id INTEGER)")
  let _ = conn.execute("INSERT INTO t VALUES (1)")
  let txn = conn.transaction()
  let _ = conn.execute("DELETE FROM t")
  let _ = conn.execute("INSERT INTO t VALUES (99)")
  txn.rollback()
  assert_eq(conn.query("SELECT COUNT(*) AS n FROM t")[0].get_int(index=0), 1L)
  assert_eq(conn.query("SELECT id FROM t")[0].get_int(index=0), 1L)
  conn.close()
}

///|
test "transaction modes produce valid BEGIN statements" {
  let conn = open_memory()
  let _ = conn.execute("CREATE TABLE t (id INTEGER)")
  let txn = conn.transaction(mode=@sqlite3.TransactionMode::Immediate)
  let _ = conn.execute("INSERT INTO t VALUES (1)")
  txn.commit()
  let txn = conn.transaction(mode=@sqlite3.TransactionMode::Exclusive)
  txn.rollback()
  let txn = conn.transaction(mode=@sqlite3.TransactionMode::Deferred)
  txn.commit()
  assert_eq(conn.query("SELECT COUNT(*) AS n FROM t")[0].get_int(index=0), 1L)
  conn.close()
}

///|
test "nested transaction is a misuse error" {
  let conn = open_memory()
  let _ = conn.execute("CREATE TABLE t (id INTEGER)")
  let txn = conn.transaction()
  let outcome = try {
    let _ = conn.transaction()
    stmt_finalize_leak_guard(conn)
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(error) =>
      match error {
        @sqlite3.SqliteError::SqliteError(code~, ..) =>
          assert_eq(code, @sqlite3.ErrorCode::Misuse)
        _ => fail("expected a misuse error for nested BEGIN")
      }
    Ok(_) => fail("nested transaction should have been rejected")
  }
  txn.rollback()
  conn.close()
}

///|
/// 兜底:确保嵌套测试里可能泄漏的内层事务句柄不会阻塞 close。
fn stmt_finalize_leak_guard(conn : @sqlite3.Connection) -> Unit raise {
  let _ = conn.query("SELECT 1")
}

///|
test "double commit and double rollback are misuse errors" {
  let conn = open_memory()
  let _ = conn.execute("CREATE TABLE t (id INTEGER)")
  let txn = conn.transaction()
  txn.commit()
  let outcome = try {
    txn.commit()
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("double commit should have been rejected")
  }
  let txn = conn.transaction()
  txn.rollback()
  let outcome = try {
    txn.rollback()
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("double rollback should have been rejected")
  }
  conn.close()
}

///|
test "with_transaction commits on success" {
  let conn = open_memory()
  let _ = conn.execute("CREATE TABLE t (id INTEGER)")
  let written = conn.with_transaction(() => {
    let _ = conn.execute("INSERT INTO t VALUES (7)")
    "done"
  })
  assert_eq(written, "done")
  assert_eq(conn.query("SELECT COUNT(*) AS n FROM t")[0].get_int(index=0), 1L)
  conn.close()
}

///|
test "with_transaction rolls back and re-raises on failure" {
  let conn = open_memory()
  let _ = conn.execute("CREATE TABLE t (id INTEGER)")
  let _ = conn.execute("INSERT INTO t VALUES (1)")
  let outcome = try {
    conn.with_transaction(() => {
      let _ = conn.execute("INSERT INTO t VALUES (99)")
      fail("boom")
    })
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("body error should propagate")
  }
  // 回滚生效:body 内的插入消失,先前数据保留
  assert_eq(conn.query("SELECT COUNT(*) AS n FROM t")[0].get_int(index=0), 1L)
  // 事务槽已释放:可以立即开启下一个事务
  let _ = conn.with_transaction(() => {
    let _ = conn.execute("INSERT INTO t VALUES (2)")
    ()
  })
  assert_eq(conn.query("SELECT COUNT(*) AS n FROM t")[0].get_int(index=0), 2L)
  conn.close()
}

///|
test "transaction refused after connection close" {
  let conn = open_memory()
  conn.close()
  let outcome = try {
    let _ = conn.transaction()
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("transaction on closed connection should fail")
  }
}
