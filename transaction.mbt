///|
/// Locking behaviour of a transaction's `BEGIN` statement.
///
/// Mirrors the SQLite `BEGIN` modifiers: `Deferred` (the default) acquires
/// locks lazily on first use, `Immediate` takes a reserved lock right away,
/// and `Exclusive` takes an exclusive lock for the whole transaction.
#derive(Eq, Debug)
pub(all) enum TransactionMode {
  Deferred
  Immediate
  Exclusive
}

///|
/// An explicit transaction started on a connection.
///
/// Finish it with `commit` or `rollback`; both finalize the transaction and
/// allow starting the next one. Dropping the handle without finishing is
/// reported by the connection: a subsequent `transaction()` call refuses to
/// start a new transaction while one is still open, so unfinished
/// transactions cannot be silently abandoned. Prefer `with_transaction`,
/// which commits on success and rolls back when the body raises.
pub struct Transaction {
  priv connection : Connection
  priv mut finished : Bool
}

///|
fn Transaction::begin_sql(mode : TransactionMode) -> String {
  match mode {
    Deferred => "BEGIN DEFERRED"
    Immediate => "BEGIN IMMEDIATE"
    Exclusive => "BEGIN EXCLUSIVE"
  }
}

///|
fn Transaction::run_finish(
  self : Transaction,
  sql : String,
  op_name : String,
) -> Unit raise SqliteError {
  if self.finished {
    raise sqlite_misuse("sqlite3: transaction already committed or rolled back")
  }
  let stmt = self.connection.prepare(sql)
  // The statement must not leak even when the step fails (e.g. a busy
  // database): a lingering active statement would keep the transaction
  // alive and block the retry the caller usually wants to make.
  // `Statement::finalize` is idempotent; the normal path finalizes
  // explicitly and `errdefer` guards the error path.
  errdefer stmt.finalize()
  if stmt.step() {
    raise sqlite_misuse("sqlite3: " + op_name + " returned unexpected rows")
  }
  stmt.finalize()
  self.finished = true
  self.connection.0.val.txn_depth -= 1
}

///|
/// Commit the transaction.
///
/// Raises the SQLite error when the commit fails (e.g. `SQLITE_BUSY` in WAL
/// mode); the transaction then remains open so the caller may retry the
/// commit or roll back explicitly.
pub fn Transaction::commit(self : Transaction) -> Unit raise SqliteError {
  self.run_finish("COMMIT", "COMMIT")
}

///|
/// Roll the transaction back.
///
/// Raises when the rollback itself fails; the transaction is still open in
/// that case. A rollback after a failed commit is the normal recovery path.
pub fn Transaction::rollback(self : Transaction) -> Unit raise SqliteError {
  self.run_finish("ROLLBACK", "ROLLBACK")
}

///|
/// Start an explicit transaction on this connection.
///
/// Nested transactions are rejected with a misuse error: SQLite has no
/// nested `BEGIN` (savepoints are the supported nesting mechanism and are
/// out of scope for this wrapper). The returned handle must be finished with
/// `commit` or `rollback` before the connection may start another
/// transaction. Use `with_transaction` for automatic commit/rollback.
pub fn Connection::transaction(
  self : Connection,
  mode~ : TransactionMode = Deferred,
) -> Transaction raise SqliteError {
  let _ = self.handle()
  if self.0.val.txn_depth != 0 {
    raise sqlite_misuse(
      "sqlite3: a transaction is already active on this connection; use savepoints for nesting",
    )
  }
  let stmt = self.prepare(Transaction::begin_sql(mode))
  errdefer stmt.finalize()
  if stmt.step() {
    raise sqlite_misuse("sqlite3: BEGIN returned unexpected rows")
  }
  stmt.finalize()
  self.0.val.txn_depth += 1
  { connection: self, finished: false, }
}

///|
/// Run `body` inside a transaction.
///
/// Commits when `body` returns and rolls back when it raises, re-raising the
/// original error afterwards. If the rollback itself fails, its SQLite error
/// replaces the body error (both conditions mean the database needs
/// attention; the rollback failure is the actionable one).
pub fn[T] Connection::with_transaction(
  self : Connection,
  mode~ : TransactionMode = Deferred,
  body : () -> T raise,
) -> T raise {
  let txn = self.transaction(mode~)
  let result = Ok(body()) catch { error => Err(error) }
  match result {
    Ok(value) => {
      txn.commit()
      value
    }
    Err(error) =>
      match
        (try {
          txn.rollback()
          None
        } catch {
          rollback_error => Some(rollback_error)
        }) {
        None => raise error
        Some(rollback_error) => raise rollback_error
      }
  }
}
