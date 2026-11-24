# AGENTS.md

Orientation for an LLM coding agent working in this tree: AOK-iSH.

AOK-iSH runs Linux binaries on iOS by JIT-translating guest machine code (i386,
amd64, arm64, riscv64, ppc64) and reimplementing the Linux kernel surface it
needs (syscalls, VFS, signals, sockets, ptrace, procfs) in C. It is a heavily
diverged fork of [ish-app/ish](https://github.com/ish-app/ish).

This file is the long version. The committed, authoritative orientation
document is **[docs/llm_onboarding.md](docs/llm_onboarding.md)**; read it before
substantive work. The upstream tree this is forked from deliberately gitignores
`AGENTS.md` and every other tool-specific agent config file, treating them as
personal, per-checkout tooling; AOK-KSH diverges from that policy and commits
this file as shared team orientation. `.gitignore` keeps the *other* agent-config
names ignored, and an upstream merge will re-add `AGENTS.md` to it — drop that
line again when one lands. Improvements to orientation belong in this file and
in `docs/llm_onboarding.md`; keep the two in agreement.

---

## 1. The five things that break silently

None of these produce a build error, a test failure, or a missing-file report.
The thing is simply absent at runtime.

1. **`fs/aok-*.manifest`** (e.g. `fs/aok-tests.manifest`): a file not listed is
   not embedded into `/AOK` and does not exist in the guest.
2. **`tests/manual/setup-regressions.sh`**: even when manifest-listed, a test
   must appear in both `need_file` (existence check) and the `all_tests` string
   to be built and run. Missing from `all_tests` means it never executes while
   the suite still reports a clean pass. Or worse the opposite, never checked:
   a missing `need_file` skips the whole suite.
3. **`kernel/native.c`**: the native-program registry. A native program absent
   here is unreachable at `/AOK/native/<name>` no matter how it links.
4. **Xcode build settings**: a meson option with no mirrored knob in
   `app/iSH.xcconfig` / `xcode-meson.sh` never reaches the shipping app build.
   A correct `meson`/`ninja` build proves nothing about the IPA.
5. The `fs/aok-*.manifest` files are read **at meson configure time** and
   embedded via a `custom_target`; they are not scanned at runtime. Editing a
   manifest (or adding a file it names) needs a reconfigure, not just `ninja`.

The reverse trap also exists: **deleting a native program's registry entry
does not remove the code from the binary.** `meson.build` links native programs
with `link_whole`, so bash's 144 objects and readline's 35 stay in `libish.a`
anyway; only the build option (`-Dnative_bash=disabled`, the default) leaves
them out. See licensing below.

---

## 2. There are two builds, and Xcode is the only one that ships

- **Meson/Ninja** builds the standalone emulator `build/ish`, plus host tools
  (`fakefsify`, `ptraceomatic`, the vDSOs). This is the fast iteration loop on
  macOS and Linux, and everything CI on Linux compiles. It is **not** the app.
- **Xcode** builds `iSH-AOK.xcodeproj` (targets `AOK-iSH`, the `iSH-AOK.FileProvider`
  extension, and UI tests) into the shipping IPA. Xcode does not compile `kernel/`,
  `emu/`, `fs/` or `jit/` itself: two legacy targets drive meson and ninja via
  `xcode-meson.sh` and `xcode-ninja.sh`, out of `$(MESON_BUILD_DIR)` (set in
  `app/Project.xcconfig` to a directory under DerivedData), and the app links the
  resulting `libish.a`, `libish_emu.a`, `libfakefs.a` plus a separately-built
  `libarchive.a` from `deps/libarchive.xcodeproj`.

Consequences:

- **Verify what the user runs.** A change that works under meson can be absent
  from the app because the Xcode knob doesn't exist or defaults differently.
- `xcode-meson.sh` passes every mirrored option explicitly on each reconfigure
  (`-Dnative_bash`, `-Dnative_helix`, `-Dnative_rust_target`, `-Dlog`, ...)
  *because meson caches option values per build directory*: changing a default
  in `meson_options.txt` does not move an existing DerivedData tree.
- `xcode-ninja.sh` runs `ninja` per arch and `lipo`s the results into fat
  archives; a single-arch build is symlinked.
- Never run `git submodule update --init` from a git worktree; its gitdir is
  shared and the submodule update cross-contaminates. Use `clone --shared`.
- **Never run the guest suite concurrently with `xcodebuild`.** Timing tests
  report `[HANG]` under that load and it is indistinguishable from a regression.

---

## 3. Clone and submodules

```bash
git clone --recurse-submodules git@github.com:emkey1/ish-AOK.git
cd ish-AOK
# already cloned without submodules:
git submodule update --init --recursive
git -C deps/smallclue submodule update --init third-party/openssh third-party/nextvi third-party/libgit2
(cd deps/dash && ../../tools/configure-dash.sh --quiet)
(cd deps/libapps/hterm && python3 bin/mkdist)
```

What is missing when a submodule is absent (none of these is always fatal):

| Submodule | When absent |
|---|---|
| `deps/smallclue` (+its `third-party/openssh`, `nextvi`, `libgit2`) | **meson silently swaps in stubs** and only WARNs at setup. ssh says "not built into this AOK-iSH", `vi` is a stub, no git. Most dangerous gap: the build stays green. |
| `deps/dash` | Hard error (`native_dash` is enabled by default). Needs `tools/configure-dash.sh --quiet` after checkout (configure only; dash's own `make` is never run). |
| `deps/zsh` | Hard error (`native_zsh` is enabled by default). |
| `deps/bash` | Only built with `-Dnative_bash=enabled`; default off. |
| `deps/helix`, `deps/tokio`, `deps/signal-hook` | Required by the app build (`AOK_NATIVE_HELIX=YES`), which then hard-errors without cargo/llvm-objcopy. |
| `deps/virglrenderer`, `deps/MoltenVK` | With `gpu=auto` (default) the GPU stack is silently disabled; `-Dgpu=enabled` errors. |
| `deps/libapps` | `xcode-meson.sh` skips regenerating hterm; the app's JS phase fails on missing `hterm_all.js`. |
| `deps/libarchive` | The Xcode `libarchive` target fails; the app links `libarchive.a`. |
| `deps/rootfs-manifest` | In-app root download catalogue resource missing. |

`subprojects/MoltenVK` and `subprojects/virglrenderer` are **symlinks** into `deps/`.

Never run `git submodule update --init` from a git worktree; its gitdir is
shared and the run cross-contaminates submodules. Use `clone --shared`.

---

## 4. Commands you will actually use

Nothing is obvious here: it is a C emulator plus an Xcode app plus 12
submodules. The commands, grouped by task:

### Build the standalone emulator (fast loop)
```bash
meson setup build --buildtype=debugoptimized     # NOT the meson default (debug/-O0)
ninja -C build                                # or: ninja -C build <target>
```
`--buildtype=debugoptimized` is not a preference. `debug` is `-O0`, and an `-O0`
build not only runs slower, it invalidates every measurement (timing,
throughput, lock contention) taken on it. On such a build the guest's
`uname -v` ends in ` unoptimized`, which is how you know you measured nothing.

Overridable settings, all in `meson_options.txt` (read the file: each option's
comment explains why its default is what it is):

| Option | Default | Effect |
|---|---|---|
| `guest_archs` | `i386,amd64,arm64,riscv64,ppc64` | which guest ABIs this build can execute (array; at least one) |
| `engine` | `jit` | `jit` is the only choice today |
| `arm64_gret` | `dmb` | gadget dispatch for the fully-translated guests; `ldar` is ~6% faster on Apple Silicon only |
| `log` / `nolog` / `log_handler` | empty / `dprintf` | logging channels (`strace`, `verbose`, `instr`, ...); see debugging below |
| `native_bash` | `disabled` | GPLv3; non-default-safe, see licensing |
| `native_zsh` | `enabled` | permissive |
| `native_dash` | `enabled` | BSD-3-Clause |
| `native_helix` | `disabled` | MPL-2.0, ~45MB; enabled in the **app** build via `app/iSH.xcconfig` |
| `native_rust` | `auto` | Rust native program; needs cargo and llvm-objcopy |
| `native_rust_features` | empty | e.g. `tokio-probe` for the kqueue front end |
| `gpu` | `auto` | /dev/dri/renderD128 with virglrenderer Venus |
| `no_crlf` | `false` | terminal output without CRLF translation |

Enable a log channel per channel name, e.g.:
```bash
meson setup build --buildtype=debugoptimized -Dlog=strace      # or: -Dlog='verbose strace'
```
The channels are compile-time (`DEBUG_<NAME>`), off unless named. To add a
channel, name it in `-Dlog` and call `TRACE(<chan>, ...)` / `STRACE(...)` from
`debug.h`. Never use printf in kernel/fs hot paths.

### Run a guest in the CLI emulator
```bash
./build/ish -f build/alpine /bin/login -f root
```
- `-f <dir>` names a fakefs (the in-app filesystem, backed by SQLite). Omit it
  to run against a **realfs** root (an actual host directory), the usual
  choice when working on the VFS itself.
- `-r <dir>` is the root; `-d` the working directory; `-c` the console.
  Read `xX_main_Xx.h`: it holds the real usage and mount logic, shared with the
  iOS app.
- The rootfs tarballs at the repo root are committed blobs (plain
  `alpine-minirootfs-*` / `devuan-minirootfs-*`) fine for CLI use, but the Xcode
  "Download Root" phase bundles only the aarch64 ones. If you create a
  fakefs from a tarball yourself:
  ```bash
  ./build/tools/fakefsify <rootfs.tar.xz> <fakefs-dir>
  # e.g. from the repo root, which creates build/alpine:
  #   ./build/tools/fakefsify alpine-minirootfs-3.24.2-aarch64.tar.xz build/alpine
  ```

### App build
```bash
xcodebuild \
  -project iSH-AOK.xcodeproj \
  -scheme iSH-AOK \
  -configuration Debug-ApplePleaseFixFB19282108 \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates build
```
`Debug-ApplePleaseFixFB19282108` is the fork's own debug configuration, not
a stock Debug (its name records the FB ticket its library-loading workaround
was copied for). This drives meson via legacy targets `Meson` and `Ninja`;
the app itself links `libish.a`, `libish_emu.a`, `libfakefs.a`. Requires
the Metal toolchain component on Xcode 26+:
`xcodebuild` with `-downloadComponent MetalToolchain`. Do **not**
confuse yourself by verifying under `ninja`; the Xcode build is the one
that ships.

### Host unit tests / e2e
```bash
meson test -C build
meson test -C build float80 riscv64_decode --print-errorlogs   # the two CI gate tests
meson test -C build e2e --print-errorlogs                       # fork/exec e2e; NOT guest gate
```
`float80` skips on hosts whose `long double` is not x87 80-bit (Apple silicon);
there is no reference to compare against there. `e2e` runs
`tests/e2e/e2e.bash -y` (meson timeout: 1800s): on first run it downloads an
Alpine rootfs, `fakefsify`s it, installs build-base under emulation, compiles a
large C file with the guest gcc, and runs the `tests/e2e/*` cases (fpu,
net_regress, qemu, sse2, shell, utimens_symlink, hello). It needs a network the
first time. Host `meson test` is a fraction of the coverage the guest suite
gives; it is a pre-push gate, never a substitute.

### Guest regression suite — the primary gate
It runs **inside a booted guest**, one program per test, exit status is the
verdict:

```bash
# In the guest (e.g. after ./build/ish -f build/alpine /bin/login -f root):
sh /AOK/tests/setup-regressions.sh --install-deps --run          # build + run all
sh /AOK/tests/setup-regressions.sh --run                        # toolchain already present
sh /AOK/tests/setup-regressions.sh --run --only fs_conformance,futex_core   # a subset
sh /AOK/tests/setup-regressions.sh --run -v                     # each binary -v
```
Options: `--install-deps` (apk build-base, else apt build-essential, else
error), `--run`, `--only NAME[,NAME...]`, `-v/--verbose`, `--src DIR`
(default `/AOK/tests`, overridable `ISH_AOK_TEST_SRC`), `--work DIR` (output
dir; defaults `$TMPDIR/ish-aok-regressions`, `/tmp/ish-aok-regressions`,
or `./ish-aok-regressions` in that order; overridable `ISH_AOK_REGRESS_DIR`).
The runner writes `<test>.out` and expects the marker `^<test>: (PASS|FAIL|SKIP)`
on a line; a killed test reports `FAIL no PASS/FAIL/SKIP marker, killed by
signal N`; `SKIP` is not a failure. A per-source-hash build cache lives at
`/AOK/fakefs/regress-cache` (override `ISH_AOK_REGRESS_CACHE`, disable
`ISH_AOK_REGRESS_NOCACHE=1`); compiling on a device is slow, readable
`tools/regress-cache.sh` moves it between a Mac and a device. ~65 tests
want root **including the setuid-switched tests that need uids the app
doesn't ship with**; on an unprivileged session the suite is supposed to
retire **the whole group** transparently, never quietly as a pass (see
`needs_root_tests` in `setup-regressions.sh`). Not checked is the same as
not shipped: add the source to `tests/manual/`, list it in BOTH
`need_file` and `all_tests` of `setup-regressions.sh`, AND line it in
`fs/aok-tests.manifest`.

Three suites are shell scripts, not C, and bypass `setup-regressions.sh`
(prebuilt list, shipped straight by the manifest, run directly from
`/AOK/tests`): `native_zsh_fork_state.sh` (119 cases), 
`native_bash_fork_state.sh` (20; needs the native bash build) and
`native_stdio_redirect.sh`.

`--install-deps --run` is the right invocation on a device/CI from a **fresh
root**; on the first run it compiles the whole suite (500+ programs), which on real hardware
takes significant time and is the reason no agent "just runs the suite"
casually — read `.jules/bolt.md` before you start a full suite build in the
background.

### Differential suite (not in CI, needs a device or a Mac)
Two harnesses compare the guest against real Linux rather than against expected output:

- **`ptraceomatic`** (`tools/ptraceomatic.c`): runs each test case under a ptrace
  oracle on macOS, then under iSH, and compares the syscall behaviour.
- **`unicornomatic`** (`tools/unicornomatic.c`) and `tests/remote/conductor.py`:
  run a corpus across every (arch x engine) combination (oracle, 32-bit, amd64 JIT, ...), comparing status and per-key fields rather than whole files. Needs a real machine.

Commands and corpus layout are documented in `tests/remote/README.md`; do not
invent invocations.

---

## 5. Repository map

```
app/            iOS app (ObjC + some Swift): terminal, RFB/Metal display, LLM chat,
                mic capture (/dev/mic), Workspace, FileProvider extension, UITests,
                12 lproj languages
app/terminal/   hterm-based web terminal (term.html/js/css); hterm_all.js is a
                BUILD ARTIFACT, not source (see build gotchas)
emu/            guest CPU state, memory, TLB, FPU/vector, per-arch decode (arch/),
                per-arch interpreters (amd64_interp.c, arm64_interp.c)
kernel/         the guest "kernel": tasks/threads (task.*), syscall dispatch
                (calls.*), exec/fork/exit, signals, futex, epoll, ptrace,
                checkpoint/suspend, swap, native program registry + glue
jit/            the gadget JIT: gen.c (translator), jit.c (block cache),
                helpers, per-guest engines (guest-arm64, guest-ppc64, guest-riscv64),
                per-host gadget libs (gadgets-x86_64, gadgets-aarch64),
                HLE (hle.c), jitprof
fs/             VFS: path.c, realfs (real.c), fakefs (fake*.c, SQLite-backed),
                procfs (proc/, proc/ish.c), aokfs (aok.c + aok-*.manifest),
                sockets (sock.c), fuse, tty, virtgpu, net_*
platform/       host OS seam: darwin.c, linux.c, standalone.c
util/           intrusive lists, timers, sync primitives, lockstats, refcount
vdso/           per-arch guest vDSOs (i386, amd64, arm64, riscv64, ppc64);
                cross-compiled to guest ELFs, installed by kernel/exec.c
opt/AOK/        the payload compiled into /AOK: docs/ (31 user-facing docs),
                tools/ (in-guest shell tools: setup-wayland.sh, ktop, manage-roots.sh,
                suspend.sh, native-links.sh, ...), bundled/ (rootfs tarballs),
                share/terminfo
tests/          manual/ (the guest regression suite, ~480 files incl. ~120 x86/ tests),
                e2e/ (e2e.bash + 7 cases), unit/ (5 ObjC LLM-chat tests),
                remote/ (differential conductor + corpora), bench-ab/ (on-device
                benchmarks), bench-utm/ (mostly moved to emkey1/aok-vm),
                arm64/ ppc64/ riscv64/ (hand-written .s guest programs), audio/, workspace/
tools/          ~124 host-side files: gen-*.py (test/code generators),
                check-*.py (release checkers, run via check-all.py),
                bash-tls-*/dash-tls-* (vendored-shell TLS rewrites),
                build-*.sh, configure-dash.sh / configure-zsh.sh,
                fakefsify.c, run-guest-gate.sh, regress-cache.sh, remote-suite.sh
docs/           llm_onboarding.md (the committed agent entry point), TODO.md
                (lab notebook, ~2400 lines), roadmap.md, build_*_musts.md,
                release-notes/, book/ (42 chapters + 8 appendices), historical/
deps/           vendored submodules: bash, zsh (configured tree), dash, helix,
                tokio, signal-hook, rust-native, smallclue, libapps, libarchive,
                rootfs-manifest, virglrenderer, MoltenVK, aports, *shim/ trees
subprojects/    MoltenVK and virglrenderer symlinks (meson subproject view)
```

---

## 6. Architecture and control flow

Boot: `main()` (`main.c`) applies `ISH_*` env toggles, then `xX_main_Xx()`
(`xX_main_Xx.h` — logic in a header, deliberately shared by CLI and app) parses
`+r:f:d:c:` (root, fakefs, workdir, console), mounts the root, becomes the first
process, runs `ish_boot_setup_hook` (`/dev`, `/proc`, `/sys`, `/AOK`), restores
a checkpoint if any, and execs the initial command.

Per guest thread: `task_run_current()` (`kernel/task.c`) loops
`interrupt = cpu_run_to_interrupt(&task->cpu, &tlb); handle_interrupt(interrupt);`
under the address-space read lock. The engine (`jit/jit.c`) runs JIT-compiled
blocks (`jit/gen.c` compiles them; hand-written gadgets in `jit/gadgets-*/`),
falling back to the per-arch interpreter, and *returns an interrupt number*
rather than returning normally.

`handle_interrupt()` (`kernel/calls.c`) dispatches: the five per-ABI syscall
vectors go through `struct syscall_abi_dispatch` tables (one per guest ABI) into
handlers that return negative errno and call into `kernel/fs.c` → `fs/`
(realfs/fakefs/procfs/aokfs) → `platform/` for host syscalls. `INT_PF` page
faults go to `emu/memory.c`. A native program never enters this loop: it runs as
host code on the guest task's own thread and calls `syscall_dispatch_native()`.

**Native programs** (the fork's central idea; full model in `kernel/native.h`):
compiled-into-the-binary host C functions, reached via `/AOK/native/<name>`,
exec-matched on the *resolved* path so symlinks dispatch natively. Things easy
to get wrong:
- not a host process — runs on the calling task's thread inside `execve`; it
  blocks that guest task for its whole duration; its return value is the exit status
- linked against the *host* libc — all I/O must go through iSH's kernel
  (`fd_write_host_buf` and friends in `kernel/fs.h`); a bare `open()` hits the host fs
- the process outlives the program — any global state must be torn down on exit
  or keyed by `nlibc_invocation_token()`, or the second run in a session breaks
  (the tokio signal-socketpair bug is the documented example)
- a setuid-root entry uses one `setuid_root` flag, not mode+owner; and a
  checkpoint can only take a native program if it provides `ckpt_dump`/
  `ckpt_state_var`/`ckpt_fds` (self-description) — otherwise the checkpoint refuses
- adding one: a `struct native_program` table entry in `kernel/native.c` plus a
  node in `fs/aok.c`. `/AOK/native` serves exactly the registered set.

Available native programs (from `deps/` + `kernel/*_glue.c`): zsh (the shipped
shell), dash/sh, smallclue (busybox-style multicall toolbox, plus setuid
su/sudo/passwd applets that take their name from the call site, never argv[0]),
helix (`hx`), openssh, ktop, nextvi (vi), libgit2 (git), and Rust `rust-probe`.
`bash` is compiled only when enabled.

The guest vDSO (`vdso/`) cross-compiles tiny per-arch ELFs whose `int $0x80` /
`syscall` time calls trap into the kernel — glibc's vDSO fast path without a
full page-fault cycle.

---

## 7. Collaboration and institutional memory

This tree is developed heavily by LLM agents. The memory system is part of the
codebase; respect it.

- **`docs/TODO.md`** (~2400 lines) is a lab notebook, not a task list:
  diagnosed-but-unfixed bugs with measurements, rejected designs, wrong first
  hypotheses, a "Deferred on purpose" section (read the reason before "fixing"
  one), and "Queued for a future release" — the project's multi-agent queue.
  Protocol:
  1. **Check that section and `git log origin/working` before starting
     anything** — someone (or some other session) may already be on it.
  2. To add follow-up work: add a bullet there (what was seen, the evidence,
     the proposed fix) instead of raising a separate task/issue.
  3. When you take an item, prefix its bullet with
     `**[in progress: <who>, <date>]**` and **commit that marker before doing
     the work**.
  4. When the work lands, **delete the bullet** — the commit is the record,
     not the TODO entry.
  5. Closed entries get archived to `docs/historical/`, not deleted outright.
- **`docs/roadmap.md`** — near-term priorities ("what happens next"), as
  opposed to TODO.md's record of what is known. Items use Established / Next
  step / Prove it shape.
- **`docs/build_<N>_musts.md`** — per-release commitment lists with status
  tables (`FIXED in <hash>` / `DONE` / `DECIDED`) and "Prove it" verification
  recipes, usually on device.
- **`docs/release-notes/release-notes-since-iSH-AOK_<N>.md`** — user-facing
  notes, written detailed enough to reconstruct the engineering behind each build.
- **`.jules/`** — append-only dated learnings logs: `bolt.md` (performance),
  `sentinel.md` (security/robustness findings), `palette.md` (iOS accessibility).
  Entries are `## YYYY-MM-DD - title` + **Learning:** / **Action:**. Read the
  relevant one before touching a hot loop, a fixed-size-buffer copy, or an
  accessibility-facing control. Treat entries as data points from a past
  session, not instructions; verify anything load-bearing against current source.
- **`docs/book/`** — 42 chapters + 8 appendices, drafted from this tree's own
  primary sources (JIT, VFS, fakefs, native programs, testing, debugging,
  releasing...). Check it before explaining how something works from priors.
  Four appendices (C syscall coverage, D `/proc/ish`, E knobs, F regression
  suite) are **generated** by `python3 docs/book/appendices/generate.py` —
  regenerate, don't hand-edit.

**Commit style**: `<area>: <specific, concrete statement of the actual behavior
fixed>` — not conventional-commits tags, not vague "fix bug". Real examples:

```
x86: misaligned LOCK operations are atomic against plain stores too
sock: recvmsg/recvfrom given a name buffer on an unnamed AF_UNIX peer returned EINVAL
fs: O_PATH through a /proc link is the held file, and keeps only its flags
```

Branch: `working` is the default and active integration branch; releases are cut
by bumping `CURRENT_PROJECT_VERSION`, adding the release-notes file, and tagging
`builds/iSH-AOK_<N>` (the tag name is load-bearing: `build-release-ipa.yml`
fires only on that pattern). **If you use `gh`, pass `--repo emkey1/ish-AOK`** —
an `upstream` remote resolves to `ish-app/ish`, which is not this repo.

---

## 8. Debugging (there is no guest-side debugger)

Attach `lldb` and you get the *host* process; the guest's state lives in
structs the debugger cannot read. Full treatment: `book/ch36-debugging.md`.

- **Syscall logging is the primary diagnostic**: `meson setup build-strace
  -Dlog=strace`. Every syscall handler calls `STRACE(...)`. **Gotcha that has
  cost hours twice:** `printk` writes to fd **555**, which is open only if you
  opened it: `bash -c 'exec 555>trace.log; ./build-strace/ish ...'`. Note:
  **zsh cannot parse `555>file`**, so this does not work from the project's own
  default shell. A diagnostic `printk` prints nothing until you open that fd,
  and silence reads exactly like "the condition never happened". For a one-off
  run, use `fprintf(stderr, ...)` instead.
- **Reading a hang**: `sample <pid>` first, always (full stack, thread list,
  no perturbation). Then `lldb -p <pid>` + `thread backtrace all`. Rule:
  *blocked is not contended* — the separating question is who holds the lock.
- **Measuring locks**: `ISH_LOCKSTATS` / `ISH_FAKEFS_LOCKSTATS` instrument
  every lock with duty cycle, aggregate wait, per-call-site holds. Duty > 100%
  on an exclusive mutex means the tool is wrong; on a shared lock it means
  healthy concurrency. A lock saturated by one thread cannot be fixed by adding
  parallelism.
- **Hardware watchpoints with no debugger (arm64 host)**: `ISH_PTHREAD_WATCH`
  uses `thread_set_state(ARM_DEBUG_STATE64)` from inside the process, no
  entitlement, works on other threads while they run. Always run a positive
  control first — an unarmed watchpoint looks exactly like one that was never hit.
- **Forensics on stripped binaries / crash reports**: an unsigned register arg
  holding `0xffffffff` is a -1 sentinel; `libjvm.so+0xNNNNN` frames still
  identify the computation once disassembled; a GOT slot's target names an
  anonymous global.
- **Driving a full-screen guest program headlessly** (`top`, `btop`, `ktop`):
  you need a pty *with a size* (`TIOCSWINSZ`), often `--force-utf`, and a real
  screen reconstruction (handle `CUP`/`ED`/`EL`) — a terminal capture is not
  text; grepping it directly finds labels in the wrong places.

Rules that generalize here: check the oracle before claiming a defect; not
faulting is not executing; a knob that "fixes" a crash may just short-circuit
the path that reached the bug; root (uid 0 in the CLI) hides permission-ordering
bugs; **prove the instrument before believing a negative result** (the one that
recurs most).

**Telling a flake from a race**, in order, before any re-run: (1) A/B the
suspected cause in one binary — flip it, flip it back; (2) bisect the context
with `--only a,b,c` to rule out state left by a neighbouring test; (3)
`lldb -p <pid>` / `thread backtrace all` on a hang — look, don't theorize.
Never run the guest suite concurrently with `xcodebuild` (timing tests report
`[HANG]` under that load and read exactly like a regression). One documented
flake exists (`time_conformance`, full-suite runs only) — "it's probably the
flake" has to be earned each time, not assumed.

---

## 9. Build gotchas (each has cost real time here)

**Linux CI is a second compiler.** The Linux CI build (`ubuntu-24.04`, clang
*and* gcc matrix) ships to no one — only the Mac build and IPA workflows ship.
It is kept green because GCC with warnings on is the only thing that looks at
code Clang does not (Clang builds every native-program target with `-w`). A
GCC-only diagnostic on vendored/native-program code is a **possible shipping
bug** (the `bash --rcfile` NULL-write crash was caught only by GCC's
`-Wincompatible-pointer-types`), not "GCC being fussy". Clang-only, meson
promotes `-Werror=incompatible-pointer-types` and
`-Werror=pointer-bool-conversion` for the project sources (a positional
initializer in the native registry once made zsh run setuid-root and a
checkpoint call a string literal).

**Never regenerate a vendored `config.h`** (bash's, zsh's, OpenSSH's) to silence
a GCC-only warning. Those were produced by running `configure` on a Mac, so they
assert Darwin facts that are false on glibc. Guard the specific bad site with
`!__linux__` instead, or you'll move what ships on Darwin to fix a platform that
doesn't ship. Related trap: `__thread` must follow the storage class for GCC
(`extern __thread`, not `__thread extern`) — Clang accepts either order.

**`deps/dash` needs a configure step that is never followed by dash's own
make.** The fork commits dash's *generated* sources but not `config.h`.
`cd deps/dash && ../../tools/configure-dash.sh --quiet` before any build —
configure only. Dash's own `make` fails from a clean checkout and can regenerate
`nodes.c` without the `__thread` conversion. `configure-dash.sh` also hard-fails
if `src/mksignames.c` is present (GPL — see licensing).

**`zsh` is a pre-configured tree**: the submodule commits generated sources
(config.h, Src/signames.c, modules) — `git submodule update --init deps/zsh`
is the whole setup; zsh's `make` never runs.

**`hterm_all.js` is a build artifact, not source.** `deps/libapps/hterm/dist/`
is gitignored; the terminal loads that file. It exists because
`xcode-meson.sh` (unsandboxed legacy target) regenerates it via
`python3 bin/mkdist` when missing/stale; the app's "Compile JavaScript" phase
only *asserts its existence* (script sandboxing). A fresh clone has no bundle.

**Rust-on-Xcode is the most trap-dense part.** `native_rust=auto` sees cargo and
enables the crate, then fails on the missing iOS target — CI does
`rustup target add aarch64-apple-ios` explicitly. Cargo is not on PATH under
xcodebuild; meson is told `-Dcargo_home=$HOME/.cargo`. The Rust triple must be
computed per-arch and per-SDK (cargo says `aarch64-apple-ios-sim`, clang wants
`arm64-apple-ios15.0-simulator` — never concatenate triples); the simulator's
`ARCHS = "arm64 x86_64"` means two slices, each its own meson dir and
`-Dnative_rust_target` — an empty target makes cargo build for the **host** and
macOS objects land in an iOS link. `llvm-objcopy` is probed at the Homebrew
keg path, not PATH.

**`-O0` is a different build, not a slow one.** Xcode forces
`buildtype=debugoptimized` in both configurations; an A/B must be real (an
earlier "A/B" was one configuration vs itself because the override was set as a
scheme Environment Variable instead of a build setting — scheme env vars reach
the app at launch, never the script phase). Guest `uname -v` says
` unoptimized` when in effect.

**Stale DerivedData keeps old options.** `MESON_BUILD_DIR` is under
`$(CONFIGURATION_BUILD_DIR)/meson` (one dir per arch); meson caches option
values per build dir, so flipping a default in `meson_options.txt` moves
nothing for an existing tree. `xcode-meson.sh` diffs cross-file +
`meson introspect --buildoptions`, re-wipes/reconfigures, and passes
`-Dnative_bash` / `-Dnative_helix` explicitly every time.

**Toolchain requirements**: `meson`/`ninja` must come from Homebrew (the legacy
targets only search Homebrew's and `/usr/local`'s bin dirs); `lld` must be on
PATH — it is a **separate Homebrew formula from `llvm`** (the i386 vDSO
links with `-fuse-ld=lld`); the Metal toolchain is a
separately downloaded component on Xcode 26+ (`xcodebuild
-downloadComponent MetalToolchain`). `ci_scripts/ci_post_clone.sh` is the
canonical checklist and hard-stops on anything missing.

**`subprojects/MoltenVK` and `subprojects/virglrenderer` are symlinks** into
`deps/` — meson's subproject view; edit the `deps/` copy.

---

## 10. Licensing landmines

- **Native bash is disabled by default** (`native_bash=disabled`, and
  `AOK_NATIVE_BASH=NO` in `app/iSH.xcconfig`) because bash + readline + GNU
  termcap are GPLv3 and cannot ship in an App Store build. `meson` folds them
  into `libish.a` with `link_whole`, so an enabled build **ships** them whether
  or not anything calls them — deleting the registry entry does not remove
  them, only the build option does. zsh (permissive) is the native shell that
  ships instead. If asked to "clean up" or re-enable native bash, read
  `README.md#native-bash-and-licensing` first.
- **`dash`'s `src/mksignames.c` is deliberately never built.** Its *output* is
  GPL-2+ by Debian's own accounting; AOK generates the signal-name table itself
  (and `tools/configure-dash.sh` hard-fails if the file reappears). Don't
  restore it "for convenience".
- **`helix` is MPL-2.0**: file-level copyleft, on by default in the **app**
  build (`AOK_NATIVE_HELIX=YES`), ~45MB. Deliberate, documented decision — see
  `meson_options.txt` and `README.md`.
- **`libgit2` ships (as SmallCLUE's `git`) because it is GPLv2 *with a linking
  exception*** — the reason it can ship where bash cannot.
- GPL source compliance for shipped rootfs images: `docs/root-manifests/`
  (generated by `tools/root-manifest.py`) and `tools/fetch-root-source.py`;
  `docs/gpl-source-offer.md` is the standing offer.

## 11. Security posture

Per `SECURITY.md`: **AOK-iSH is not a security boundary.** It assumes it runs
inside another sandbox (iOS's own) for a single user. Weak permission checks,
memory corruption in edge cases, and thread-safety issues are **ordinary
correctness bugs** — file them as normal GitHub issues (or TODO.md /
future-release-queue entries), not security reports. A genuine security bug
(e.g. RCE without user consent) goes through GitHub Security Advisories.

Separately: the app ships an in-app LLM chat client with an optional
`run_shell` tool (`app/LLMChat*.*`, `opt/AOK/docs/llm-chat.md`). Its
confirm-by-default per-command behaviour (and the "Allow All" opt-out) is
deliberate — preserve it if you touch that feature, don't quietly loosen it.

---

## 12. What CI runs (and what it doesn't)

`ci.yml` (push to `working`/`master`, PRs): Linux build on `ubuntu-24.04`
(clang **and** gcc matrix) plus a Mac build. Needs `libarchive-dev`
`libsqlite3-dev`, smallclue's nested submodules (`third-party/openssh`,
`nextvi`, `libgit2` — plain `submodules: true` stops one level down), dash
configure, and on Mac: `rustup target add aarch64-apple-ios` + hterm mkdist.
It runs `meson test float80 riscv64_decode` and `meson test e2e`, and on Mac an
unsigned Release arm64 app build. It does **not** run the guest regression
suite or the differential harnesses — those need a booted guest and are a
human's job before push/release. A red job that gates nothing (e.g.
`build-ktop.yml`, which cross-compiles ktop with Zig and commits the binaries
back) can stay red unnoticed; if you add a job that commits an artifact, check
its freshness from the artifact side.

Other workflows: `build-release-ipa.yml` (tag `builds/iSH-AOK_*`; runs
`tools/check-all.py` before it will build an IPA), `build-dev-ipa.yml` (push to
`working`; dev prerelease under `dev-latest`, guarded to repo names
ending in `/ish-AOK`), `update-alpine-repo.yml` (daily rclone sync of the in-repo Alpine APK mirror
under `deps/aports`), `deploy-site.yml` (release → Netlify hook),
`autolabel.yml` (issue labelling). `upload-build.yml` is **upstream-only**
(`if: github.repository == 'ish-app/ish'`) — it never runs in this fork. The
dev workflow deletes and recreates the `dev-latest` prerelease on every push
(URL stable, content not).

**Pre-push gate, stated by the project**: guest suite **and** e2e, plus
`java -version` in the Alpine root for anything touching memory or exec — the
JVM hammers threads, maps, and signals harder than anything hand-written, so
it is a whole-system smoke test. The **release** gate is wider: all maintained
roots, on the Mac and on real hardware (`tools/run-guest-gate.sh` is that
harness: every guest architecture, real device, and since 552 a glibc/Devuan
root too — 4 kernel bugs shipped through the musl-only gap before that),
because a 32-bit-only or device-only regression is invisible everywhere else.

## 13. Knobs

Generated inventory of every `ISH_*` env var and meson option:
`book/appendices/appendix-e-knobs.md` (regenerate after adding one). The ones
you'll use:

| Knob | Purpose |
|---|---|
| `-Dlog=strace` (or `verbose`, `instr`) | logging channels; `ISH_LOG` is the same for the app build (`app/iSH.xcconfig`) |
| `ISH_LOCKSTATS`, `ISH_FAKEFS_LOCKSTATS` | lock duty-cycle/wait instrumentation |
| `ISH_PTHREAD_WATCH`, `ISH_PTHREAD_WATCH_SELFTEST` | hardware watchpoints, no debugger (arm64 host) |
| `ISH_HLE`, `ISH_HLE_STATS` | high-level emulation of hot libc routines (arm64/riscv64 guests) + call stats |
| `ISH_MULTICORE` | multi-core guest scheduling |
| `ISH_GUEST_MEM_BUDGET_MB`, `ISH_GUEST_MEM_HEADROOM_MB` | guest memory budget vs iOS jetsam |
| `ISH_BOOT_ROOT=<name>` | boot a named root for one launch (device test legs) |
| `ISH_SESSION`, `ISH_RESTORE` | checkpoint session restore (CLI) |
| `ISH_SOCKRESTART_AFTER` | exercise the freeze/resume socket rebuild from the CLI |
| `ISH_AOK_TEST_SRC`, `ISH_AOK_REGRESS_DIR`, `ISH_AOK_REGRESS_CACHE`, `ISH_AOK_REGRESS_NOCACHE` | guest regression suite overrides |
| `ISH_MINT_HOST`, `ISH_LIMA_INSTANCE`, `ISH_MINT_BINDIR` | `tests/remote/conductor.py` oracles |

## 14. Sideload / IPA and app-identity gotchas

The published IPAs are built unsigned (`CODE_SIGNING_ALLOWED=NO`) and re-signed
by users with AltStore/SideStore/Sideloadly. A re-signer decides what to ask
Apple for by reading the entitlements of the bundle it re-signs:

- **Always run `tools/adhoc-sign-app.sh <path/to/AOK-KSH.app>` before packaging
  an unsigned build.** Without it the bundle has no entitlements blob, the
  re-signer signs with no App Group, iOS grants no shared container, and the
  app falls into its private `AppGroupFallback` — the app works but Files
  integration (File Provider domains, shared folders) is silently off, and a
  fresh install that can't import its bundled root reports **"No filesystem
  storage available"**. The script needs no certificate or keychain; it just
  leaves a readable entitlements blob (expanding the `$(...)` refs Xcode's
  packaging step would have expanded, signing appex bundles first, and failing
  if the app group is not in the result).
- **Verify an IPA before handing it to a user**: entitlements/app-group blob
  present, FileProvider extension present, bundled aarch64 rootfs present.
- A **sideloaded profile does not get** `com.apple.developer.kernel.increased-
  memory-limit` or `extended-virtual-addressing` (both are in
  `app/iSH.entitlements`). The app runs without them at a lower memory ceiling
  — a guest doing heavy work can be killed where a store build survives. Free
  Apple-ID accounts also get 7-day provisioning and a 3-app limit; expiry
  looks like "the app stopped launching" and is normal.
- **There is no custom URL scheme** (`CFBundleURLTypes` is absent from
  `app/Info.plist`): the app cannot be driven from outside. Do not promise
  runtime automation. (It opens URLs *outward*, e.g. a guest's `open`.)
- **ATS trap (documented in `app/Info.plist` itself):** `NSAllowsArbitraryLoads`
  is set, and `NSAllowsLocalNetworking` must **not** be added beside it — any
  iOS 10+ networking key makes the blanket flag ignored. Xcode rewrites the
  plist alphabetically and drops XML comments; the explanation has already been
  lost that way once.
- **App identity** is centralized in `app/iSH.xcconfig`: `ROOT_BUNDLE_IDENTIFIER`
  (`app.ish.aok-ksh`) drives every bundle id, the app group
  (`group.app.ish.aok-ksh`) and the File Provider domain; `DEVELOPMENT_TEAM`
  (`UYU5FM4LQ4`) is upstream's and must change for your own signing. The two
  shipping targets read it as `$(ROOT_BUNDLE_IDENTIFIER)` rather than keeping
  their own copy, and the entitlements files take the group from
  `$(PRODUCT_APP_GROUP_IDENTIFIER)`. The root is deliberately **not** iSH-AOK's
  `app.ish.iSH-AOK`: that is what makes this a separate app with its own
  container that installs beside iSH-AOK, so do not "fix" it back.
- **`MARKETING_VERSION` (the user-visible 1.x) and `CURRENT_PROJECT_VERSION`
  (the build number) are separate**; the routine release bump touches only the
  build number.
- **House rules:**
  - Never `git add -A`: uninitialized submodules stage as deletions. Stage
    explicit paths.
  - **Pushing to `working` in a repo named `ish-AOK` auto-publishes a public
    dev IPA** (`build-dev-ipa.yml`, name-guarded so even forks publish). Check
    the branch and the remote before pushing.
  - Registering a new filesystem: `fs/mount.c` has a fixed
    `MAX_FILESYSTEMS 16` table (12 registered); overflowing it asserts at boot,
    which in the app (stderr nowhere) looks like an unexplained boot crash.
    "Don't run it to the rim."
  - `unfakefsify` is the same binary as `fakefsify` under a second name
    (`tools/meson.build`) — invoked as `unfakefsify` it extracts a fakefs
    image back to a tarball.

## 15. Where to read next

- `docs/llm_onboarding.md` — the committed entry point; this file's canonical twin
- `README.md` — what the fork adds, all build paths, licensing sections
- `docs/TODO.md` — what is known-broken (read before touching anything adjacent)
- `docs/book/README.md` — 42 chapters on how everything works, written from
  this tree's primary sources; key chapters: 6 (threaded-code JIT), 16/17/21
  (VFS/fakefs//AOK), 22-24 (native programs), 34 (two builds), 35 (testing),
  36 (debugging)
- `book/appendices/appendix-f-regression-suite.md` — every regression test and
  why it exists (generated)
- `kernel/task.h` top to bottom — the fields carry comments naming the bug
  that required them
- External (third-party, not in this repo): the `ish-aok` agent skill at
  `github.com/R0GUEEE/iSH-Skills` — IPA sideloading/verification, app
  configuration, and device-deployment procedures with helper scripts. Useful
  for app-side work; its facts predate ppc64 and the 3.24.2 bundle, so verify
  against this tree before relying on any specific number.
