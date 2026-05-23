---
name: zsh-reap
description: Find, kill, or restart long-running foreground commands the user already started in another terminal (dev servers, file watchers, REPLs running for more than a few seconds). Reach for this before asking the user to manually Ctrl-C and re-run something, and before trying to wrap their running server in your own Bash tool call.
---

# zsh-reap

`zsh-reap` is a small zsh plugin + CLI that registers any foreground command running in the user's interactive shell once it has been running for at least `$ZSH_REAP_THRESHOLD` seconds (default 5). From your `Bash` tool you can inspect those jobs and bounce them in the originating shell without asking the user.

Repo and full spec: https://github.com/gauravmm/zsh-reap

## When to use this

- The user references a long-running process they have open ("my dev server", "the watcher", "the REPL") and you need to restart it after editing.
- You made a change that requires a restart of a process the user is already running.
- The user asks you to kill or check on something running in another terminal.

## When NOT to use this

- For a brand-new command you'd be running for the first time — just use `Bash` directly. `zsh-reap` only knows about commands the user already started.
- For background jobs (`cmd &`). Only foreground commands are tracked.
- For commands you launched yourself via your `Bash` tool. The plugin's hooks only run in the user's _interactive_ shells; your `Bash` tool spawns a non-interactive subshell, so anything you start there is invisible to `zsh-reap`. **You can `restart` or `kill` entries the user created; you cannot create new ones.**

## Detect

```sh
command -v zsh-reap >/dev/null && zsh-reap list
```

- Binary missing: the plugin isn't installed. Point the user at https://github.com/gauravmm/zsh-reap. Don't try to install it for them silently — installation involves editing their shell init, which they should do or approve themselves.
- Binary present, `list` empty: the user has nothing tracked right now. Either nothing has crossed the threshold yet, or the plugin isn't loaded in the shell they're running things in. Ask before assuming.

## Commands

| Command                        | What it does                                                             |
| ------------------------------ | ------------------------------------------------------------------------ |
| `zsh-reap list`                | TSV: `ID`, `PID`, `SHELL`, `CWD`, `UPTIME`, `COMMAND`                    |
| `zsh-reap show <id>`           | Full key/value entry for one job                                         |
| `zsh-reap restart <id>`        | Kill the fg child and re-run in the original shell (returns immediately) |
| `zsh-reap restart <id> --wait` | Same, but block until the new run is registered (~ threshold + 1s)       |
| `zsh-reap kill <id>`           | TERM → KILL after 5s. Does not restart.                                  |
| `zsh-reap forget <id>`         | Drop the entry without killing the process.                              |

Use `--wait` when the next thing you'll do depends on the server being back up (running tests, hitting a health endpoint, etc.).

## Typical workflow

```sh
# Identify what's running
zsh-reap list

# Pick the entry whose CWD/COMMAND matches the work, restart it, wait for the new run
zsh-reap restart 1319a-8e --wait

# Then run whatever you needed the fresh server for
curl -fsS localhost:3000/health
```

## Behaviour to know

- **Restart re-runs the exact command string** the user typed, in the original shell, with that shell's _current_ environment. It is not a re-exec of the prior process; if the user `export`ed something since starting the command, the restart picks up the new value.
- **If the original shell exited, the entry is gone.** There is no detach mode — tell the user to relaunch manually.
- **Pipelines restart as one unit** (the whole pipeline string is re-evaluated).
- **Daemonizing commands** (fork-and-exit): `restart` still re-runs the command string, but the registered `PID` will be of the short-lived foreground process, not the daemon.
- **Secrets in command strings** land on disk under `$XDG_STATE_HOME/zsh-reap/` at mode 0600. Same exposure as `~/.zsh_history`. If the user has secrets in a command line, flag it but don't refuse to operate.
