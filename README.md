# zsh-reap

A zsh plugin that tracks long-running foreground jobs and exposes a CLI so
external tools — primarily Claude Code and other agentic harnesses — can
list, kill, and restart them.

## The problem

You start a test server in a terminal:

```
$ npm run dev
```

An agent (Claude Code, an editor extension, …) edits your code in a
different process and needs to bounce that server. Without zsh-reap, it
has to ask you to do it. With zsh-reap, the agent runs:

```
$ zsh-reap list
ID         PID     SHELL   CWD                  UPTIME   COMMAND
1319a-8e   78234   ttys003 ~/work/myapp         0:14:22  npm run dev

$ zsh-reap restart 1319a-8e
```

…and the originating shell kills its current foreground job and
re-executes it. No user interaction required.

## Install

| Manager     | Add to your config                                                            |
|-------------|-------------------------------------------------------------------------------|
| zgenom      | `zgenom load gauravmm/zsh-reap`                                               |
| zgen        | `zgen load gauravmm/zsh-reap`                                                 |
| antidote    | `gauravmm/zsh-reap` in `~/.zsh_plugins.txt`                                   |
| sheldon     | `[plugins.zsh-reap]` + `github = "gauravmm/zsh-reap"`                         |
| oh-my-zsh   | clone to `$ZSH_CUSTOM/plugins/zsh-reap`, then add `zsh-reap` to `plugins=()`  |
| znap        | `znap source gauravmm/zsh-reap`                                               |
| manual      | `source /path/to/zsh-reap.plugin.zsh` in your `.zshrc`                        |

The CLI `zsh-reap` is added to your `$PATH` by the plugin. The state dir
defaults to `${XDG_STATE_HOME:-~/.local/state}/zsh-reap`.

## Use

```
zsh-reap list                   # TSV of currently-tracked jobs
zsh-reap show <id>              # full metadata for one entry
zsh-reap kill <id>              # SIGTERM, escalating to SIGKILL after 5s
zsh-reap restart <id>           # signal the originating shell to restart
zsh-reap restart <id> --wait    # block until the new run is registered
zsh-reap forget <id>            # remove the entry without killing
```

An entry appears once a foreground command has been running for longer
than `$ZSH_REAP_THRESHOLD` seconds (default 5). The watcher that decides
this runs in the background; the hot path in your prompt is one
double-fork.

## How it works (one paragraph)

A `preexec` hook spawns a detached watcher with the command, cwd, and
`$HISTCMD`. The watcher sleeps `$ZSH_REAP_THRESHOLD` seconds, then checks
your shell's controlling-tty foreground process group. If the shell is
still blocked on a foreground job, the watcher records an entry under
`$XDG_STATE_HOME/zsh-reap/jobs/<id>`. When you (or an agent) run
`zsh-reap restart <id>`, the CLI stages the command in
`$XDG_STATE_HOME/zsh-reap/pending/<shell_pid>` and kills the
foreground job; the kill wakes your shell's `wait()`, your shell's
`precmd` notices the pending file, and `eval`s the recorded command
in-place.

The full design — including why some obvious-looking alternatives
(`print -z`, `TRAPUSR1`, env snapshots, detach-restart) are explicitly
out of scope or were tried and abandoned — is in [`spec/SPEC.md`](spec/SPEC.md).

## Configuration

| Env var               | Default                              | Effect                               |
|-----------------------|--------------------------------------|--------------------------------------|
| `ZSH_REAP_THRESHOLD`  | `5`                                  | Seconds before a fg command is tracked. |
| `ZSH_REAP_STATE_DIR`  | `$XDG_STATE_HOME/zsh-reap`           | Where entries live.                  |

## Caveats and limitations

- **Restart requires the originating shell.** If you close the terminal
  that started a server, the entry is removed and you'll have to
  re-launch manually. Detach mode is explicitly out of scope (see
  `spec/SPEC.md` §1).
- **Backgrounded jobs (`cmd &`) are not tracked.** Only foreground
  commands.
- **Secrets in command lines land on disk.** The `command` field is the
  literal line you typed and is stored under `$XDG_STATE_HOME/zsh-reap`
  with the same `0600` permissions as your shell history. zsh-reap
  does not redact — putting secrets in command lines is already an
  antipattern (`ps`, `~/.zsh_history`, CI logs, …); use env files,
  secret managers, or stdin instead.
- **Daemonizing commands**: if your command forks-and-exits (the
  classic Unix daemon pattern), zsh-reap loses track of the daemon
  PID. `restart` will still work — it re-runs the command string —
  but `kill` and `list` will reflect the dead foreground PID.

## License

MIT.
