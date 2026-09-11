- compile_flags.txt

```
-I/home/<user>/.moon/include
```

## Resource lifetime

SQLite connections and prepared statements use backend-specific opaque handles.
They are released only by explicit calls to `Connection::close()` and
`Statement::finalize()`; dropping the corresponding MoonBit values does not
release SQLite resources.

This is intentional. The WebAssembly host cannot observe MoonBit
reference-count release through a native free callback. Native-only finalizers
would therefore make resource lifetime depend on the selected backend: code
that accidentally omitted `close()` or `finalize()` could appear to work on
native while leaking on WebAssembly. Requiring explicit release gives every
backend the same contract.

Connections keep their optional handle in shared `Ref` state, while statements
use a mutable struct that also records current-row validity and retains the
originating connection for error-message capture. Copies therefore observe the
same closed or finalized state and cannot reuse a released raw handle.

## Native FFI adapters

Functions whose MoonBit native ABI already matches SQLite bind directly to the
corresponding `sqlite3_*` symbol. The C stub is reserved for actual adaptation:
reshaping open and prepare results, supplying omitted callback arguments, and
copying strings or blobs across the ownership boundary.

SQLite reports result-column conversion allocation failures only through the
connection-wide error state. The text and BLOB adapters compare that state
immediately before and after conversion, so an older `SQLITE_NOMEM` from
another statement is not assigned to a legitimate empty or `NULL` value. A
newly observed `SQLITE_NOMEM` invalidates the statement's current row. If the
connection already reports `SQLITE_NOMEM`, SQLite provides no public API that
can distinguish a simultaneous second conversion failure from that older
state; the adapters avoid the unsafe false positive.

Native asynchronous operations use a generic per-connection executor and job
envelope. The envelope owns queue linkage, completion notification, and an
immutable diagnostic snapshot. Each operation owns its copied inputs, typed
result, blocking SQLite call, and cleanup in a separate C file. Resource-
producing jobs transfer successful handles to MoonBit only after the public API
has validated the complete result and checked cancellation. Rejected results
are asynchronously discarded before their job is released. The worker touches
only raw SQLite handles; mutable
MoonBit wrapper state remains confined to the event-loop thread.

Open and prepare jobs embed a second queue envelope for disposal. Both
completion pipes and all C storage are reserved before submission, so rejecting
a successful result never needs another fallible allocation. Disposal closes
an unclaimed database or finalizes an unclaimed statement on the connection's
worker. The owning job stays alive until disposal completes.

Workers release-publish their results and close the sole completion writer;
the waiter acquires the publication after EOF. There is no notification byte
write and no worker-owned Windows `OVERLAPPED` that could escape onto the
runtime's IOCP. `python scripts/test-native-completion.py` checks publication
and immediate release under ASan/UBSan on POSIX.

Connections are opened with `SQLITE_OPEN_FULLMUTEX`. Synchronous calls bypass
the executor and bracket each logical operation and its error lookup with
SQLite's recursive connection mutex; native jobs use the same mutex while
capturing their result. The MoonBit connection state counts outstanding jobs,
so `close` can reject destruction without moving lifecycle policy into the C
executor. Statements similarly reject synchronous use while their asynchronous
step is outstanding. Sync-only connections never create an executor. A step
job also captures its direct row-change count before releasing the mutex, which
keeps that result attributable to the operation that produced it.

## Wasm FFI adapter

The Wasm adapter targets moonrun's `moonbitlang/sqlite` import ABI. Native
SQLite pointers never enter guest memory; moonrun owns them and returns typed
64-bit handles. SQL and text use MoonBit's UTF-16 storage directly, while
filenames and blobs use checked byte ranges. Variable-length results are
measured and copied into MoonBit-owned buffers during synchronous host calls.

Async open, prepare, and step use the host job ABI merged in
[moon PR #2169](https://github.com/moonbitlang/moon/pull/2169), with the
`thread_pool/spawn_worker_with_pipe` import from
[moon PR #2185](https://github.com/moonbitlang/moon/pull/2185). Each connection
lazily reserves a public `@pipe.pipe()` before creating its first job. The
first submission starts a host worker that retains the pipe writer; later
submissions reuse that worker through `thread_pool/wake_worker`. A guest async
mutex serializes submission and completion reads for that connection. SQLite
workers can coexist with filesystem jobs on the same async event loop without
registering jobs in async's private scheduler.

Each completion is a four-byte little-endian ID. The waiter reads the complete
ID and checks it before accessing the host result; EOF indicates a broken
channel, not job completion. Closing the guest writer after worker creation is
safe because the host retains it until the worker is freed. Connection close
releases the idle worker and reader after all outstanding jobs have finished.

Jobs copy inputs before suspension, retain host resource leases until release,
and return immutable diagnostics and change counts. Cancellation is shielded
through completion. Cancellation and SQL-tail rejection submit a discard job
on the same worker and pipe while the original result is still unclaimed. The
published `moonbitlang/async` 0.21.2 dependency needs no patch or additional
guest event loop.

`scripts/test-wasm-errors.py` tests the public error contract by injecting pipe
creation and completed-job status failures into a temporary copy of the Wasm
adapter. The dependency and runtime are unchanged. It checks error translation
and resource reuse for open, prepare, step, and disposal of rejected or cancelled
results. Keep translation around the whole public operation: catching only job
construction misses failures reported during completion or disposal.

Build the known compatible runtime and select it with `MOONRUN_OVERRIDE`:

```bash
cargo install --git https://github.com/moonbitlang/moon --rev 230003a6671939d12dc20521498c91df367c27a7 --locked --root .moonrun --bin moonrun moonrun
moon check --target wasm
MOONBIT_ASYNC_CHECK_FD_LEAK=1 MOONRUN_OVERRIDE="$PWD/.moonrun/bin/moonrun" moon test --target wasm
```

The pinned moonrun revision supports in-memory and policy-checked file-backed
databases, statement reset and binding cleanup, affected-row counts, and
result-column names. It uses `libsqlite3-sys` `0.38.2`, bundling SQLite
`3.53.2`. File access remains subject to the host runtime's filesystem policy.
The host also rejects `PRAGMA busy_timeout`, so the two lock-wait regressions
that depend on that pragma remain native-only. Other lifecycle, cancellation,
diagnostic, file persistence, and concurrency tests run on both backends.

The column-name length/copy ABI reserves `-1` for SQLite's NULL pointer, `0` for
an explicit empty name, and positive values for UTF-16 content lengths. The
adapter already implements this convention. Hosts predating the corresponding
runtime change still return zero for NULL, so only those hosts cannot report
the rare `sqlite3_column_name16` conversion allocation failure.
