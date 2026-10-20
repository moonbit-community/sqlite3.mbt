#include "../../ffi/sqlite3.h"
#include <moonbit.h>

/* These callbacks touch only native storage, including on SQLite workers. */
static int policy_marker;

static int deny_attach(void *context, int action, const char *arg1,
                       const char *arg2, const char *database,
                       const char *trigger) {
  (void)arg1;
  (void)arg2;
  (void)database;
  (void)trigger;
  if (context != &policy_marker) {
    return SQLITE_DENY;
  }
  return action == SQLITE_ATTACH ? SQLITE_DENY : SQLITE_OK;
}

typedef int (*authorizer_callback)(void *, int, const char *, const char *,
                                   const char *, const char *);

MOONBIT_FFI_EXPORT authorizer_callback sqlite3_test_authorizer(void) {
  return deny_attach;
}

MOONBIT_FFI_EXPORT void *sqlite3_test_authorizer_context(void) {
  return &policy_marker;
}
