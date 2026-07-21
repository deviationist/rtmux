# iSH-on-iOS compatibility notes (for rtmux & friends)

Findings from running `ish-probe.sh` inside **iSH** on an **iPhone 15 Pro**.
iSH is a usermode **x86 (i686) emulator** running **Alpine Linux** with
**busybox** as the base userland. The goal here is to know what our zsh
operator helpers — chiefly [`rtmux`](rtmux.zsh) — can rely on when run from
the phone, and which fallbacks they need.

> Status: **feasibility confirmed.** Local capabilities mapped via
> `ish-probe.sh`; **SSH confirmed working** (used routinely from iSH on this
> phone). The only open sub-question is whether OpenSSH connection
> *multiplexing* works — an optimisation, not a blocker. rtmux-on-iSH is a go.

## Environment

- Kernel string: `Linux localhost 4.20.69-ish SUPER AWESOME … i686` — emulated,
  not a real device kernel.
- `TERM=xterm-256color`. ANSI colour + bold render; 256-colour assumed OK.
- Userland is **busybox** (`dd` reports `BusyBox v1.33.1`), so most "coreutils"
  are busybox applets with reduced option sets (see quirks below).

## What works (confirmed)

| Capability | Result | Relevance to rtmux |
|---|---|---|
| **zsh 5.8.1** present | ✅ | rtmux is a zsh function — runtime exists |
| zsh idioms `${(q)}`, arrays, `read -r -d ''` heredoc capture | ✅ | inspector heredoc + quoting |
| zsh `read -k / -t / -s` (single-key + timeout reads) | ✅ | the core of a pure-zsh picker |
| zsh modules `zselect`, `system`, `zle`, `datetime` load | ✅ | timeout-poll loop without fzf; live refresh possible |
| zsh `EXIT` trap fires | ✅ | rtmux cleanup (temp files / master socket) |
| ANSI colour / bold / `\r` + `ESC[2K` clear-line | ✅ | spinner + coloured rows |
| **Raw single-key read** (`stty raw` + `dd bs=1`) | ✅ (byte `0x61`) | press-a-digit selection |
| **Arrow keys** send clean `ESC[A` | ✅ (`1b 5b 41`) | arrow-key nav also viable (see note) |
| Fractional `sleep 0.2` | ✅ | spinner / poll cadence |
| `stty size` → rows×cols | ✅ (**29×50** — narrow!) | menu layout; design for **~50 cols** |
| Background `&` + `wait` | ✅ | spinner / poll model |
| busybox toolset (`awk/sed/grep/cut/tr/mktemp/nc`) + `git 2.32.7` | ✅ | scripting + `git pull` to deploy |
| **`fzf`** | ✅ **works** (`apk add fzf`) | rtmux's picker may run **as-is** — see version caveat below |
| **SSH** | ✅ (used routinely in iSH) | the transport rtmux needs — confirmed |

## What's missing or weak

| Thing | State | Consequence |
|---|---|---|
| `bash`, `dash` | ❌ missing | normal on iSH; only `zsh` + busybox `ash`/`sh` matter. Don't assume bash. |
| `tmux`, `python3` **locally** | ❌ missing | **fine** — in rtmux these run **remotely** on the target hosts, never on the phone. |
| `tput` / terminfo | ❌ missing | can't use terminfo; **hardcode ANSI escapes** (which work). Geometry via `stty size`, not `tput cols`. |

> **Arrow keys note:** an earlier probe run showed garbage bytes (`6f 6c 1b`)
> for the UP-arrow — that was **leftover buffered input** from the preceding
> keypress test, not an iSH defect. A clean run sends the standard `ESC[A`
> (`1b 5b 41`), so arrow nav works. Numbered selection (press a digit) is still
> the simpler, more finger-friendly choice on a phone, but arrows are available.

> **fzf works (correction):** I first flagged fzf as a poor bet because it's a Go
> binary and the Go runtime is iSH's classic weak spot. On this iSH build,
> `apk add fzf` installs and runs fine — so rtmux's existing fzf UI may run
> **as-is**, and the pure-zsh numbered picker drops to a *fallback*, not a
> requirement. **Caveat (FIXED):** iSH's Alpine repo ships **fzf 0.27** — old
> enough to miss several features rtmux used: the `load` auto-refresh event
> (0.36+), `show-preview`/`hide-preview` actions and comma-form
> `--preview-window` (0.38+), and `--id-nth` (0.71+). rtmux now reads
> `fzf --version` once and **version-gates each of these**, falling back to
> `toggle-preview` + colon-delimited preview-window + ctrl-r-only refresh on old
> fzf. So rtmux runs on fzf 0.27; you just lose live auto-refresh (use ctrl-r)
> and stable-cursor-on-reload. Updating fzf on iSH is impractical (no 32-bit
> official binaries; mixing Alpine `edge` repos is risky), so this compat path
> is the supported one.

## busybox quirks that bit the probe

- **`<cmd> --version` is dangerous on shells.** `ash --version` isn't a real
  busybox option; instead of erroring it drops into an **interactive shell
  reading the terminal**, so a script appears to "freeze." Always run version
  probes with stdin redirected (`</dev/null`). Several applets print
  `unrecognized option` for `--version` (e.g. `ssh`, `od`, `stty`) — that's
  cosmetic, the binary is present.
- busybox applets generally have **fewer flags** than GNU/coreutils — assume the
  POSIX subset, not GNU extensions.

## SSH — confirmed working

SSH is used routinely from iSH on this phone, so the transport rtmux depends on
is **not** a blocker (this retires the earlier "SSH via iSH doesn't work"
worry). Reachability in the probed setup was over WireGuard onto a home LAN;
targets are ordinary `user@host` ssh destinations either way.

The one open sub-question is **connection multiplexing** (`ControlMaster`),
which only OpenSSH supports — it's the rtmux "fast path" that reuses one
authenticated socket for the listing, previews, and attach. It's an
**optimisation, not a requirement**: the iSH rtmux variant should *try*
ControlMaster and **fall back to one ssh per action** if the socket can't be
created (or if iSH ships Dropbear). With live-refresh off by default on a phone,
the no-mux cost is just one connect per manual refresh + one for the attach —
perfectly acceptable.

`ssh -t` (the pty for `tmux attach`) is exercised every time interactive ssh is
used, so it works. The remote inspector needs `python3` + `tmux`, both already
present on the target hosts.

## rtmux-on-iSH — try stock first

With **fzf working**, every local dependency rtmux needs (zsh, fzf, ssh) is
present, so step one is to run **stock `rtmux` as-is**:

```sh
source ~/.zsh/rtmux/rtmux.zsh
rtmux -W user@host             # -W = no live refresh (right default on a phone)
```

If it breaks, the likely culprits and the iSH-friendly adjustments:

1. **fzf version** — iSH/Alpine ships **fzf 0.27**. rtmux now version-gates every
   feature newer than that (`load` 0.36, `show/hide-preview` + comma
   `--preview-window` 0.38, `--id-nth` 0.71) and falls back cleanly. Fixed; runs
   on 0.27 with ctrl-r refresh instead of live auto-refresh.
2. **Live auto-refresh is wrong on a phone** — the default 1 s poll loop spawns
   an ssh + remote python3 every tick (battery; iOS suspends the app when
   backgrounded). Use `-W`, or give the iSH path a long interval / manual refresh.
3. **Multiplexing may be absent** — rtmux leans on `ControlMaster`. If the
   control socket can't be created, ssh silently falls back to a fresh
   connection per call: it still *works*, but each list/preview/attach
   reconnects. With key auth that's just slower; with passwords it's painful. A
   `RTMUX_NO_CM` path would keep it clean.
4. Everything else (remote python3 inspector, `ssh -t` attach) is unchanged —
   it runs on the remote hosts, which already have python3 + tmux.

## How to re-run

```sh
cd ~/.zsh/rtmux && git pull
./ish-probe.sh                    # local capabilities
./ish-probe.sh user@host          # + SSH reachability
```

`ish-probe.sh` is a temporary diagnostic; this file is the durable record.
