///|
priv enum Sqlite3Worker {
  Uninitialized
  Ready(@pipe.PipeRead, @pipe.PipeWrite)
  Started(UInt64, @pipe.PipeRead)
}

///|
priv struct Sqlite3ExecutorHandle {
  mutex : @async.Mutex
  mut worker : Sqlite3Worker
  mut next_id : Int
}

///|
fn sqlite3_executor_create_impl(rescode : Ref[Int]) -> Sqlite3ExecutorHandle {
  rescode.val = SQLITE_OK
  { mutex: @async.Mutex(), worker: Uninitialized, next_id: 0, }
}

///|
fn sqlite3_executor_release_impl(executor : Sqlite3ExecutorHandle) -> Unit {
  // The connection rejects close while jobs are outstanding. The worker is
  // therefore idle here, and releasing it closes the host's retained writer.
  match executor.worker {
    Uninitialized => ()
    Ready(reader, writer) => {
      writer.close()
      reader.close()
    }
    Started(worker, reader) => {
      sqlite3_free_worker_import(worker)
      reader.close()
    }
  }
  executor.worker = Uninitialized
}

///|
fn Sqlite3ExecutorHandle::reserve_notification(
  self : Sqlite3ExecutorHandle,
) -> Unit raise {
  // Allocate before creating the first job, so notification failure cannot
  // strand a SQLite result. Discard jobs reuse this same completion pipe.
  if self.worker is Uninitialized {
    let (reader, writer) = @pipe.pipe()
    self.worker = Ready(reader, writer)
  }
}

///|
// SQLite owns these jobs' copied inputs and results. The async runtime owns
// the worker; the guest mutex orders submission and reads from its private pipe.
priv struct Sqlite3Job {
  handle : UInt64
  executor : Sqlite3Executor
}

///|
struct Sqlite3OpenJob(Sqlite3Job)

///|
struct Sqlite3PrepareJob(Sqlite3Job)

///|
struct Sqlite3StepJob(Sqlite3Job)

///|
#unsafe_skip_stub_check
#borrow(filename)
fn sqlite3_make_open_job_import(
  filename : Bytes,
  length : Int,
  flags : Int,
) -> UInt64 = "moonbitlang/sqlite" "sqlite3_make_open_job"

///|
#unsafe_skip_stub_check
#borrow(sql)
fn sqlite3_make_prepare_job_import(
  database : UInt64,
  sql : String,
  offset : Int,
  length : Int,
) -> UInt64 = "moonbitlang/sqlite" "sqlite3_make_prepare_job"

///|
fn sqlite3_make_step_job_import(
  database : UInt64,
  statement : UInt64,
) -> UInt64 = "moonbitlang/sqlite" "sqlite3_make_step_job"

///|
fn sqlite3_make_discard_job_import(job : UInt64) -> UInt64 = "moonbitlang/sqlite" "sqlite3_make_discard_job"

///|
#unsafe_skip_stub_check
#borrow(output)
fn sqlite3_job_result_import(job : UInt64, output : FixedArray[Int]) -> Unit = "moonbitlang/sqlite" "sqlite3_job_result"

///|
fn sqlite3_take_job_handle_import(job : UInt64) -> UInt64 = "moonbitlang/sqlite" "sqlite3_take_job_handle"

///|
fn sqlite3_job_message16_length_import(job : UInt64) -> Int = "moonbitlang/sqlite" "sqlite3_job_message16_length"

///|
#unsafe_skip_stub_check
#borrow(output)
fn sqlite3_job_message16_import(
  job : UInt64,
  output : String,
  capacity : Int,
) -> Int = "moonbitlang/sqlite" "sqlite3_job_message16"

///|
fn sqlite3_free_job_import(job : UInt64) -> Unit = "moonbitlang/async" "thread_pool/free_job"

///|
fn sqlite3_spawn_worker_with_pipe_import(
  completion_id : Int,
  job : UInt64,
  writer : UInt64,
) -> UInt64 = "moonbitlang/async" "thread_pool/spawn_worker_with_pipe"

///|
fn sqlite3_wake_worker_import(
  worker : UInt64,
  completion_id : Int,
  job : UInt64,
) -> Unit = "moonbitlang/async" "thread_pool/wake_worker"

///|
fn sqlite3_free_worker_import(worker : UInt64) -> Unit = "moonbitlang/async" "thread_pool/free_worker"

///|
fn sqlite3_job_get_err_import(job : UInt64) -> Int = "moonbitlang/async" "thread_pool/job_get_err"

///|
pub fn sqlite3_open_job(
  executor : Sqlite3Executor,
  filename : Bytes,
  flags : Int,
  rescode : Ref[Int],
) -> Sqlite3OpenJob raise {
  executor.0.reserve_notification()
  rescode.val = SQLITE_OK
  Sqlite3OpenJob({
    handle: sqlite3_make_open_job_import(filename, filename.length(), flags),
    executor,
  })
}

///|
pub fn sqlite3_prepare_job(
  executor : Sqlite3Executor,
  database : Sqlite3,
  sql : String,
  rescode : Ref[Int],
) -> Sqlite3PrepareJob raise {
  executor.0.reserve_notification()
  rescode.val = SQLITE_OK
  Sqlite3PrepareJob({
    handle: sqlite3_make_prepare_job_import(database.0.0, sql, 0, sql.length()),
    executor,
  })
}

///|
pub fn sqlite3_step_job(
  executor : Sqlite3Executor,
  database : Sqlite3,
  statement : Sqlite3Stmt,
  rescode : Ref[Int],
) -> Sqlite3StepJob raise {
  executor.0.reserve_notification()
  rescode.val = SQLITE_OK
  Sqlite3StepJob({
    handle: sqlite3_make_step_job_import(database.0.0, statement.0.0),
    executor,
  })
}

///|
async fn Sqlite3Job::wait(self : Sqlite3Job) -> Unit {
  let executor = self.executor.0
  executor.mutex.acquire()
  defer executor.mutex.release()
  let id = executor.next_id
  executor.next_id += 1
  let reader = match executor.worker {
    Uninitialized => abort("sqlite3: asynchronous job lost its completion pipe")
    Ready(reader, writer) => {
      // moonrun retains the writer before submitting the job. Closing the
      // guest handle leaves the host writer alive for later wake_worker calls.
      defer writer.close()
      let worker = sqlite3_spawn_worker_with_pipe_import(
        id,
        self.handle,
        writer.fd(),
      )
      executor.worker = Started(worker, reader)
      reader
    }
    Started(worker, reader) => {
      sqlite3_wake_worker_import(worker, id, self.handle)
      reader
    }
  }
  // Callers shield both the mutex wait and completion read from cancellation.
  // EOF means the channel failed, not that the job completed. Do not unwind
  // and reuse a worker whose job may still be running after a read failure.
  let bytes = FixedArray::make(4, b'\x00')
  for received = 0; received < bytes.length(); {
    let count = reader.read(
      bytes,
      offset=received,
      max_len=bytes.length() - received,
    ) catch {
      // async's pipe reader can propagate EINTR or readiness races. Preserve
      // any partial ID when retrying rather than restarting a four-byte read.
      @os_error.OSError(_) as error if error.is_EINTR() ||
        error.is_nonblocking_io_error() => continue received
      _ => abort("sqlite3: asynchronous completion notification failed")
    }
    if count == 0 {
      abort("sqlite3: asynchronous completion pipe closed before notification")
    }
    continue received + count
  }
  let completed_id = bytes[0].to_int() |
    (bytes[1].to_int() << 8) |
    (bytes[2].to_int() << 16) |
    (bytes[3].to_int() << 24)
  if completed_id != id {
    abort("sqlite3: asynchronous completion ID mismatch")
  }
  // This accessor restores the completed host job without draining async's
  // private scheduler queue. SQLite's own result code is in its result record.
  let error = sqlite3_job_get_err_import(self.handle)
  if error != 0 {
    raise @os_error.OSError(error, context="sqlite3: asynchronous host job")
  }
}

///|
fn Sqlite3Job::result(self : Sqlite3Job) -> (Int, Int, String, Int, Int64?) {
  // The host copies a 24-byte little-endian record; Wasm Ints are 32 bits.
  let output = FixedArray::make(6, 0)
  sqlite3_job_result_import(self.handle, output)
  let changes = if output[3] == 0 {
    None
  } else {
    Some(
      output[4].reinterpret_as_uint().to_int64() | (output[5].to_int64() << 32),
    )
  }
  let length = sqlite3_job_message16_length_import(self.handle)
  let message = String::make(length, '\u0000')
  if sqlite3_job_message16_import(self.handle, message, length) != length {
    abort("sqlite3: inconsistent asynchronous diagnostic length")
  }
  (output[0], output[1], message, output[2], changes)
}

///|
async fn Sqlite3Job::discard(self : Sqlite3Job) -> Unit {
  let handle = sqlite3_make_discard_job_import(self.handle)
  if handle != sqlite3_null_handle_import() {
    defer sqlite3_free_job_import(handle)
    let discard = Sqlite3Job::{ handle, executor: self.executor, }
    discard.wait()
  }
}

///|
pub async fn Sqlite3OpenJob::wait(self : Sqlite3OpenJob) -> Unit {
  self.0.wait()
}

///|
pub fn Sqlite3OpenJob::result(self : Sqlite3OpenJob) -> (Int, Int, String) {
  let (code, extended, message, _, _) = self.0.result()
  (code, extended, message)
}

///|
pub fn Sqlite3OpenJob::take_database(self : Sqlite3OpenJob) -> Sqlite3 {
  Sqlite3(Sqlite3Handle(sqlite3_take_job_handle_import(self.0.handle)))
}

///|
pub async fn Sqlite3OpenJob::discard(self : Sqlite3OpenJob) -> Unit {
  self.0.discard()
}

///|
pub fn Sqlite3OpenJob::release(self : Sqlite3OpenJob) -> Unit {
  sqlite3_free_job_import(self.0.handle)
}

///|
pub async fn Sqlite3PrepareJob::wait(self : Sqlite3PrepareJob) -> Unit {
  self.0.wait()
}

///|
pub fn Sqlite3PrepareJob::result(
  self : Sqlite3PrepareJob,
) -> (Int, Int, String, Int) {
  let (code, extended, message, tail, _) = self.0.result()
  (code, extended, message, tail)
}

///|
pub fn Sqlite3PrepareJob::take_statement(
  self : Sqlite3PrepareJob,
) -> Sqlite3Stmt {
  Sqlite3Stmt(Sqlite3StmtHandle(sqlite3_take_job_handle_import(self.0.handle)))
}

///|
pub async fn Sqlite3PrepareJob::discard(self : Sqlite3PrepareJob) -> Unit {
  self.0.discard()
}

///|
pub fn Sqlite3PrepareJob::release(self : Sqlite3PrepareJob) -> Unit {
  sqlite3_free_job_import(self.0.handle)
}

///|
pub async fn Sqlite3StepJob::wait(self : Sqlite3StepJob) -> Unit {
  self.0.wait()
}

///|
pub fn Sqlite3StepJob::result(
  self : Sqlite3StepJob,
) -> (Int, Int, String, Int64?) {
  let (code, extended, message, _, changes) = self.0.result()
  (code, extended, message, changes)
}

///|
pub fn Sqlite3StepJob::release(self : Sqlite3StepJob) -> Unit {
  sqlite3_free_job_import(self.0.handle)
}
