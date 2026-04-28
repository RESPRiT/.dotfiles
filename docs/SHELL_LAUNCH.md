---
tracks:
  - bashrc
  - zshrc
  - shellrc
  - hooks/post-merge
  - install.sh
  - ~/.ssh/config
---

# Shell launch

`bashrc`/`zshrc` invoke `_repo_auto_update` (defined in `shellrc`) at startup when `DOTFILES_AUTO_UPDATE=1` and/or `DOCS_AUTO_UPDATE=1` is set in local rc. The function forks the entire fetch+pull+`post-merge` pipeline into a detached background subshell and returns immediately, so shell startup is unblocked (~10ms regardless of network state). The fetch itself is wrapped in a 5s wall-clock cap via `timeout`/`gtimeout`/`perl`'s alarm-then-exec trick (the SIGALRM timer survives `exec` on macOS and Linux), so a flaky network can't pile up zombie processes.

The detach uses the double-subshell idiom — `( ( cmd ) & )` rather than `( cmd ) & disown` — so the interactive shell never sees a backgrounded job and zsh skips the `[N] PID` job-control announcement.

If the background fetch finds upstream commits, it captures one headline line (`[label] Updated from remote (N commits)`) plus one line per migration that ran (`[migration] NAME ✓` or `✗`, emitted by `hooks/post-merge`) into `.state/notice-<label>` via a tmp-then-mv atomic write. `git pull` runs with `--quiet` so its own progress doesn't leak into the notice; per-migration stdout/stderr is appended to `.state/migrations.log` instead, keeping the notice terse while preserving a full transcript for debugging. A `_repo_show_notices` precmd hook (zsh) / `PROMPT_COMMAND` function (bash), also defined in `shellrc`, prints and clears those notice files on the next prompt redraw. If nothing was pulled, no notice is written and the user sees nothing.

This is the third iteration of this code:

- **Always-async with a sentinel-file headline** (pre-`0e7c0cc`): forked fetch+pull, success message in `$repo/.update-msg`, precmd hook displayed it. Lost migration output because only the headline was captured; failures went to `2>/dev/null`.
- **Always-sync** (`0e7c0cc`): everything ran inline. Migration output was visible but the user paid a full network fetch on every shell launch.
- **Always-async with a full-transcript notice + precmd hook** (current): keeps startup at ~10ms and recovers the migration-visibility property by capturing the whole pull+`post-merge` transcript into the notice file.

Concurrent shells racing on the same repo can collide on git's index lock (the loser's `git pull` errors out). The error lands in the loser's notice file; the user sees both notices on the next prompt. Repo data is safe in either case. A `mkdir`-based mutex would prevent the collision, but two shells launched within ~500ms of each other isn't common enough to justify the extra moving part.

## SSH connection multiplexing (per-machine)

`install.sh` prompts for this when at least one auto-update is enabled, and writes the block below to `~/.ssh/config`:

```
Host github.com
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%C
  ControlPersist 10m
```

(Plus `mkdir -p ~/.ssh/sockets && chmod 700 ~/.ssh/sockets`.) Decline once and the decision is recorded in `.state/decisions` so re-runs don't re-prompt; manually adding any `ControlMaster` line to `~/.ssh/config` also satisfies the check.

The first ssh-based git op of a session opens a control socket and stays in the background; subsequent ops to the same `(user, host, port)` skip the handshake entirely. Observed on this machine: cold fetch ~1.27s (creates master), warm fetch ~0.51s (reuses master). With the always-async design, multiplexing doesn't change shell startup latency (~10ms either way), but it cuts the *background* fetch's wall-clock from ~1.5s to ~0.5s — so notices land on the user's next prompt that much sooner.

This config is **not** committed to the dotfiles repo:

- `~/.ssh/config` already carries per-host identity routing that varies between machines.
- macOS and Linux OpenSSH support `ControlMaster`; Windows OpenSSH historically didn't, so a shared config would silently no-op there.
- The control socket grants any local process running as the same user the ability to use the multiplexed connection without re-auth. Fine on a single-user laptop, debatable on a shared host.

### Operational notes

- **First connection per persist window is still cold.** The master is created during the first `git fetch`/`ssh`; only subsequent ones inside the persist window benefit. Idle for 10m → next launch pays the full handshake again.
- **`%C` hashes `(localuser, host, hostname, port, remoteuser)`.** A master created by `git fetch git@github.com` lives at a different path than one created by `ssh github.com` (no user → defaults to local user). `ssh -O check github.com` will report "no socket" against a `git@`-keyed master — use `ssh -O check git@github.com` to inspect the right one.
- **Multiplexed children share the master's auth.** github only needs one identity so this doesn't bite, but if two simultaneous sessions to the same host needed different keys, the second would silently inherit the first's.
- **Lifecycle:** `ssh -O stop git@github.com` drops the master cleanly; `ssh -O check git@github.com` reports state without opening a new connection. The socket file in `~/.ssh/sockets/` is the visible evidence; if it disappears, the master died and the next op will be cold again.
