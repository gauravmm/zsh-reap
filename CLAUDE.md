# zsh-reap — Claude context

A zsh plugin + CLI that tracks long-running foreground jobs so external
tools (agents, scripts) can list/kill/restart them. The complete design
is in [`spec/SPEC.md`](spec/SPEC.md) — treat that as the source of truth.

## Layout

- `zsh-reap.plugin.zsh` — entry script. Sets up the `REAP` hash,
  registers preexec/precmd/zshexit hooks. No `TRAPUSR1` (see spec §5.1).
- `functions/_reap_*` — autoloaded function files (one function per
  file, no extension, per the Zsh Plugin Standard).
- `bin/zsh-reap` — the external CLI (executable zsh script).
- `spec/SPEC.md` — design doc; the source of truth.

## How the pieces interact

```
preexec    → spawns detached watcher (double-fork, no I/O)
watcher    → sleeps THRESHOLD seconds, then writes $STATE/jobs/<id>
             if the shell is still in a foreground command
precmd     → if $STATE/pending/$$ exists, consume it: cd, _reap_preexec,
             eval the staged command (loops in case more arrive); then
             rm -f $STATE/jobs/<this-shell>-*  (harmless if absent)
zshexit    → cleans both jobs/<this-shell>-* and pending/$$
CLI restart → writes $STATE/pending/<shell_pid> with cmd+cwd, then
             kills the foreground child (TERM → 5s poll → KILL). The
             kill is what wakes the shell's wait() so precmd can run.
```

## Conventions (please respect)

- **No external dependencies** beyond zsh, `ps`, `pgrep`, `kill`, `cat`,
  `mv`, `rm`, `sleep`, and `mkdir`. No `jq`, no Python, no `awk` even.
- **No JSON anywhere.** The on-disk format is `key=value` per line with
  `printf '%q'`-quoted string values. The CLI emits TSV from `list`.
- **`emulate -L zsh` at the top of every function.** Sets
  `LOCAL_OPTIONS`, so options changed inside the function are restored
  on return. Avoids surprises from `KSH_ARRAYS`, `SH_WORD_SPLIT`, etc.
- **String values must be `printf '%q'`-quoted on write.** Otherwise
  values like `??` (a glob) blow up at `eval` time on read. Currently
  applies to `command`, `cwd`, `shell_tty`.
- **State dir is `${XDG_STATE_HOME:-$HOME/.local/state}/zsh-reap`,
  mode 0700.** Files under it are mode 0600. Never widen.
- **The Plugin Standard `$0` idiom is load-bearing**, see the top of
  `zsh-reap.plugin.zsh`. Don't simplify to `${0:A:h}` — that breaks
  under `FUNCTION_ARGZERO` / eval-sourcing.
- **PMSPEC is unreliable.** The user may have a stale value from an
  old plugin manager. We defensively check whether `fpath` / `path`
  already contain our dirs rather than trusting PMSPEC's bits.

## Things explicitly out of scope (don't add them back)

These are decisions, not deferrals — see SPEC.md §1, §3.3, §8.

- Detach-restart (re-launching jobs whose originating shell has exited).
- Env-var snapshotting. The trap inherits the live shell's env.
- Secret redaction in command strings. The README points users at env
  files / secret managers / stdin instead.
- `--json` output, `--cwd`/`--tty` filters, `--signal` flags. Pick the
  sensible default and ship.
- Backgrounded-jobs (`cmd &`) tracking. Foreground only.
- Frontends, history logs, bash/fish ports.

## Testing locally

End-to-end interactive testing is best done by hand in a real terminal:

```
ZSH_REAP_STATE_DIR=/tmp/reap-dev source ./zsh-reap.plugin.zsh
sleep 30      # in one terminal
ZSH_REAP_STATE_DIR=/tmp/reap-dev ./bin/zsh-reap list   # in another
ZSH_REAP_STATE_DIR=/tmp/reap-dev ./bin/zsh-reap restart <id>
```

Syntax-check all files at once:

```
for f in zsh-reap.plugin.zsh functions/_reap_* bin/zsh-reap; do
  zsh -n "$f" && echo "ok: $f"
done
```

The hooks rely on a real TTY (the watcher reads `ps -o tpgid=` to detect
"shell at prompt"), so tests inside `bash -c` / Claude's Bash tool won't
exercise the full path. CLI subcommands (`list`, `show`, `forget`, `kill`,
`gc`-via-list) can be exercised with hand-crafted entry files.

## When making changes

- Read `spec/SPEC.md` first. It's tight and current.
- If a change feels like it needs a new env var or a new flag, it's
  probably out of scope per §3.3/§8. Push back before adding.
- For changes to the on-disk format, update the schema table in §3.2
  and the field list in `_reap_watcher`.
- For changes to the restart protocol, update §5.1 (including the
  vertical diagram), `_reap_precmd`'s pending-loop, and the CLI's
  `cmd_restart`.
- A `ZSH_REAP_DEBUG=1` env var (set in the user's interactive shell)
  appends timestamped lines to `$STATE/debug.log` from `_reap_precmd`.
  Useful for diagnosing restart-timing issues; cheap when unset.
