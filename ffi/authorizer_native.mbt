///|
/// A native C callback with the exact sqlite3_set_authorizer signature.
/// Obtain it from C FFI; this is not a MoonBit closure. SQLite may invoke it
/// on an executor worker, where accessing MoonBit-managed values is invalid.
#external
pub type Sqlite3Authorizer

///|
/// Caller-owned native callback state. It must remain valid until the
/// authorizer is replaced, cleared, or the database is successfully closed.
#external
pub type Sqlite3AuthorizerContext

///|
extern "c" fn null_authorizer() -> Sqlite3Authorizer = "moonbit_sqlite3_null_authorizer"

///|
extern "c" fn null_authorizer_context() -> Sqlite3AuthorizerContext = "moonbit_sqlite3_null_authorizer_context"

///|
extern "c" fn sqlite3_set_authorizer_impl(
  database : Sqlite3Handle,
  authorizer : Sqlite3Authorizer,
  context : Sqlite3AuthorizerContext,
) -> Int32 = "sqlite3_set_authorizer"

///|
/// Install a native C authorizer. Omit authorizer to clear it, or omit context
/// to pass NULL as the callback's first argument. The caller owns the callback
/// and its native state; SQLite does not destroy them. They must be safe to
/// use on the connection's executor worker as well as the calling thread.
pub fn sqlite3_set_authorizer(
  database : Sqlite3,
  authorizer? : Sqlite3Authorizer,
  context? : Sqlite3AuthorizerContext,
) -> Int32 {
  sqlite3_set_authorizer_impl(
    database.0,
    authorizer.unwrap_or_else(null_authorizer),
    context.unwrap_or_else(null_authorizer_context),
  )
}
