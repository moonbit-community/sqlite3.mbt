///|
fn open_memory_rows() -> @sqlite3.Connection raise @sqlite3.SqliteError {
  @sqlite3.Connection::open(":memory:")
}

///|
fn seed_people(conn : @sqlite3.Connection) -> Unit raise {
  let _ = conn.execute(
    "CREATE TABLE people (id INTEGER, name TEXT, score REAL)",
  )
  let _ = conn.execute("INSERT INTO people VALUES (?, ?, ?)", params=[
    @sqlite3.Value::Integer(1),
    @sqlite3.Value::Text("Ada"),
    @sqlite3.Value::Real(99.5),
  ])
  let _ = conn.execute("INSERT INTO people VALUES (?, ?, ?)", params=[
    @sqlite3.Value::Integer(2),
    @sqlite3.Value::Text("Grace"),
    @sqlite3.Value::Real(88.0),
  ])
}

///|
test "execute returns changed row count" {
  let conn = open_memory_rows()
  let _ = conn.execute("CREATE TABLE t (id INTEGER)")
  let changed = conn.execute("INSERT INTO t VALUES (?)", params=[
    @sqlite3.Value::Integer(1),
  ])
  assert_eq(changed, 1L)
  let changed = conn.execute("UPDATE t SET id = 2")
  assert_eq(changed, 1L)
  let changed = conn.execute("DELETE FROM t WHERE id = 2")
  assert_eq(changed, 1L)
  conn.close()
}

///|
test "query collects snapshot rows with names and values" {
  let conn = open_memory_rows()
  seed_people(conn)
  let rows = conn.query("SELECT id, name, score FROM people ORDER BY id")
  assert_eq(rows.length(), 2)
  let first = rows[0]
  assert_eq(first.column_count(), 3)
  assert_eq(first.name(index=0), "id")
  assert_eq(first.name(index=1), "name")
  assert_eq(first.get_int(index=0), 1L)
  assert_eq(first.get_text(index=1), "Ada")
  assert_eq(first.get_real(index=2), 99.5)
  conn.close()
}

///|
test "rows stay valid after statement lifetime ends" {
  let conn = open_memory_rows()
  seed_people(conn)
  // query 内部已经 finalize 了语句;快照仍可读
  let rows = conn.query("SELECT id, name FROM people ORDER BY id")
  conn.close()
  assert_eq(rows[1].get_text(index=1), "Grace")
  assert_eq(rows[1].get_by_name(name="name"), @sqlite3.Value::Text("Grace"))
}

///|
test "get_by_name and index_of resolve columns" {
  let conn = open_memory_rows()
  seed_people(conn)
  let row = conn.query("SELECT id, name, score FROM people ORDER BY id")[1]
  assert_eq(row.index_of(name="score"), Some(2))
  assert_eq(row.index_of(name="missing"), None)
  assert_eq(row.get_by_name(name="id"), @sqlite3.Value::Integer(2))
  let outcome = try {
    let _ = row.get_by_name(name="nope")
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("unknown column should raise")
  }
  conn.close()
}

///|
test "typed accessors are strict about storage class" {
  let conn = open_memory_rows()
  let _ = conn.execute("CREATE TABLE t (a INTEGER, b TEXT)")
  let _ = conn.execute("INSERT INTO t VALUES (5, 'x')")
  let row = conn.query("SELECT a, b FROM t")[0]
  assert_eq(row.get_int(index=0), 5L)
  assert_eq(row.get_text(index=1), "x")
  // 类型不匹配:严格报错而不是静默转换
  let outcome = try {
    let _ = row.get_text(index=0)
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("get_text on INTEGER should raise")
  }
  let outcome = try {
    let _ = row.get_int(index=1)
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("get_int on TEXT should raise")
  }
  // 越界
  let outcome = try {
    let _ = row.get_int(index=9)
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("out-of-range index should raise")
  }
  conn.close()
}

///|
test "bind_all binds positional parameters in order" {
  let conn = open_memory_rows()
  let _ = conn.execute("CREATE TABLE t (a INTEGER, b TEXT, c BLOB)")
  let stmt = conn.prepare("INSERT INTO t VALUES (?, ?, ?)")
  stmt.bind_all([
    @sqlite3.Value::Integer(3),
    @sqlite3.Value::Text("blob-ish"),
    @sqlite3.Value::Blob(b"\x01\x02\x03"),
  ])
  assert_eq(stmt.step(), false)
  stmt.finalize()
  let row = conn.query("SELECT a, b, c FROM t")[0]
  assert_eq(row.get_int(index=0), 3L)
  assert_eq(row.get_text(index=1), "blob-ish")
  assert_eq(row.get_blob(index=2).length(), 3)
  conn.close()
}

///|
test "row() rejects when no row is current" {
  let conn = open_memory_rows()
  let _ = conn.execute("CREATE TABLE t (id INTEGER)")
  let stmt = conn.prepare("SELECT id FROM t")
  // 尚未 step:没有当前行
  let outcome = try {
    let _ = stmt.row()
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("row() before step should raise")
  }
  stmt.finalize()
  conn.close()
}

///|
test "null values round-trip through snapshots" {
  let conn = open_memory_rows()
  let _ = conn.execute("CREATE TABLE t (a INTEGER)")
  let _ = conn.execute("INSERT INTO t VALUES (NULL)")
  let row = conn.query("SELECT a FROM t")[0]
  assert_eq(row.get(index=0), @sqlite3.Value::Null)
  conn.close()
}
