# zsh-reap — Specification

`zsh-reap` is a zsh plugin that automatically tracks long-running foreground
jobs and exposes a CLI (`zsh-reap`) so external tools — primarily Claude Code
and other agentic harnesses — can list, kill, and restart them.

The primary use case: a developer manually starts a test server in a terminal
(`npm run dev`, `cargo run`, `python manage.py runserver`, `mix phx.server`,
…). An agent working in another process needs to bounce that server after
editing code, without having to know how the user started it or which shell it
lives in.

**Design constraint: restarts always happen in the originating shell.** If
that shell has exited, the entry is gone and the agent must ask the user to
re-launch manually. This constraint lets us inherit the shell's live state
(env, history, terminal) for free and drop a substantial amount of metadata,
code, and on-disk secrets exposure. Detach-restart is explicitly out of
scope — not deferred.

This document covers:

1. Plugin scaffolding & installation
2. Tracking mechanism
3. Tracked metadata
4. CLI surface (list, kill, restart, …)
5. Restart-in-original-shell protocol
6. Security model
7. Performance budget
8. Open questions and out-of-scope items

Tradeoffs are called out inline only where the decision is non-obvious.

---

## 1. Plugin scaffolding

### 1.1 Repository layout

```
zsh-reap/
├── zsh-reap.plugin.zsh        # entry script, sourced by every supported manager
├── functions/                 # autoloaded, one function per file (no extension)
│   ├── _reap_preexec
│   ├── _reap_precmd
│   ├── _reap_zshexit
│   ├── _reap_trapusr1
│   └── _reap_watcher
├── bin/
│   └── zsh-reap               # the external CLI (zsh script)
├── spec/SPEC.md
└── README.md
```

Rationale: `<name>.plugin.zsh` at the repo root is the single filename every
relevant plugin manager (oh-my-zsh, sheldon, antidote, zgen/zgenom, znap)
agrees to source. `functions/` and `bin/` follow the Zsh Plugin Standard so
managers that honor the `f` / `b` capability bits do the right thing
automatically, and the entry script falls back to adding them manually for
managers that don't.

### 1.2 Entry script (`zsh-reap.plugin.zsh`)

Skeleton, following the Zsh Plugin Standard:

```zsh
# Resolve own path, robust to FUNCTION_ARGZERO / POSIX_ARGZERO / eval-sourcing.
0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"

typeset -gA REAP
REAP[DIR]="${0:h}"
REAP[STATE_DIR]="${ZSH_REAP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zsh-reap}"
REAP[THRESHOLD]="${ZSH_REAP_THRESHOLD:-5}"   # seconds

# fpath + PATH fallbacks for managers that don't honor PMSPEC bits
[[ $PMSPEC != *f* ]] && fpath+=( "${0:h}/functions" )
[[ $PMSPEC != *b* ]] && path+=( "${0:h}/bin" )

autoload -Uz add-zsh-hook
autoload -Uz _reap_preexec _reap_precmd _reap_zshexit \
             _reap_trapusr1 _reap_watcher

# Only run in interactive top-level shells
[[ -o interactive ]] || return 0
(( ZSH_SUBSHELL == 0 )) || return 0

mkdir -p "${REAP[STATE_DIR]}/jobs"
chmod 0700 "${REAP[STATE_DIR]}"

add-zsh-hook preexec _reap_preexec
add-zsh-hook precmd  _reap_precmd
add-zsh-hook zshexit _reap_zshexit

TRAPUSR1() { _reap_trapusr1 }
```

### 1.3 Installation snippets (for README)

| Manager     | Install line                                                                                 |
|-------------|----------------------------------------------------------------------------------------------|
| zgenom      | `zgenom load gauravmm/zsh-reap`                                                              |
| zgen        | `zgen load gauravmm/zsh-reap`                                                                |
| antidote    | `gauravmm/zsh-reap` in `~/.zsh_plugins.txt`                                                  |
| sheldon     | `[plugins.zsh-reap] github = "gauravmm/zsh-reap"`                                            |
| oh-my-zsh   | `git clone … ${ZSH_CUSTOM}/plugins/zsh-reap` + add `zsh-reap` to `plugins=(…)`               |
| znap        | `znap source gauravmm/zsh-reap`                                                              |
| manual      | `source /path/to/zsh-reap.plugin.zsh`                                                        |

---

## 2. Tracking mechanism

### 2.1 The core problem

We want to record metadata about foreground commands that **are still
running** and have exceeded a duration threshold. Zsh's `preexec`/`precmd`
hooks bracket a command:

- `preexec` runs *before* the child is forked — we don't yet know the child
  PID, and the duration is zero.
- `precmd` runs *after* the child has exited — we know the duration, but the
  process is gone, so there's nothing to restart.

Neither hook fires *during* a foreground command. So we need a third actor: a
short-lived background watcher that decides, after the threshold elapses,
whether the command is still running and should be registered.

### 2.2 Lifecycle

```
preexec ──► spawn detached watcher ──► (sleep T) ──► is shell still in this command?
                                                       │
                                                       ├── yes → write entry to registry
                                                       └── no  → exit silently

…command runs…

precmd ──► remove any registry entry for this shell (job finished or was killed)
```

`preexec` spawns the watcher detached, handing everything it knows as
arguments (and the raw command string via stdin to dodge shell-quoting on
multi-line input):

```zsh
_reap_preexec() {
  emulate -L zsh
  ( _reap_watcher "$$" "$HISTCMD" "$EPOCHSECONDS" "$PWD" <<<"$1" & ) &!
}
```

The double-fork (`( … & ) &!`) detaches the watcher from the shell's job
table so it isn't reported by `jobs` and doesn't print "[1] done" when it
exits. No on-disk candidate file is needed.

### 2.3 The watcher

The watcher receives `(shell_pid, histcmd, start_epoch, cwd)` as arguments
and the command string on stdin. It:

1. Sleeps `REAP[THRESHOLD]` seconds (default 5).
2. Reads the parent shell's controlling-tty foreground process group:

   ```
   tpgid=$(ps -o tpgid= -p "$shell_pid")
   ```

3. Compares to the shell's own pgid (computed once via `ps -o pgid= -p
   $shell_pid`). If equal, the shell is at its prompt (no foreground
   command) and the watcher exits.
4. Otherwise: lists processes in that pgrp via `pgrep -g "$tpgid"` and
   treats the youngest one with `PPID == shell_pid` as `child_pid`. (For
   pipelines, all children share `tpgid`; we record the pgid as the
   primary identifier and the first child as `child_pid`.)
5. Writes the entry to `$STATE/jobs/$(printf '%x-%x' $shell_pid $histcmd)`.

### 2.4 Why this approach

**Tradeoff: background watcher vs. ptrace/pty interception.** A more
accurate but heavier alternative would be to run a sidecar daemon that
attaches to the user's tty and observes process events directly (e.g. via a
pty proxy or `dtrace` on macOS). That would catch detaching daemons and
correctly attribute multi-stage launches, but requires elevated privileges
and platform-specific code. The watcher approach is best-effort and pure
shell + `ps`/`pgrep`; it works on macOS and Linux without any extra
dependencies.

**Tradeoff: choosing the threshold.** Lower thresholds capture more jobs but
register short-lived commands the user doesn't care about (`make build`,
`npm test`). Higher thresholds miss servers that the user wants to restart
*before* they're fully ready. Default 5s; configurable via
`ZSH_REAP_THRESHOLD`.

### 2.5 Edge cases

- **Pipelines (`cmd1 | cmd2`)**: register the pgid; restart re-executes the
  whole pipeline string (we keep `$1` from preexec, which is the literal
  pipeline as typed).
- **Backgrounded jobs (`&`)**: explicitly out of scope per design. `&` jobs
  don't block preexec→precmd the same way and tend to be user-managed via
  `jobs`/`fg`.
- **Daemonizing commands** (`cmd` that forks and exits): the registered
  `child_pid` will be dead within seconds, but a daemon may still be running
  under a different PID. Lazy GC will mark the entry dead; restart will
  re-run the original command. This is the correct semantic: restart what
  the user typed.
- **Subshells / non-interactive shells**: the plugin no-ops via the
  `interactive` + `ZSH_SUBSHELL == 0` guard in §1.2.
- **`exec` replacing the shell**: the shell PID survives, the watcher fires
  against the new program. The new program's tpgid will normally equal its
  own pgid, indistinguishable from "at prompt"; we accept this as a known
  miss.

---

## 3. Tracked metadata

### 3.1 Registry storage

One file per tracked job, under `${REAP[STATE_DIR]}/jobs/`. Filename is the
`entry_id` (see below). Format is one `key=value` per line, values
URL-encoded if they contain `\n` or `=`. Plain text, shell-parseable, no
external dependencies (no `jq`, no JSON anywhere in the project).

**Tradeoff: one file per job vs. a single registry file.** One file per
job means zero locking — concurrent shells never write to the same path.
The CLI reads via `for f in $STATE/jobs/*; do …`. A single registry would
require advisory locking (`flock` is non-portable on macOS pre-Sequoia) or
careful atomic-rename gymnastics. File-per-job is the right call.

### 3.2 Fields

| Field         | Source                            | Notes                                                     |
|---------------|-----------------------------------|-----------------------------------------------------------|
| `entry_id`    | `printf '%x-%x' $$ $HISTCMD`      | Filename and CLI handle. Unique by construction.          |
| `shell_pid`   | `$$`                              | The zsh process the user typed into; receives `SIGUSR1`.  |
| `shell_tty`   | `$TTY`                            | e.g. `/dev/ttys003`. Cosmetic, for `list` output.         |
| `child_pid`   | watcher: `pgrep -g <tpgid>` head  | The foreground child; for pipelines, the first stage.     |
| `child_pgid`  | tpgid at capture                  | The foreground process group; used by `kill -PGID`.       |
| `command`     | preexec `$1`                      | Raw command string as typed (incl. pipelines, redirects). |
| `cwd`         | `$PWD` at preexec                 | Restart `cd`s here before re-execing.                     |
| `start_epoch` | `$EPOCHSECONDS` at preexec        | Unix time in seconds. Used for uptime display.            |

That's the entire persistent schema. No env snapshot, no hostname, no
host_boot_id, no threshold, no explicit state field — an entry's mere
presence in `$STATE/jobs/` means "alive"; lazy GC removes the file when the
shell or child dies. `shell_pgid` is computed transiently in the watcher to
detect "shell at prompt" and not persisted.

The `entry_id` doubles as the filename: `$STATE/jobs/<entry_id>`. Hex
encoding of `($$, $HISTCMD)` is unique by construction (HISTCMD is
monotonic per shell) and stays compact — typical IDs are 6–8 characters
(e.g. `1319a-8e`).

**Why so little.** The same-shell restart guarantee (§1) means the
`TRAPUSR1` handler runs inside the original zsh process and inherits its
live environment. Anything the shell already knows about itself
(`$PATH`, `$NODE_ENV`, `$VIRTUAL_ENV`, …) does not need to be on disk. PID
liveness is verified by `kill -0` at query time, which also catches
across-reboot staleness because the post-reboot PID either doesn't exist
or belongs to an unrelated process whose owner check fails.

### 3.3 What we deliberately don't track

- **Environment variables.** Inherited from the live shell at restart. If
  the user `export`s a variable mid-session, the restart picks up the new
  value — which is usually what they want.
- **Stdout/stderr of the running job.** Out of scope; users who want this
  run under `tmux`/`script`.
- **File descriptors, open sockets, child trees beyond `child_pid`.** The
  contract is "restart re-runs the command string"; reconstructing more
  is beyond what we can promise.
- **History of past runs.** Once a job exits, its registry entry is
  removed. The user's shell history already keeps the command line.

---

## 4. CLI interface (`zsh-reap`)

The CLI is a zsh script under `bin/zsh-reap`. It emits TSV (one entry per
line, tab-separated columns) for `list` and plain text status for
everything else — easy for both humans and agents to parse.

### 4.1 `zsh-reap list`

```
$ zsh-reap list
ID         PID     SHELL   CWD                          UPTIME   COMMAND
1319a-8e   78234   ttys003 ~/work/myapp                 0:14:22  npm run dev
138f0-1f   80112   ttys005 ~/work/myapp/api             0:02:11  cargo run --release
```

No flags. Filter with `grep`/`awk` if needed.

Lazy GC runs here: each entry's `child_pid` and `shell_pid` are checked
with `kill -0`. If either is dead, the entry file is removed. Reboots are
handled implicitly — post-reboot the PIDs either don't exist or belong to
unrelated processes whose ownership / `pgid` cross-check fails.

### 4.2 `zsh-reap show <id>`

Dumps the entry file. Implemented as literally `cat $STATE/jobs/<id>`. The
on-disk format (one `key=value` per line, see §3) is the stable interface
— `show` exists so users don't need to know the path.

### 4.3 `zsh-reap kill <id>`

Sends `SIGTERM` to `child_pgid` (the foreground process group), waits up
to 5s, then escalates to `SIGKILL` if still alive. The shell's `precmd`
removes the entry naturally afterward.

### 4.4 `zsh-reap restart <id>`

The headline feature.

1. Read entry. If `shell_pid` is dead (`kill -0` fails): remove the entry
   and error out — the originating shell is gone, no fallback.
2. Send `SIGUSR1` to `shell_pid` (not the pgrp — that would also hit the
   child).
3. Return. The original shell's `TRAPUSR1` does the rest (§5.1).

Flags:

- `--wait` → block until the entry's `child_pid` field has been updated
  by the watcher (i.e., the new child has been registered), with a
  timeout. Lets agents observe restart completion before running tests.

### 4.5 `zsh-reap forget <id>`

Removes a registry entry without killing anything. For when the user
no longer wants the agent to see/restart a particular server.

---

## 5. Restart-in-original-shell protocol

### 5.1 Alive-shell path (`SIGUSR1` trap)

Sequence:

```
[CLI side]
kill -USR1 <shell_pid>
    │
    ▼
[Shell side: TRAPUSR1]
USR1 interrupts wait() in zwaitjob; trap fires
glob $STATE/jobs/$(printf '%x' $$)-*    # exactly one match — the fg job
source entry                            # → cmd, cwd, child_pgid
rm entry
kill -TERM -<child_pgid>
cd $cwd
_reap_preexec "$cmd"                    # respawn watcher
eval $cmd                               # new fg child; trap blocks here
    │
    ▼
(when the new child eventually exits, trap returns; zsh's main loop sees
the original wait() came back, precmd removes the entry the watcher wrote
for the new run)
```

A few things make this work cleanly:

- **The trap finds its own job by glob.** Filenames start with
  `printf '%x' $$`, and a given shell has at most one foreground job at
  any moment, so the glob matches exactly one entry. No pending file
  needed.
- **The trap runs while `zwaitjob` is still blocked.** Per the zsh
  source, signal traps fire at safe points inside `zwaitjob`'s
  `sigsuspend` — the trap can run before the original child is reaped.
  Sending `SIGUSR1` first and letting the trap send `SIGTERM` to the
  child makes the trap the single agent of change; no races.
- **`eval $cmd` re-blocks the shell on the new child.** Function traps
  run in their own scope but execute commands in the parent shell's
  context, so the new foreground child becomes the shell's new job,
  exactly as if the user had retyped the line.
- **Auto-execute is the default and only behavior.** The whole point of
  this plugin is that an agent can restart without touching the user's
  terminal. A "stage the command in the line buffer for the user to
  approve" path defeats that. The same-UID argument applies: anyone who
  can `kill -USR1` your shell could already `kill <shell>; nohup bad-cmd
  &` you, so accepting USR1 as "run this previously-tracked command"
  doesn't widen the privilege boundary.

**Tradeoff: TRAPUSR1 vs. polling a file.** An alternative to signals is
to have a `precmd` hook that checks for a pending-restart file every
prompt. That works only when the shell is *at* a prompt — exactly the
case we don't care about (when there's no job to restart). It also costs
a `stat` on every prompt. Signals are the right primitive here.

### 5.2 What happens when the shell is gone

If the originating shell has exited, the `zshexit` hook removes the entry,
so `list` won't show it and `restart` will fail. The user must re-launch
manually. Detach mode is explicitly out of scope (see §1).

If the shell crashes (no `zshexit` hook fires), lazy GC catches it on the
next `list`/`restart` invocation by `kill -0`-ing `shell_pid`.

### 5.3 Auth: who can signal the shell?

`SIGUSR1` requires same-UID. Anyone who can already signal the user's
shell can already `exec` arbitrary code as that user, so we don't widen
the privilege boundary by accepting USR1. Detail in §6.

---

## 6. Security

### 6.1 Threat model

The user is the only principal. We assume same-host, same-UID processes
are equally trusted (because they are: any same-UID process can
`ptrace` the shell, write to its files, etc.). The threats we *do* care
about:

1. **Disk-resident leaks**: registry files persist until the shell exits
   or is GC'd. They are mode `0600` in a `0700` dir under
   `$XDG_STATE_HOME`. The same-shell-only restart design means we don't
   write env vars to disk at all — the trap reads them live from the
   originating shell.
2. **Secrets in command strings — explicitly out of scope.** The raw
   `command` field is the literal line the user typed; if they typed
   `curl -H "Authorization: Bearer xxx"`, that token lands in
   `$STATE/jobs/<id>` in plaintext. We do not try to detect or redact
   this. The rationale:

   - Putting secrets on a command line is already an antipattern.
     They leak via `ps` / `/proc/<pid>/cmdline` (visible to every
     same-UID process), shell history, process accounting, CI logs,
     crash dumps, and anything that wraps the command (`time`,
     `nohup`, tmux scrollback, the user's editor terminal). Tools that
     accept secrets (mysql, curl, git, docker, the cloud CLIs) all
     document file- or env- or stdin-based alternatives for exactly
     this reason.
   - A pattern-matching redactor (`*token*`, `*secret*`, …) is a
     heuristic that gives users false confidence — it will miss
     `--header "X-Custom-Auth: …"`, `--data '{"key": "…"}'`, and
     anything with a project-specific name.
   - Our on-disk exposure is no worse than `~/.zsh_history`, which
     captures the same line under the same `0600` permissions. If a
     user is comfortable with their shell history's threat model, ours
     is equivalent.

   The README will spell this out and point at the standard
   alternatives (env files, secret managers, stdin). Users who need
   stronger guarantees should not put secrets on the command line in
   the first place.
3. **Registry-entry injection**: the `TRAPUSR1` handler reads an entry
   from `$STATE/jobs/` and `eval`s its `command` field. If a same-UID
   process could write a hostile entry whose filename matches
   `printf '%x' $$`-prefix, the shell would obey on the next
   `SIGUSR1`. The only mitigation is `$STATE` being mode `0700`, which
   is enforced at plugin init. Same-UID attackers can already `eval` in
   the shell directly (§6.2), so this is not an escalation.
4. **CLI as setuid**: the CLI must never be installed setuid. We
   document this and refuse to run as root unless `ZSH_REAP_ALLOW_ROOT=1`
   is set (which we don't recommend).

### 6.2 What we explicitly do not protect against

- A same-UID attacker who can already `eval` in the user's shell. There's
  no defending against that.
- Multi-user systems sharing a state dir over NFS. Use a per-user
  `$XDG_STATE_HOME` (the default).
- TOCTOU between the watcher reading `tpgid` and writing the entry. The
  worst case is a slightly stale `child_pid`, which lazy GC catches.

---

## 7. Performance

### 7.1 Hot path: `preexec`

Per-command overhead is exactly one double-fork for the watcher. No file
I/O. Target: < 2ms on a modern Mac. The double-fork dominates; if it
becomes a problem, the fallback is a single persistent watcher per shell
fed via a fifo (more complex, deferred unless needed).

### 7.2 Hot path: `precmd`

One `rm -f` of the registry entry (a no-op if the watcher never promoted
it because the command exited under the threshold). Target: < 1ms.

### 7.3 Watcher

- `sleep $THRESHOLD` (cost: zero CPU, one process slot).
- After sleep: 2 `ps`/`pgrep` invocations and a write.
- Lifetime is bounded by `THRESHOLD + ε`; total CPU per command is
  negligible.

### 7.4 CLI

- `list`: opens every file under `$STATE/jobs/`. With ~10 tracked jobs at
  any time, latency is dominated by `kill -0` syscalls; well under 50ms.
- `restart`: two file writes and one signal. Sub-millisecond.

### 7.5 Disk footprint

- Each entry is ~1KB. With 100 stale entries the registry is 100KB. GC
  prunes aggressively, so steady state is "however many jobs you have
  running right now."

---

## 8. Open questions / out of scope

These need decisions before implementation, or are explicitly deferred:

- **Multi-process pipelines**: we record the pipeline string and restart
  it as one. If a pipeline has multiple long-running stages and the user
  wants to kill only one, they can't. Documented limitation.

---

## 9. v1 acceptance checklist

The plugin is "done" for v1 when:

- [ ] Installs cleanly under zgenom and oh-my-zsh.
- [ ] `npm run dev` started in one terminal appears in `zsh-reap list`
      from another terminal within ~`THRESHOLD + 1` seconds.
- [ ] `zsh-reap restart <id>` from a second terminal kills the running
      server and re-executes the same command in the original shell,
      on macOS and Linux, with no user interaction.
- [ ] Closing the original terminal removes its entries from the
      registry on `zshexit`; lazy GC catches the crash case.
- [ ] No registry entries persist across a reboot (validated via lazy GC).
- [ ] No environment variables appear in any registry file.
- [ ] `zsh-reap list` over a 100-entry registry completes in < 100ms.
