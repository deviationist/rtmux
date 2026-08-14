# rtmux — agent index

`rtmux` lists the tmux sessions of one or several **remote** hosts in an `fzf`
picker and ssh-attaches to the pick. Rows are enriched **on the remote side** —
attached marker, the pane's cwd basename, its main process, and for Claude Code
panes the conversation's AI title plus live status — so an anonymous `2` becomes
`● myapp claude Fix the pagination race`.

**Entry point:** `rtmux.zsh` defines the `rtmux` function (sourced from `~/.zshrc`).
Config auto-loads from a gitignored `.env` beside the script (see `.env.example`);
`RTMUX_ENV_FILE` overrides that path (the test suite injects a fixture with it).

## Command

```
rtmux [-d] [-n] [-a] [-i SECS] [-W] [host[:dir] …] [name]
  <host>          ssh alias or user@host
  <h1> <h2> …     several remotes → one merged, tabbed picker
  <host>:<dir>    attach to the session rooted in <dir>, or start one there
  -a, --all       fan out over the whole $RTMUX_HOSTS pool (ignore $RTMUX_HOST)
  -d, --detach    attach with -d (detach other clients first)
  -n, --new       skip the picker: start a session (`-n NAME` names it directly)
  -i, --interval  poll interval in seconds (default 1; fractional ok)
  -W, --no-watch  disable auto-refresh (ctrl-r to refresh manually)
```

- **Picker keys:** Enter attach · `ctrl-n` new session · `ctrl-r` refresh ·
  `Tab`/`Shift-Tab` cycle host tabs (multi-host) · `→` live pane preview · `←`
  hide · Esc cancel.
- **Remote enrichment (`$_RTMUX_REMOTE_PY`, `rtmux.zsh:65`):** a quoted-heredoc
  Python script piped to the remote `python3`, emitting TSV. Single-host rows are
  `<display>\t<session>`; multi-host rows add `\t<slug>\t<host>` (slug =
  ControlPath-safe token) so preview/attach/`ctrl-n` route to the row's own host.
  Claude→session mapping is **exact**: `~/.claude/sessions/<pid>.json` (written per
  live process, carrying `sessionId`/`cwd`/`status`) is matched by walking the
  pane's process tree, then the title is read from that transcript under
  `~/.claude/projects`. Older Claude builds without the per-pid file fall back to
  the newest transcript. No `/proc` (non-Linux remote) → rows degrade to the
  pane's command name.
- **Row order:** unattached first (that's the one you're jumping into), then by
  most-recent activity — `att` then `-act` in the inspector's sort key.
- **Directory targets (`host:dir`)** — resolved remotely by `$_RTMUX_DIRQ_SH`
  (`~`/relative expand against the remote `$HOME`). One match → attach. Several →
  a picker over just those, preview open up front. None → two default-yes prompts
  (start a session named after the dir? launch Claude Code in it?); a missing dir
  offers `mkdir -p` first. `-n` forces a fresh session regardless.
- **Multi-host (`_rtmux_multi`, `rtmux.zsh:597`):** hosts are queried in parallel,
  one ControlMaster each at `$cpbase-$slug`, merged into one list; each row gets a
  colour from a 6-entry palette padded to the longest host name (max 14). The tab
  bar is `transform-header`. Unreachable hosts are noted, not fatal.
- **Host precedence:** explicit args → `--all` pool → `RTMUX_HOST` (default single)
  → `RTMUX_HOSTS` pool. `-n` and `-a` don't combine.
- **New sessions:** Enter auto-names; a typed name matching `$RTMUX_CODE_DIR/<name>`
  on the remote triggers the start-there + launch-Claude offers.
- **One connection per host:** ControlMaster (`ControlPersist=30`,
  `ConnectTimeout=10`) covers listing, polls, previews and the attach — at most one
  password/2FA prompt — torn down on every exit path including `Ctrl-C`. Connect
  runs behind a spinner (`_rtmux_spin`) with the login banner suppressed unless it
  fails.
- **Live refresh:** fzf's `load` event self-perpetuates the poll loop; the cursor is
  pinned across reloads with `--id-nth`.

## Env vars

| Var | Default | Purpose |
|---|---|---|
| `RTMUX_HOST` | unset | default single remote for a bare `rtmux` |
| `RTMUX_HOSTS` | unset | space-separated fan-out pool (`--all`, or bare `rtmux` with no default) |
| `RTMUX_WATCH` | `1` | live refresh on/off (`0` = `-W`) |
| `RTMUX_WATCH_INTERVAL` | `1` | seconds between refreshes (fractional ok) |
| `RTMUX_CODE_DIR` | `~/code` | remote project root for the `-n` name match |
| `RTMUX_ENV_FILE` | `<script dir>/.env` | override the `.env` path (test hook) |

## fzf version gating

`fzf --version` is parsed once and **every** newer feature is gated, so rtmux runs
on builds as old as **0.27** (what iSH/Alpine ships — see `ish-compat.md`):

| Feature | Needs | Below that |
|---|---|---|
| `load` event (auto-refresh) | 0.36+ | manual `ctrl-r` only, header says so |
| `show-preview`/`hide-preview`, comma `--preview-window`, tab bar (`transform-header`) | 0.38+ | `toggle-preview`, colon form, no tabs |
| `--id-nth` (stable cursor across reloads) | 0.71+ | omitted |

## Conventions

- Deps: `zsh` + `fzf` + `ssh` locally; `tmux` + `python3` **on the remote** only —
  nothing is installed there, the inspector is piped inline.
- `.env` is sourced inside function scope with the keys pre-`typeset`ed local, so it
  never leaks into the interactive shell.
- The generated on-the-fly `sh` helpers (awk field filters, tab-split flags, mod
  arithmetic for tab cycling) are the fragile part — they only break in a live
  picker, which is exactly what the tests lock down.
- Completion (`_rtmux_complete`) registers via `compdef`, deferring to a `precmd`
  hook if sourced before `compinit`. Hosts complete with **no** trailing suffix so
  `host:` chains; `host:<Tab>` lists remote dirs over ssh `BatchMode=yes
  ConnectTimeout=3` (never password-prompts mid-completion).
- Watch out for zsh 5.9: a freshly loop-`local` var used as `printf -v`'s target
  echoes `name=value` to stdout and corrupts the picker's first row — declare it
  outside the loop (`rtmux.zsh:614`).
- Tests: `zsh tests/rtmux.test.zsh` — stubs `ssh` and `fzf`, so no network, no
  remote, no real tmux (tmux-backed inspector checks skip when it's absent). CI
  runs `zsh -n` on both files plus the suite on every push/PR.
- README images: `zsh tools/generate-readme-svg.zsh` — stands up two local tmux
  servers on private sockets as the "remotes", stubs `ssh` to dispatch to them,
  and renders the **real** rtmux output (rows, colours, header, tab bar,
  preview) into `assets/*-<hash>.svg`, rewriting the README refs. Commit the
  SVGs with the README. Sandbox gotchas worth not rediscovering: a pane's
  command name comes from the *executable's* filename (so the demo compiles an
  idle stub and copies it to `claude`/`zsh`); `-t 0` is an ambiguous tmux target
  (use `=0:`); and the run needs a pty or the connect spinner returns early and
  the listing comes back empty.
- **Never hand-write a command the tool itself builds.** The preview pane is
  produced by extracting the `--preview=` string rtmux handed fzf and filling
  fzf's `{2}`/`{3}`/`{4}` from the highlighted row, then running *that* — so a
  broken preview path fails the build instead of quietly rendering a plausible
  picture. (fzf expands `{n}` against the **original** line, not the
  `--with-nth=1` display field — verified against fzf 0.74 — which is what makes
  `{2}`=session / `{3}`=slug / `{4}`=host work at all.)
