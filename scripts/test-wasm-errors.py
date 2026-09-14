"""Inject notification and host-job failures at the Wasm FFI boundary."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile


root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="sqlite3-wasm-errors-") as directory:
    project = Path(directory) / "sqlite3"
    shutil.copytree(
        root,
        project,
        symlinks=True,
        ignore=shutil.ignore_patterns(
            ".git", ".mooncakes", "_build", ".moonrun", ".agents", ".codex",
        ),
    )
    shutil.copytree(root / ".mooncakes", project / ".mooncakes", symlinks=True)
    adapter = project / "internal/ffi/ffi_async_wasm.mbt"
    source = adapter.read_text()
    pipe = "let (reader, writer) = @pipe.pipe()"
    status = 'fn sqlite3_job_get_err_import(job : UInt64) -> Int = "moonbitlang/async" "thread_pool/job_get_err"'
    assert source.count(pipe) == 1 and source.count(status) == 1
    source = source.replace(pipe, '''let (reader, writer) = if sqlite3_test_failure.val < 0 {
      sqlite3_test_failure.val = 0
      raise @os_error.OSError(5, context="injected pipe creation failure")
    } else {
      @pipe.pipe()
    }''')
    source = source.replace(status, '''fn sqlite3_real_job_get_err_import(job : UInt64) -> Int = "moonbitlang/async" "thread_pool/job_get_err"

///|
let sqlite3_test_failure : Ref[Int] = Ref(0)

///|
pub fn sqlite3_test_fail_after(jobs : Int) -> Unit {
  sqlite3_test_failure.val = jobs
}

///|
fn sqlite3_job_get_err_import(job : UInt64) -> Int {
  // Complete the real job and restore its result before injecting an error.
  let error = sqlite3_real_job_get_err_import(job)
  if sqlite3_test_failure.val > 0 {
    sqlite3_test_failure.val -= 1
    if sqlite3_test_failure.val == 0 {
      return 5
    }
  }
  error
}''')
    adapter.write_text(source)
    shutil.copyfile(
        root / "tests/async_error_contract.mbt",
        project / "async_error_contract_test.mbt",
    )
    subprocess.run(
        ["moon", "test", "async_error_contract_test.mbt", "--target", "wasm"],
        cwd=project,
        env=dict(os.environ, MOONBIT_ASYNC_CHECK_FD_LEAK="1"),
        check=True,
        timeout=120,
    )

print("Wasm error contract: construction, completion, and disposal failures passed.")
