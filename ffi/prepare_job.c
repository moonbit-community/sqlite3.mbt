#include "job.h"
#include <moonbit.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct moonbit_sqlite3_prepare_job {
  moonbit_sqlite3_job_t job;
  moonbit_sqlite3_job_t discard;
  moonbit_sqlite3_executor_t *executor;
  sqlite3 *database;
  uint16_t *sql;
  int32_t sql_length;
  sqlite3_stmt *statement;
  int32_t tail_offset;
} moonbit_sqlite3_prepare_job_t;

static void
moonbit_sqlite3_run_prepare_job(
  moonbit_sqlite3_executor_job_t *executor_job
) {
  moonbit_sqlite3_prepare_job_t *prepare_job =
    (moonbit_sqlite3_prepare_job_t *)executor_job;
  moonbit_sqlite3_job_t *job = &prepare_job->job;
  sqlite3_mutex *mutex = sqlite3_db_mutex(prepare_job->database);
  if (mutex) {
    sqlite3_mutex_enter(mutex);
  }
  const void *tail = NULL;
  job->rescode = sqlite3_prepare16_v2(
    prepare_job->database,
    prepare_job->sql,
    prepare_job->sql_length * (int32_t)sizeof(uint16_t),
    &prepare_job->statement,
    &tail
  );
  if (job->rescode == SQLITE_OK) {
    job->extended_rescode = SQLITE_OK;
    if (prepare_job->statement) {
      prepare_job->tail_offset =
        (int32_t)((const uint16_t *)tail - prepare_job->sql);
    } else {
      prepare_job->tail_offset = -1;
    }
  } else {
    prepare_job->tail_offset = -1;
    moonbit_sqlite3_job_capture_error(job, prepare_job->database);
    if (prepare_job->statement) {
      sqlite3_finalize(prepare_job->statement);
      prepare_job->statement = NULL;
    }
  }
  if (mutex) {
    sqlite3_mutex_leave(mutex);
  }
  free(prepare_job->sql);
  prepare_job->sql = NULL;
  moonbit_sqlite3_job_publish_result(&prepare_job->job);
}

/* The cleanup envelope is reserved before submission and reuses the owning
 * job's storage. Releasing the owner is legal only after cleanup completes. */
static void
moonbit_sqlite3_run_prepare_discard(
  moonbit_sqlite3_executor_job_t *executor_job
) {
  moonbit_sqlite3_prepare_job_t *owner =
    (moonbit_sqlite3_prepare_job_t *)((char *)executor_job -
      offsetof(moonbit_sqlite3_prepare_job_t, discard));
  sqlite3_mutex *mutex = sqlite3_db_mutex(owner->database);
  sqlite3_mutex_enter(mutex);
  sqlite3_finalize(owner->statement);
  owner->statement = NULL;
  sqlite3_mutex_leave(mutex);
  moonbit_sqlite3_job_publish_result(&owner->discard);
}

MOONBIT_FFI_EXPORT
moonbit_sqlite3_job_t *
moonbit_sqlite3_prepare_job_discard(moonbit_sqlite3_job_t *job) {
  if (!moonbit_sqlite3_job_result_is_published(job)) {
    abort();
  }
  moonbit_sqlite3_prepare_job_t *owner = (moonbit_sqlite3_prepare_job_t *)job;
  if (!owner->statement || owner->discard.executor_job.run) {
    abort();
  }
  owner->discard.executor_job.run = moonbit_sqlite3_run_prepare_discard;
  if (!moonbit_sqlite3_executor_submit(
        owner->executor, &owner->discard.executor_job
      )) {
    /* The MoonBit connection remains in flight through cleanup, so its
     * executor cannot have been stopped. No allocation occurs here. */
    abort();
  }
  return &owner->discard;
}

MOONBIT_FFI_EXPORT
moonbit_sqlite3_job_t *
moonbit_sqlite3_prepare_job(
  moonbit_sqlite3_executor_t *executor,
  sqlite3 *database,
  moonbit_string_t sql,
  moonbit_sqlite3_notification_t notification,
  moonbit_sqlite3_notification_t discard_notification,
  int32_t *rescode
) {
  if (!database) {
    *rescode = SQLITE_MISUSE;
    return NULL;
  }
  int32_t sql_length = Moonbit_array_length(sql);
  if (sql_length > INT32_MAX / (int32_t)sizeof(uint16_t)) {
    *rescode = SQLITE_TOOBIG;
    return NULL;
  }
  moonbit_sqlite3_prepare_job_t *prepare_job =
    calloc(1, sizeof(*prepare_job));
  if (!prepare_job) {
    *rescode = SQLITE_NOMEM;
    return NULL;
  }
  size_t sql_size = (size_t)sql_length * sizeof(uint16_t);
  prepare_job->sql = malloc(sql_size == 0 ? sizeof(uint16_t) : sql_size);
  if (!prepare_job->sql) {
    free(prepare_job);
    *rescode = SQLITE_NOMEM;
    return NULL;
  }
  if (sql_size > 0) {
    memcpy(prepare_job->sql, sql, sql_size);
  }
  prepare_job->database = database;
  prepare_job->sql_length = sql_length;
  prepare_job->tail_offset = -1;
  prepare_job->executor = executor;
  if (!moonbit_sqlite3_job_initialize(
        &prepare_job->discard, discard_notification, rescode
      )) {
    free(prepare_job->sql);
    free(prepare_job);
    return NULL;
  }
  if (!moonbit_sqlite3_job_submit(
        &prepare_job->job,
        executor,
        notification,
        moonbit_sqlite3_run_prepare_job,
        rescode
      )) {
    moonbit_sqlite3_job_dispose(&prepare_job->discard);
    free(prepare_job->sql);
    free(prepare_job);
    return NULL;
  }
  return &prepare_job->job;
}

MOONBIT_FFI_EXPORT
sqlite3_stmt *
moonbit_sqlite3_prepare_job_statement(moonbit_sqlite3_job_t *job) {
  if (!job || !moonbit_sqlite3_job_result_is_published(job) ||
      job->rescode != SQLITE_OK) {
    return NULL;
  }
  moonbit_sqlite3_prepare_job_t *prepare_job =
    (moonbit_sqlite3_prepare_job_t *)job;
  if (!prepare_job->statement) {
    return NULL;
  }
  sqlite3_stmt *statement = prepare_job->statement;
  prepare_job->statement = NULL;
  return statement;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_sqlite3_prepare_job_tail_offset(moonbit_sqlite3_job_t *job) {
  if (!job || !moonbit_sqlite3_job_result_is_published(job)) {
    return -1;
  }
  moonbit_sqlite3_prepare_job_t *prepare_job =
    (moonbit_sqlite3_prepare_job_t *)job;
  return prepare_job->tail_offset;
}

MOONBIT_FFI_EXPORT
void
moonbit_sqlite3_prepare_job_release(moonbit_sqlite3_job_t *job) {
  if (!job || !moonbit_sqlite3_job_result_is_published(job)) {
    return;
  }
  moonbit_sqlite3_prepare_job_t *prepare_job =
    (moonbit_sqlite3_prepare_job_t *)job;
  if (prepare_job->discard.executor_job.run &&
      !moonbit_sqlite3_job_result_is_published(&prepare_job->discard)) {
    abort();
  }
  moonbit_sqlite3_job_dispose(&prepare_job->discard);
  if (prepare_job->statement) {
    /* Every successful result must be taken or asynchronously discarded. */
    abort();
  }
  free(prepare_job->sql);
  moonbit_sqlite3_job_dispose(job);
  free(prepare_job);
}
