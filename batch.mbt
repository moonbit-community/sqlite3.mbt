///|
/// Execute a SQL script in order, discarding result rows.
///
/// Empty scripts succeed. Stops at the first prepare or execution error and
/// finalizes every statement it creates. No transaction is started or committed
/// implicitly: earlier changes can remain after an error, and the caller owns
/// rollback of any explicit transaction. Use `prepare_next` to bind parameters
/// or read result rows.
pub fn Connection::execute_batch(
  self : Connection,
  sql : String,
) -> Unit raise SqliteError {
  for remaining = sql[:] {
    guard self.prepare_next(remaining) is Some((statement, rest)) else { break }
    // Finalization may repeat a step error. Preserve the original diagnostic
    // while still releasing the failed statement.
    errdefer (statement.finalize() catch { _ => () })
    while statement.step() {

    }
    statement.finalize()
    continue rest
  }
}

///|
/// Execute a SQL script using asynchronous preparation and stepping.
///
/// Result rows are discarded and errors stop the script, as with `execute_batch`.
/// Statement finalization uses the synchronous `Statement::finalize` operation.
/// Other tasks may interleave operations on the connection between jobs; callers
/// must coordinate exclusive access when needed. Cancellation waits for submitted
/// work, finalizes the current statement, and skips the remaining statements.
/// Completed changes and explicit transactions remain the caller's responsibility.
pub async fn Connection::execute_batch_async(
  self : Connection,
  sql : String,
) -> Unit {
  for remaining = sql[:] {
    guard self.prepare_next_async(remaining) is Some((statement, rest)) else {
      break
    }
    errdefer (statement.finalize() catch { _ => () })
    while statement.step_async() is Row {

    }
    statement.finalize()
    continue rest
  }
}
