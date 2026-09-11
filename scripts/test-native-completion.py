"""Check the native completion protocol on POSIX, with ASan and UBSan."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
moon_root = Path(shutil.which("moon")).resolve().parent.parent
ffi = root / "internal/ffi"
with tempfile.TemporaryDirectory(prefix="sqlite3-completion-") as directory:
    executable = Path(directory) / "test"
    subprocess.run(
        [
            os.environ.get("CC", "cc"),
            "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
            "-pthread", "-I", str(moon_root / "include"), "-I", str(ffi),
            str(root / "tests/job_completion.c"), str(ffi / "job.c"),
            str(ffi / "executor.c"), str(ffi / "sqlite3.c"),
            "-lm", "-ldl", "-o", str(executable),
        ],
        check=True,
    )
    subprocess.run([str(executable)], check=True)
print("Native completion: 1000 immediate releases passed (ASan/UBSan).")
