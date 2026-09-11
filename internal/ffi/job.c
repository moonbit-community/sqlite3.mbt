#include "job.h"
#include <moonbit.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <fcntl.h>
#include <unistd.h>
#endif

#ifdef _WIN32

static moonbit_sqlite3_notification_t
moonbit_sqlite3_duplicate_notification(
  moonbit_sqlite3_notification_t notification
) {
  HANDLE duplicate = NULL;
  if (!DuplicateHandle(
        GetCurrentProcess(),
        notification,
        GetCurrentProcess(),
        &duplicate,
        0,
        FALSE,
        DUPLICATE_SAME_ACCESS
      )) {
    return NULL;
  }
  return duplicate;
}

static void
moonbit_sqlite3_close_notification(
  moonbit_sqlite3_notification_t notification
) {
  CloseHandle(notification);
}

#else

static moonbit_sqlite3_notification_t
moonbit_sqlite3_duplicate_notification(
  moonbit_sqlite3_notification_t notification
) {
  int duplicate = dup(notification);
  if (duplicate >= 0) {
    int flags = fcntl(duplicate, F_GETFD);
    if (flags >= 0) {
      (void)fcntl(duplicate, F_SETFD, flags | FD_CLOEXEC);
    }
  }
  return duplicate;
}

static void
moonbit_sqlite3_close_notification(
  moonbit_sqlite3_notification_t notification
) {
  close(notification);
}

#endif

bool
moonbit_sqlite3_job_initialize(
  moonbit_sqlite3_job_t *job,
  moonbit_sqlite3_notification_t notification,
  int32_t *rescode
) {
  *rescode = SQLITE_OK;
  if (!job) {
    *rescode = SQLITE_MISUSE;
    return false;
  }
  moonbit_sqlite3_notification_t duplicate =
    moonbit_sqlite3_duplicate_notification(notification);
#ifdef _WIN32
  if (!duplicate) {
#else
  if (duplicate < 0) {
#endif
    *rescode = SQLITE_IOERR;
    return false;
  }
  job->executor_job.next = NULL;
  job->executor_job.run = NULL;
  job->notification = duplicate;
#ifdef _WIN32
  job->result_published = 0;
#else
  atomic_init(&job->result_published, false);
#endif
  return true;
}

bool
moonbit_sqlite3_job_submit(
  moonbit_sqlite3_job_t *job,
  moonbit_sqlite3_executor_t *executor,
  moonbit_sqlite3_notification_t notification,
  void (*run)(moonbit_sqlite3_executor_job_t *job),
  int32_t *rescode
) {
  *rescode = SQLITE_OK;
  if (!executor) {
    *rescode = SQLITE_MISUSE;
    return false;
  }
  if (!moonbit_sqlite3_job_initialize(job, notification, rescode)) {
    return false;
  }
  job->executor_job.run = run;
  if (!moonbit_sqlite3_executor_submit(executor, &job->executor_job)) {
    moonbit_sqlite3_close_notification(job->notification);
#ifdef _WIN32
    job->notification = NULL;
#else
    job->notification = -1;
#endif
    *rescode = SQLITE_IOERR;
    return false;
  }
  return true;
}

void
moonbit_sqlite3_job_capture_error(
  moonbit_sqlite3_job_t *job,
  sqlite3 *database
) {
  job->extended_rescode = database
    ? sqlite3_extended_errcode(database)
    : job->rescode;
  if (!database) {
    return;
  }
  const uint16_t *message = (const uint16_t *)sqlite3_errmsg16(database);
  if (!message) {
    return;
  }
  size_t length = 0;
  while (message[length] != 0) {
    length++;
  }
  if (length == 0) {
    return;
  }
  if (length > INT32_MAX || length > SIZE_MAX / sizeof(uint16_t)) {
    job->rescode = SQLITE_TOOBIG;
    job->extended_rescode = SQLITE_TOOBIG;
    return;
  }
  job->message = malloc(length * sizeof(uint16_t));
  if (!job->message) {
    job->rescode = SQLITE_NOMEM;
    job->extended_rescode = SQLITE_NOMEM;
    return;
  }
  memcpy(job->message, message, length * sizeof(uint16_t));
  job->message_length = (int32_t)length;
}

void
moonbit_sqlite3_job_publish_result(moonbit_sqlite3_job_t *job) {
  /* The release operation publishes every preceding result write, including
   * fields owned by a concrete job. The waiter performs the matching acquire
   * after the private pipe reaches EOF. Closing the sole writer is the
   * completion signal: no fallible write, or foreign Windows IOCP packet,
   * can outlive the job or strand the waiter.
   * Copy the notification first because the worker must not touch the job
   * after publishing it. */
  moonbit_sqlite3_notification_t notification = job->notification;
#ifdef _WIN32
  job->notification = NULL;
#else
  job->notification = -1;
#endif
#ifdef _WIN32
  InterlockedExchange(&job->result_published, 1);
#else
  atomic_store_explicit(
    &job->result_published,
    true,
    memory_order_release
  );
#endif
  moonbit_sqlite3_close_notification(notification);
}

bool
moonbit_sqlite3_job_result_is_published(moonbit_sqlite3_job_t *job) {
  if (!job) {
    return false;
  }
#ifdef _WIN32
  return InterlockedCompareExchange(&job->result_published, 0, 0) != 0;
#else
  return atomic_load_explicit(
    &job->result_published,
    memory_order_acquire
  );
#endif
}

void
moonbit_sqlite3_job_dispose(moonbit_sqlite3_job_t *job) {
#ifdef _WIN32
  if (job->notification) {
    moonbit_sqlite3_close_notification(job->notification);
    job->notification = NULL;
  }
#else
  if (job->notification >= 0) {
    moonbit_sqlite3_close_notification(job->notification);
    job->notification = -1;
  }
#endif
  free(job->message);
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_sqlite3_job_acquire_result(moonbit_sqlite3_job_t *job) {
  return moonbit_sqlite3_job_result_is_published(job) ? 1 : 0;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_sqlite3_job_rescode(moonbit_sqlite3_job_t *job) {
  return job && moonbit_sqlite3_job_result_is_published(job)
    ? job->rescode
    : SQLITE_MISUSE;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_sqlite3_job_extended_rescode(moonbit_sqlite3_job_t *job) {
  return job && moonbit_sqlite3_job_result_is_published(job)
    ? job->extended_rescode
    : SQLITE_MISUSE;
}

MOONBIT_FFI_EXPORT
moonbit_string_t
moonbit_sqlite3_job_message(moonbit_sqlite3_job_t *job) {
  int32_t length = job && moonbit_sqlite3_job_result_is_published(job)
    ? job->message_length
    : 0;
  moonbit_string_t message = moonbit_make_string_raw(length);
  if (length > 0) {
    memcpy(message, job->message, (size_t)length * sizeof(uint16_t));
  }
  return message;
}
