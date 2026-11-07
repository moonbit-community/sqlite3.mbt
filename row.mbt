///|
/// An immutable snapshot of one result row: column names plus dynamically
/// typed values copied out of the statement.
///
/// Snapshots decouple row data from statement lifetime, so they are safe to
/// keep after `step` advances or the statement is finalized. Typed accessors
/// (`get_int`, `get_text`, ...) are strict: they raise a misuse error when
/// the stored class differs, instead of reproducing SQLite's lossy
/// conversion rules. Read the cell as a `Value` and convert explicitly when
/// coercion is wanted.
#derive(Debug, Eq)
pub struct Row {
  priv names : FixedArray[String]
  priv values : Array[Value]
}

///|
/// Number of columns in the row.
pub fn Row::column_count(self : Row) -> Int32 {
  self.values.length()
}

///|
/// Column name at `index` (0-based).
pub fn Row::name(self : Row, index~ : Int32) -> String raise {
  guard index >= 0 && index < self.names.length() else {
    raise sqlite_misuse(
      "sqlite3: column index \{index} is outside 0..<\{self.names.length()}",
    )
  }
  self.names[index]
}

///|
/// All column names, in result order.
pub fn Row::names(self : Row) -> Array[String] {
  Array::from_fixed_array(self.names)
}

///|
/// Dynamically typed value at `index`.
pub fn Row::get(self : Row, index~ : Int32) -> Value raise {
  guard index >= 0 && index < self.values.length() else {
    raise sqlite_misuse(
      "sqlite3: column index \{index} is outside 0..<\{self.values.length()}",
    )
  }
  self.values[index]
}

///|
/// Dynamically typed value of the first column named `name`.
///
/// Raises a misuse error when no such column exists; duplicate names
/// (e.g. from a join without aliases) resolve to the first occurrence.
pub fn Row::get_by_name(self : Row, name~ : String) -> Value raise {
  for i = 0; i < self.names.length(); i = i + 1 {
    if self.names[i] == name {
      return self.values[i]
    }
  }
  raise sqlite_misuse("sqlite3: no column named \{name}")
}

///|
/// Index of the first column named `name`, if present.
pub fn Row::index_of(self : Row, name~ : String) -> Int32? {
  for i = 0; i < self.names.length(); i = i + 1 {
    if self.names[i] == name {
      return Some(i)
    }
  }
  None
}

///|
fn Row::expect(
  self : Row,
  index~ : Int32,
  storage : String,
  keep : (Value) -> Bool,
) -> Value raise {
  let value = self.get(index~)
  if keep(value) {
    value
  } else {
    raise sqlite_misuse(
      "sqlite3: column \{index} holds \{value_kind_name(value)}, expected \{storage}",
    )
  }
}

///|
fn value_kind_name(value : Value) -> String {
  match value {
    Null => "NULL"
    Integer(_) => "INTEGER"
    Real(_) => "REAL"
    Text(_) => "TEXT"
    Blob(_) => "BLOB"
  }
}

///|
/// Strict INTEGER accessor: raises unless the stored class is INTEGER.
pub fn Row::get_int(self : Row, index~ : Int32) -> Int64 raise {
  match self.expect(index~, "INTEGER", value => value is Integer(_)) {
    Integer(v) => v
    _ => abort("sqlite3: unreachable typed accessor branch")
  }
}

///|
/// Strict REAL accessor: raises unless the stored class is REAL.
pub fn Row::get_real(self : Row, index~ : Int32) -> Double raise {
  match self.expect(index~, "REAL", value => value is Real(_)) {
    Real(v) => v
    _ => abort("sqlite3: unreachable typed accessor branch")
  }
}

///|
/// Strict TEXT accessor: raises unless the stored class is TEXT.
pub fn Row::get_text(self : Row, index~ : Int32) -> String raise {
  match self.expect(index~, "TEXT", value => value is Text(_)) {
    Text(v) => v
    _ => abort("sqlite3: unreachable typed accessor branch")
  }
}

///|
/// Strict BLOB accessor: raises unless the stored class is BLOB.
pub fn Row::get_blob(self : Row, index~ : Int32) -> Bytes raise {
  match self.expect(index~, "BLOB", value => value is Blob(_)) {
    Blob(v) => v
    _ => abort("sqlite3: unreachable typed accessor branch")
  }
}

///|
/// Snapshot the statement's current row.
///
/// Raises a misuse error when the last `step` did not produce a row. Column
/// names are read from the statement; values are copied as `Value`, so the
/// snapshot stays valid across further steps and finalization.
pub fn Statement::row(self : Statement) -> Row raise SqliteError {
  let count = self.column_count()
  let names : FixedArray[String] = FixedArray::make(count, "")
  let values : Array[Value] = []
  for i = 0; i < count; i = i + 1 {
    names[i] = self.column_name(index=i)
    values.push(self.column(index=i))
  }
  { names, values, }
}

///|
/// Bind positional parameters `1..=n` from `values` in order.
///
/// Resets nothing: combine with `Statement::reset` when re-executing a
/// statement that already carries bindings.
pub fn Statement::bind_all(
  self : Statement,
  values : Array[Value],
) -> Unit raise SqliteError {
  for i = 0; i < values.length(); i = i + 1 {
    self.bind(index=i + 1, values[i])
  }
}

///|
/// Run one SQL statement with positional parameters, ignoring result rows.
///
/// Returns the number of rows changed by the statement (`sqlite3_changes`)
/// when it completed, so `INSERT`/`UPDATE`/`DELETE` callers get the affected
/// row count for free. The statement is finalized before returning, including
/// on the error path.
pub fn Connection::execute(
  self : Connection,
  sql : String,
  params~ : Array[Value] = [],
) -> Int64 raise SqliteError {
  let stmt = self.prepare(sql)
  // `Statement::finalize` is idempotent, so the normal path finalizes
  // explicitly and `errdefer` only guards the error path.
  errdefer stmt.finalize()
  stmt.bind_all(params)
  let _ = stmt.step()
  stmt.finalize()
  self.changes()
}

///|
/// Run one query with positional parameters and collect every row.
///
/// Rows are snapshots (`Row`), valid after this call returns. The statement
/// is finalized before returning, including on the error path.
pub fn Connection::query(
  self : Connection,
  sql : String,
  params~ : Array[Value] = [],
) -> Array[Row] raise SqliteError {
  let stmt = self.prepare(sql)
  errdefer stmt.finalize()
  stmt.bind_all(params)
  let collected : Array[Row] = []
  while stmt.step() {
    collected.push(stmt.row())
  }
  stmt.finalize()
  collected
}
