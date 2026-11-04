///|
struct Statement {
  mut handle : @ffi.Sqlite3Stmt?
  step_in_flight : Ref[Bool]
  mut has_row : Bool
  mut column_types : Array[Int32]?
  connection : Connection
}

///|
const SQLITE_NOMEM = 7

///|
fn Statement::ensure_not_in_flight(self : Statement) -> Unit raise SqliteError {
  if self.step_in_flight.val {
    raise sqlite_misuse("sqlite3: an asynchronous step is using this statement")
  }
}

///|
fn Statement::get_handle(
  self : Statement,
) -> @ffi.Sqlite3Stmt raise SqliteError {
  self.ensure_not_in_flight()
  let _ = self.connection.handle()
  match self.handle {
    Some(handle) => handle
    None => raise sqlite_misuse("sqlite3: statement is finalized")
  }
}

///|
fn Statement::column_info(
  self : Statement,
  index : Int32,
) -> (@ffi.Sqlite3Stmt, Int32) raise SqliteError {
  self.ensure_not_in_flight()
  let _ = self.connection.handle()
  match (self.handle, self.has_row) {
    (Some(handle), true) => {
      let column_count = @ffi.sqlite3_column_count(handle)
      if index < 0 || index >= column_count {
        raise sqlite_misuse(
          "sqlite3: column index \{index} is outside 0..<\{column_count}",
        )
      }
      // SQLite only guarantees the initial storage class before a coercing
      // accessor runs. Cache it on the first read of each cell so typed and
      // dynamic reads remain order-independent within the current row.
      let types = match self.column_types {
        Some(types) => types
        None => {
          let types = Array::make(column_count, 0)
          self.column_types = Some(types)
          types
        }
      }
      if types[index] == 0 {
        types[index] = @ffi.sqlite3_column_type(handle, index)
      }
      (handle, types[index])
    }
    (None, _) => raise sqlite_misuse("sqlite3: statement is finalized")
    _ => raise sqlite_misuse("sqlite3: statement has no current row")
  }
}

///|
fn Statement::error(self : Statement, raw_code : Int32) -> SqliteError {
  self.connection.error(raw_code)
}

///|
fn sql_tail_is_ignorable(sql : StringView) -> Bool {
  let scanner = @lexbuf.StringScanner::{ data: sql, cursor: 0, }
  for ;; {
    lexscan scanner with longest {
      re"^[ \t\n\f\r;\uFEFF]+" => continue
      re"^--[^\n]*(\n|$)" => continue
      re"^/[*]([^*]|[*]+[^*/])*[*]+/" => continue
      re"^/[*]([^*]|[*]+[^*/])*[*]*$" => return true
      re"^$" => return true
      _ => return false
    }
  }
}

///|
pub fn Connection::prepare(
  self : Connection,
  stmt : String,
) -> Statement raise SqliteError {
  guard self.prepare_impl(stmt[:], single=true) is Some((statement, _)) else {
    raise sqlite_misuse("sqlite3: SQL does not contain a statement")
  }
  statement
}

///|
/// Prepare the first SQL statement and return its unconsumed remainder.
///
/// Returns `None` when the input contains only whitespace, comments, or empty
/// semicolons. The remainder is a view into the original input and may itself
/// contain only comments. SQLite determines statement boundaries, including
/// semicolons inside strings and trigger bodies.
///
/// The caller must finalize each returned statement. When iterating a migration,
/// execute each statement before preparing the next: later statements may depend
/// on schema changes made by earlier ones. NUL code units are rejected.
pub fn Connection::prepare_next(
  self : Connection,
  sql : StringView,
) -> (Statement, StringView)? raise SqliteError {
  self.prepare_impl(sql, single=false)
}

///|
fn Connection::prepare_impl(
  self : Connection,
  sql : StringView,
  single~ : Bool,
) -> (Statement, StringView)? raise SqliteError {
  if sql.contains_code_unit(0x0000) {
    raise sqlite_misuse("sqlite3: SQL contains a NUL code unit")
  }
  let db = self.handle()
  @ffi.sqlite3_db_mutex_enter(db)
  defer @ffi.sqlite3_db_mutex_leave(db)
  let tail_offset = Ref(-1)
  let rescode = Ref(SQLITE_OK)
  let out = @ffi.sqlite3_prepare16_v2(db, sql, tail_offset, rescode)
  if rescode.val != SQLITE_OK {
    raise sqlite_error(rescode.val, @ffi.sqlite3_errmsg(db))
  }
  if tail_offset.val < 0 {
    return None
  }
  if tail_offset.val == 0 || tail_offset.val > sql.length() {
    let _ = @ffi.sqlite3_finalize(out)
    raise sqlite_misuse("sqlite3: invalid SQL tail offset")
  }
  let remainder = sql[tail_offset.val:]
  if single && !sql_tail_is_ignorable(remainder) {
    let _ = @ffi.sqlite3_finalize(out)
    raise sqlite_misuse("sqlite3: SQL contains more than one statement")
  }
  // Only a successful, non-empty prepare reaches this point. A handle from a
  // failed prepare is never stored in public Statement state.
  let statement = {
    handle: Some(out),
    step_in_flight: Ref(false),
    has_row: false,
    column_types: None,
    connection: self,
  }
  Some((statement, remainder))
}

///|
/// Reset the statement to its initial state so it can be executed again.
///
/// Existing parameter bindings are preserved unless `clear_bindings` is true.
/// The current row, if any, is invalidated even when SQLite reports an error
/// from the previous execution.
pub fn Statement::reset(
  self : Statement,
  clear_bindings~ : Bool = false,
) -> Unit raise SqliteError {
  let handle = self.get_handle()
  let database = self.connection.handle()
  @ffi.sqlite3_db_mutex_enter(database)
  defer @ffi.sqlite3_db_mutex_leave(database)
  self.has_row = false
  self.column_types = None
  let rescode = @ffi.sqlite3_reset(handle)
  // sqlite3_reset() can report an error from the previous execution even
  // though it has rewound the statement. Capture that error before clearing
  // bindings can replace the connection's error message.
  let reset_error = if rescode == SQLITE_OK {
    None
  } else {
    Some(self.error(rescode))
  }
  let clear_rescode = if clear_bindings {
    @ffi.sqlite3_clear_bindings(handle)
  } else {
    SQLITE_OK
  }
  match reset_error {
    Some(error) => raise error
    None => if clear_rescode != SQLITE_OK { raise self.error(clear_rescode) }
  }
}

///|
/// Return the number of columns in the statement's result set.
///
/// Statements that do not return rows have zero columns.
pub fn Statement::column_count(self : Statement) -> Int32 raise SqliteError {
  let handle = self.get_handle()
  let database = self.connection.handle()
  @ffi.sqlite3_db_mutex_enter(database)
  defer @ffi.sqlite3_db_mutex_leave(database)
  @ffi.sqlite3_column_count(handle)
}

///|
/// Return the name assigned to a result column.
///
/// Column indexes start at zero. An explicit SQL `AS` alias determines the
/// name when present.
pub fn Statement::column_name(
  self : Statement,
  index~ : Int32,
) -> String raise SqliteError {
  let handle = self.get_handle()
  let database = self.connection.handle()
  @ffi.sqlite3_db_mutex_enter(database)
  defer @ffi.sqlite3_db_mutex_leave(database)
  let column_count = @ffi.sqlite3_column_count(handle)
  if index < 0 || index >= column_count {
    raise sqlite_misuse(
      "sqlite3: column index \{index} is outside 0..<\{column_count}",
    )
  }
  match @ffi.sqlite3_column_name(handle, index) {
    Some(name) => name
    None =>
      raise sqlite_error(
        SQLITE_NOMEM,
        "sqlite3: failed to allocate result column name",
      )
  }
}

///|
pub fn[T : Bind] Statement::bind(
  self : Statement,
  index~ : Int32,
  val : T,
) -> Unit raise SqliteError {
  let _ = self.get_handle()
  let database = self.connection.handle()
  @ffi.sqlite3_db_mutex_enter(database)
  defer @ffi.sqlite3_db_mutex_leave(database)
  T::bind(self, index, val)
}

///|
pub fn[T : Column] Statement::column(
  self : Statement,
  index~ : Int32,
) -> T raise SqliteError {
  let _ = self.get_handle()
  let database = self.connection.handle()
  @ffi.sqlite3_db_mutex_enter(database)
  defer @ffi.sqlite3_db_mutex_leave(database)
  T::column(self, index)
}

///|
pub fn Statement::step(self : Statement) -> Bool raise SqliteError {
  let handle = self.get_handle()
  let database = self.connection.handle()
  @ffi.sqlite3_db_mutex_enter(database)
  defer @ffi.sqlite3_db_mutex_leave(database)
  self.has_row = false
  self.column_types = None
  let rescode = @ffi.sqlite3_step(handle)
  match rescode {
    SQLITE_DONE => false
    SQLITE_ROW => {
      self.has_row = true
      true
    }
    _ => raise self.error(rescode)
  }
}

///|
pub fn Statement::finalize(self : Statement) -> Unit raise SqliteError {
  self.ensure_not_in_flight()
  match self.handle {
    None => ()
    Some(handle) => {
      let database = self.connection.handle()
      @ffi.sqlite3_db_mutex_enter(database)
      defer @ffi.sqlite3_db_mutex_leave(database)
      // sqlite3_finalize consumes the statement even when it reports an error.
      self.handle = None
      self.has_row = false
      self.column_types = None
      let rescode = @ffi.sqlite3_finalize(handle)
      if rescode != SQLITE_OK {
        raise self.error(rescode)
      }
    }
  }
}
