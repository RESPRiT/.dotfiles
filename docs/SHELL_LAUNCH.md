---
tracks:
  - bashrc
  - zshrc
  - shellrc
  - hooks/post-merge
  - ~/.ssh/config
---

# Shell launch

`bashrc`/`zshrc` invoke `_repo_auto_update` (defined in `shellrc`) synchronously at startup when `DOTFILES_AUTO_UPDATE=1` and/or `DOCS_AUTO_UPDATE=1` is set in local rc. Synchronous-with-output is deliberate: the prior detached-background `( … &)` form silently swallowed `post-merge` migration stderr and raced its stdout against the prompt redraw, so migration progress and failures were effectively invisible. The fetch is wrapped in a 5s wall-clock cap via `timeout`/`gtimeout`/`perl`'s alarm-then-exec trick (the SIGALRM timer survives `exec` on macOS and Linux), so a flaky network can't hang the prompt indefinitely.

The dominant startup cost is the SSH handshake to github — measured at ~1s per fetch on this machine, paid twice when both repos auto-update. Wrapper, DNS, and `rev-list HEAD..@{u}` together are <60ms. The mitigation below keeps warm-shell startup under a second.

## SSH connection multiplexing (per-machine)

Add to `~/.ssh/config`:

```
Host github.com
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%C
  ControlPersist 10m
```

One-time setup: `mkdir -p ~/.ssh/sockets && chmod 700 ~/.ssh/sockets`.

The first ssh-based git op of a session opens a control socket and stays in the background; subsequent ops to the same `(user, host, port)` skip the handshake entirely. Observed: cold fetch ~1.27s (creates master), warm fetch ~0.51s (reuses master). End-to-end shell launch with both repos auto-updating drops from ~2.5s (two cold) to ~1.0s (two warm) inside the persist window.

This config is **not** committed to the dotfiles repo:

- `~/.ssh/config` already carries per-host identity routing that varies between machines.
- macOS and Linux OpenSSH support `ControlMaster`; Windows OpenSSH historically didn't, so a shared config would silently no-op there.
- The control socket grants any local process running as the same user the ability to use the multiplexed connection without re-auth. Fine on a single-user laptop, debatable on a shared host.

### Operational notes

- **First connection per persist window is still cold.** The master is created during the first `git fetch`/`ssh`; only subsequent ones inside the persist window benefit. Idle for 10m → next launch pays the full handshake again.
- **`%C` hashes `(localuser, host, hostname, port, remoteuser)`.** A master created by `git fetch git@github.com` lives at a different path than one created by `ssh github.com` (no user → defaults to local user). `ssh -O check github.com` will report "no socket" against a `git@`-keyed master — use `ssh -O check git@github.com` to inspect the right one.
- **Multiplexed children share the master's auth.** github only needs one identity so this doesn't bite, but if two simultaneous sessions to the same host needed different keys, the second would silently inherit the first's.
- **Lifecycle:** `ssh -O stop git@github.com` drops the master cleanly; `ssh -O check git@github.com` reports state without opening a new connection. The socket file in `~/.ssh/sockets/` is the visible evidence; if it disappears, the master died and the next op will be cold again.
