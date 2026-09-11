#include "job.h"
#include <assert.h>
#include <moonbit.h>
#include <stdlib.h>
#include <unistd.h>

moonbit_sqlite3_executor_t *moonbit_sqlite3_executor_create(int32_t *rescode);
void moonbit_sqlite3_executor_release(moonbit_sqlite3_executor_t *executor);

/* This test exercises C-owned publication only, without the MoonBit allocator. */
moonbit_string_t moonbit_make_string_raw(int32_t length) {
  (void)length;
  abort();
}

static void complete(moonbit_sqlite3_executor_job_t *executor_job) {
  moonbit_sqlite3_job_t *job = (moonbit_sqlite3_job_t *)executor_job;
  job->rescode = SQLITE_DONE;
  job->extended_rescode = SQLITE_DONE;
  moonbit_sqlite3_job_publish_result(job);
}

int main(void) {
  int32_t code;
  moonbit_sqlite3_executor_t *executor = moonbit_sqlite3_executor_create(&code);
  assert(code == SQLITE_OK);
  for (int i = 0; i < 1000; ++i) {
    int notification[2];
    assert(pipe(notification) == 0);
    moonbit_sqlite3_job_t *job = calloc(1, sizeof(*job));
    assert(job);
    assert(moonbit_sqlite3_job_submit(
      job, executor, notification[1], complete, &code
    ));
    close(notification[1]);
    char byte;
    /* EOF is the entire completion protocol. A byte write would reintroduce
     * fallible notification I/O and the foreign OVERLAPPED lifetime on Windows. */
    assert(read(notification[0], &byte, 1) == 0);
    assert(moonbit_sqlite3_job_result_is_published(job));
    assert(job->rescode == SQLITE_DONE);
    assert(job->extended_rescode == SQLITE_DONE);
    close(notification[0]);
    moonbit_sqlite3_job_dispose(job);
    // Release immediately, even if the worker has not returned from publish.
    free(job);
  }
  moonbit_sqlite3_executor_release(executor);
}
