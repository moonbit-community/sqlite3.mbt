///|
/// The outcome of one asynchronous call to `Statement::step_async`.
///
/// `Done(changes=None)` means SQLite classified the statement as read-only.
/// For a potentially writing statement, `Done(changes=Some(count))` carries
/// the connection's direct row-change count captured before its mutex was
/// released.
pub(all) enum StepResult {
  Row
  Done(changes~ : Int64?)
} derive(Debug, Eq)

///|
// Translate I/O failures at each public operation's boundary, covering job
// construction, completion, and disposal. Cancellation remains an async error.
fn async_io_error(error : @os_error.OSError) -> SqliteError {
  sqlite_error(SQLITE_IOERR, "sqlite3: asynchronous operation failed: \{error}")
}

///|
/// Open a database without blocking the MoonBit event loop.
///
/// Later asynchronous operations on the connection execute in submission order.
pub async fn Connection::open_async(filename : String) -> Connection {
  try {
    if filename.contains_code_unit(0x0000) {
      raise sqlite_misuse("sqlite3: filename contains a NUL code unit")
    }
    let executor = create_executor()
    let mut executor_owned = true
    defer (if executor_owned { @ffi.sqlite3_executor_release(executor) })
    let flags = SQLITE_OPEN_READWRITE |
      SQLITE_OPEN_CREATE |
      SQLITE_OPEN_FULLMUTEX
    let submit_rescode = Ref(SQLITE_OK)
    let job = @ffi.sqlite3_open_job(
      executor,
      @utf8.encode(filename),
      flags,
      submit_rescode,
    )
    defer job.release()
    if submit_rescode.val != SQLITE_OK {
      raise sqlite_error(
        submit_rescode.val,
        "sqlite3: failed to submit asynchronous open",
      )
    }
    @async.protect_from_cancel(() => job.wait())
    let (rescode, extended_rescode, message) = job.result()
    if rescode != SQLITE_OK {
      raise sqlite_error(
        extended_rescode,
        if message == "" {
          "sqlite3: asynchronous open failed"
        } else {
          message
        },
      )
    }
    if @async.is_being_cancelled() {
      @async.protect_from_cancel(() => job.discard())
      @async.pause()
    }
    let database = job.take_database()
    executor_owned = false
    Connection::from_open_database(database, Some(executor))
  } catch {
    @os_error.OSError(_) as error => raise async_io_error(error)
    error => raise error
  }
}

///|
/// Prepare one SQL statement without blocking the MoonBit event loop.
///
/// Jobs for one connection execute in submission order. Cancellation waits for an
/// in-flight prepare and finalizes its result before returning control to the
/// caller.
pub async fn Connection::prepare_async(
  self : Connection,
  sql : String,
) -> Statement {
  try {
    if sql.contains_code_unit(0x0000) {
      raise sqlite_misuse("sqlite3: SQL contains a NUL code unit")
    }
    let (database, executor) = self.begin_job()
    defer self.finish_job()
    let submit_rescode = Ref(SQLITE_OK)
    // Job construction reserves cleanup before SQLite can produce a resource.
    // Keep that resource with its job until validation and cancellation checks
    // finish, so rejection can dispose of it without publishing a raw handle.
    let job = @ffi.sqlite3_prepare_job(executor, database, sql, submit_rescode)
    defer job.release()
    if submit_rescode.val != SQLITE_OK {
      raise sqlite_error(
        submit_rescode.val,
        "sqlite3: failed to submit asynchronous prepare",
      )
    }
    @async.protect_from_cancel(() => job.wait())
    let (rescode, extended_rescode, message, tail_offset) = job.result()
    if rescode != SQLITE_OK {
      raise sqlite_error(
        extended_rescode,
        if message == "" {
          "sqlite3: asynchronous prepare failed"
        } else {
          message
        },
      )
    }
    if tail_offset < 0 {
      raise sqlite_misuse("sqlite3: SQL does not contain a statement")
    }
    let invalid_tail = tail_offset > sql.length() ||
      !sql_tail_is_ignorable(sql, tail_offset)
    let cancelled = @async.is_being_cancelled()
    if invalid_tail || cancelled {
      @async.protect_from_cancel(() => job.discard())
    }
    if invalid_tail {
      raise sqlite_misuse("sqlite3: SQL contains more than one statement")
    }
    if cancelled {
      @async.pause()
    }
    let statement = job.take_statement()
    {
      handle: Some(statement),
      step_in_flight: Ref(false),
      has_row: false,
      column_types: None,
      connection: self,
    }
  } catch {
    @os_error.OSError(_) as error => raise async_io_error(error)
    error => raise error
  }
}

///|
/// Execute one step without blocking the MoonBit event loop.
///
/// Jobs for one connection execute in submission order. Operations on different
/// connections may run concurrently.
///
/// Synchronous operations on other statements may run while this step is in
/// flight, but can block behind SQLite's serialized connection access. The
/// statement being stepped rejects synchronous use until the step completes.
///
/// Cancellation waits for an in-flight SQLite step to finish before returning
/// the connection and statement to the caller.
pub async fn Statement::step_async(self : Statement) -> StepResult {
  try {
    let connection = self.connection
    let result = @async.protect_from_cancel() <| () => {
      let statement = self.get_handle()
      self.step_in_flight.val = true
      defer {
        self.step_in_flight.val = false
      }
      let (database, executor) = connection.begin_job()
      defer connection.finish_job()
      self.has_row = false
      self.column_types = None
      let submit_rescode = Ref(SQLITE_OK)
      let job = @ffi.sqlite3_step_job(
        executor, database, statement, submit_rescode,
      )
      defer job.release()
      if submit_rescode.val != SQLITE_OK {
        raise sqlite_error(
          submit_rescode.val,
          "sqlite3: failed to submit asynchronous operation",
        )
      }
      job.wait()
      let (rescode, extended_rescode, message, changes) = job.result()
      match rescode {
        SQLITE_ROW => {
          self.has_row = true
          Row
        }
        SQLITE_DONE => Done(changes~)
        _ =>
          raise sqlite_error(
            extended_rescode,
            if message == "" {
              "sqlite3: asynchronous operation failed"
            } else {
              message
            },
          )
      }
    }
    if @async.is_being_cancelled() {
      @async.pause()
    }
    result
  } catch {
    @os_error.OSError(_) as error => raise async_io_error(error)
    error => raise error
  }
}
