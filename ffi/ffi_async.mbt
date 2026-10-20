///|
priv struct Sqlite3Job {
  handle : Sqlite3JobHandle
  mut notification : @pipe.PipeRead?
}

///|
struct Sqlite3OpenJob {
  job : Sqlite3Job
  discard_notification : @pipe.PipeRead
}

///|
struct Sqlite3PrepareJob {
  job : Sqlite3Job
  discard_notification : @pipe.PipeRead
}

///|
struct Sqlite3StepJob(Sqlite3Job)

///|
pub fn sqlite3_open_job(
  executor : Sqlite3Executor,
  filename : Bytes,
  flags : Int32,
  rescode : Ref[Int32],
) -> Sqlite3OpenJob raise {
  let (notification, notifier) = @pipe.pipe()
  defer notifier.close()
  errdefer notification.close()
  let (discard_notification, discard_notifier) = @pipe.pipe()
  defer discard_notifier.close()
  Sqlite3OpenJob::{
    job: {
      handle: sqlite3_open_job_impl(
        executor.0,
        filename,
        flags,
        notifier.fd(),
        discard_notifier.fd(),
        rescode,
      ),
      notification: Some(notification),
    },
    discard_notification,
  }
}

///|
pub fn sqlite3_prepare_job(
  executor : Sqlite3Executor,
  database : Sqlite3,
  sql : String,
  rescode : Ref[Int32],
) -> Sqlite3PrepareJob raise {
  let (notification, notifier) = @pipe.pipe()
  defer notifier.close()
  errdefer notification.close()
  let (discard_notification, discard_notifier) = @pipe.pipe()
  defer discard_notifier.close()
  Sqlite3PrepareJob::{
    job: {
      handle: sqlite3_prepare_job_impl(
        executor.0,
        database.0,
        sql,
        notifier.fd(),
        discard_notifier.fd(),
        rescode,
      ),
      notification: Some(notification),
    },
    discard_notification,
  }
}

///|
pub fn sqlite3_step_job(
  executor : Sqlite3Executor,
  database : Sqlite3,
  statement : Sqlite3Stmt,
  rescode : Ref[Int32],
) -> Sqlite3StepJob raise {
  let (notification, notifier) = @pipe.pipe()
  defer notifier.close()
  Sqlite3StepJob({
    handle: sqlite3_step_job_impl(
      executor.0,
      database.0,
      statement.0,
      notifier.fd(),
      rescode,
    ),
    notification: Some(notification),
  })
}

///|
async fn Sqlite3Job::wait(self : Sqlite3Job) -> Unit {
  guard self.notification is Some(notification) else {
    abort("sqlite3: asynchronous job lost its completion notification")
  }
  let signal = FixedArray::make(1, b'\x00')
  for ;; {
    ignore(notification.read(signal, max_len=1)) catch {
      @os_error.OSError(_) as error if error.is_EINTR() ||
        error.is_nonblocking_io_error() => continue
      _ => abort("sqlite3: asynchronous completion notification failed")
    }
    break
  }
  if !self.acquire_result() {
    abort("sqlite3: asynchronous job woke before publishing its result")
  }
}

///|
fn Sqlite3Job::acquire_result(self : Sqlite3Job) -> Bool {
  sqlite3_job_acquire_result_impl(self.handle)
}

///|
fn Sqlite3Job::rescode(self : Sqlite3Job) -> Int32 {
  sqlite3_job_rescode_impl(self.handle)
}

///|
fn Sqlite3Job::extended_rescode(self : Sqlite3Job) -> Int32 {
  sqlite3_job_extended_rescode_impl(self.handle)
}

///|
fn Sqlite3Job::message(self : Sqlite3Job) -> String {
  sqlite3_job_message_impl(self.handle)
}

///|
fn Sqlite3Job::close_notification(self : Sqlite3Job) -> Unit {
  if self.notification is Some(notification) {
    notification.close()
    self.notification = None
  }
}

///|
/// Wait for a submitted job to complete. This does not cancel SQLite work; use @async.protect_from_cancel when cancellation must await cleanup.
pub async fn Sqlite3OpenJob::wait(self : Sqlite3OpenJob) -> Unit {
  self.job.wait()
}

///|
/// Read the completed job snapshot: primary code, extended code, and message. Call only after wait succeeds.
pub fn Sqlite3OpenJob::result(self : Sqlite3OpenJob) -> (Int32, Int32, String) {
  (self.job.rescode(), self.job.extended_rescode(), self.job.message())
}

///|
/// Transfer a successful completed result exactly once. The caller must close the database; do not discard it after taking it.
pub fn Sqlite3OpenJob::take_database(self : Sqlite3OpenJob) -> Sqlite3 {
  Sqlite3(sqlite3_open_job_database_impl(self.job.handle))
}

///|
/// Release exactly once. Successfully submitted work must have completed, and any successful database result must first be taken or discarded. Do not use the job afterward.
pub fn Sqlite3OpenJob::release(self : Sqlite3OpenJob) -> Unit {
  self.job.close_notification()
  self.discard_notification.close()
  sqlite3_open_job_release_impl(self.job.handle)
}

///|
/// After successful completion, close an untaken database on its executor. Await this under cancellation protection before release; this does not release the job itself.
pub async fn Sqlite3OpenJob::discard(self : Sqlite3OpenJob) -> Unit {
  let handle = sqlite3_open_job_discard_impl(self.job.handle)
  let discard = Sqlite3Job::{
    handle,
    notification: Some(self.discard_notification),
  }
  discard.wait()
}

///|
/// Wait for submitted preparation to complete. Protect this wait from cancellation so the statement can be taken or discarded before release.
pub async fn Sqlite3PrepareJob::wait(self : Sqlite3PrepareJob) -> Unit {
  self.job.wait()
}

///|
/// Read the completed snapshot: primary code, extended code, message, and UTF-16 tail offset. Call only after wait succeeds.
pub fn Sqlite3PrepareJob::result(
  self : Sqlite3PrepareJob,
) -> (Int32, Int32, String, Int32) {
  (
    self.job.rescode(),
    self.job.extended_rescode(),
    self.job.message(),
    sqlite3_prepare_job_tail_offset_impl(self.job.handle),
  )
}

///|
/// Transfer the completed statement exactly once. The caller must finalize it; do not discard it after taking it.
pub fn Sqlite3PrepareJob::take_statement(
  self : Sqlite3PrepareJob,
) -> Sqlite3Stmt {
  Sqlite3Stmt(sqlite3_prepare_job_statement_impl(self.job.handle))
}

///|
/// Release exactly once after submitted work completes and any produced statement has been taken or discarded. Do not use the job afterward.
pub fn Sqlite3PrepareJob::release(self : Sqlite3PrepareJob) -> Unit {
  self.job.close_notification()
  self.discard_notification.close()
  sqlite3_prepare_job_release_impl(self.job.handle)
}

///|
/// After successful completion, finalize an untaken statement on its executor. Await this under cancellation protection before release; this does not release the job itself.
pub async fn Sqlite3PrepareJob::discard(self : Sqlite3PrepareJob) -> Unit {
  let handle = sqlite3_prepare_job_discard_impl(self.job.handle)
  let discard = Sqlite3Job::{
    handle,
    notification: Some(self.discard_notification),
  }
  discard.wait()
}

///|
/// Wait for submitted stepping to complete. Protect the wait from cancellation and keep the database and statement alive until completion.
pub async fn Sqlite3StepJob::wait(self : Sqlite3StepJob) -> Unit {
  self.0.wait()
}

///|
/// Read the completed snapshot: primary code, extended code, message, and optional direct change count. Call only after wait succeeds.
pub fn Sqlite3StepJob::result(
  self : Sqlite3StepJob,
) -> (Int32, Int32, String, Int64?) {
  let changes = if sqlite3_step_job_has_changes_impl(self.0.handle) {
    Some(sqlite3_step_job_changes_impl(self.0.handle))
  } else {
    None
  }
  (self.0.rescode(), self.0.extended_rescode(), self.0.message(), changes)
}

///|
/// Release exactly once after submitted work completes. This does not finalize the caller-owned statement. Do not use the job afterward.
pub fn Sqlite3StepJob::release(self : Sqlite3StepJob) -> Unit {
  self.0.close_notification()
  sqlite3_step_job_release_impl(self.0.handle)
}
