# rtmux — remote tmux session picker.
#
# Lists the tmux sessions on a remote host in an fzf picker and, on Enter,
# ssh's in and attaches to the chosen one. Each row is enriched on the remote
# side: attached state, window count, and the *main process* of the session's
# active pane. When that process is Claude Code, the row also shows the
# conversation's AI-generated title (falling back to the last prompt) — pulled
# from the session transcript under ~/.claude/projects on the remote host — so
# you can jump straight back into the right remote coding session.
#
#   rtmux <host>           pick a session on <host> (ssh alias or user@host)
#   rtmux <host> <host>…   pick across several remotes at once (see below)
#   rtmux <host>:<dir>     attach to the session rooted in <dir> on <host>, or
#                          start one there (`rtmux dev:~/code/project`); tab
#                          completion completes the remote directories
#   rtmux -d <host>        attach with -d (detach any other clients first)
#   rtmux <host> -n [name] skip the picker: start a new session right away
#                          (auto-named, or -n <name> for a named one)
#   rtmux                  use $RTMUX_HOSTS / $RTMUX_HOST if set, else usage
#
# Multiple remotes: pass more than one host (or set RTMUX_HOSTS="prod dev" in
# ~/.zsh/.env) and rtmux queries them all, merging their sessions into one
# picker. Each row is tagged with a coloured host column, and a tab bar across
# the top lets you Tab / Shift-Tab through per-host views (plus an "All" tab
# that shows everything). Attach, preview, and ctrl-n all target the host of
# the row you're on. A single host keeps the original tab-less behaviour.
#
# When the host has no tmux sessions, rtmux offers to start one (over the same
# SSH master channel) instead of just bailing — Enter/y for an auto-named
# session, a typed name for a named one, n to decline. The same offer is on
# ctrl-n inside the picker. If a typed name matches a ~/code/<name> dir on the
# remote ($RTMUX_CODE_DIR, default ~/code), rtmux then offers — both default-yes
# — to start the session in that dir and to launch Claude Code in it.
#
# The <host>:<dir> form targets a directory: rtmux resolves <dir> on the
# remote (~ and relative paths expand against the remote $HOME) and attaches
# to the session already rooted there (-d honoured). Several sessions rooted
# in the same dir → a picker over just those (Enter attach, ctrl-n new, Esc
# cancel). None → starts one with `tmux new-session -c <dir>`, named after the
# directory, behind two default-yes prompts (start there? — n cancels outright
# — then launch Claude Code in it?). Adding
# -n forces a fresh session even when one is already rooted in the dir. A zsh
# completion (registered at the bottom of this file) completes hosts and, after
# `host:`, the remote directories themselves.
#
# Unattached sessions sort to the top (the one you're jumping into is usually
# the one you haven't attached yet); attached sessions sink to the bottom. Within
# each group, rows are ordered by most-recent activity.
#
# In the picker: ↑/↓ navigate, Enter attach, ctrl-n start a new session,
# → live-preview the session's pane (← hides it again), Esc cancels.
#
# Requires: fzf locally; tmux + python3 on the remote host. Session/process
# enrichment uses the remote /proc (Linux); on a host without /proc it
# degrades to just the pane's foreground command (no Claude title).
#
# An SSH ControlMaster connection is opened for the duration so the initial
# listing, every preview, and the final attach all reuse one authenticated
# channel (fast; one password/2FA prompt at most). It is torn down on exit.

# Remote inspector script. Quoted heredoc — runs verbatim on the remote python3,
# no local expansion. Emits TSV lines:  <display>\t<session_name>
# where <display> carries ANSI colour (rendered via fzf --ansi).
read -r -d '' _RTMUX_REMOTE_PY <<'PYEOF'
import os, sys, json, glob, subprocess

HOME = os.path.expanduser("~")
PROJ = os.path.join(HOME, ".claude", "projects")

C_GREEN = "\033[32m"; C_DIM = "\033[2m"; C_CYAN = "\033[36m"
C_YEL = "\033[33m"; C_BOLD = "\033[1m"; C_RST = "\033[0m"

def sh(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""

sess_fmt = "#{session_name}\t#{session_attached}\t#{session_windows}\t#{session_activity}"
sessions = []
for line in sh("tmux", "list-sessions", "-F", sess_fmt).splitlines():
    p = line.split("\t")
    if len(p) < 4:
        continue
    sessions.append({"name": p[0], "att": p[1] == "1", "win": p[2],
                     "act": int(p[3]) if p[3].isdigit() else 0})
if not sessions:
    sys.exit(0)

# Active pane per session: pid, foreground command, and tmux's own cwd.
active = {}
for line in sh("tmux", "list-panes", "-a", "-F",
               "#{session_name}\t#{pane_active}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}").splitlines():
    q = line.split("\t")
    if len(q) >= 5 and q[1] == "1":
        active[q[0]] = {"pid": q[2], "cmd": q[3], "path": q[4]}

# Authoritative pid -> running-session map. Claude Code writes one
# ~/.claude/sessions/<pid>.json per live process, carrying the exact
# {pid, sessionId, cwd, status, updatedAt, …}. Using this avoids guessing the
# session by transcript mtime (which is wrong when a cwd has several sessions).
sess_by_pid = {}
sdir = os.path.join(HOME, ".claude", "sessions")
try:
    for fn in os.listdir(sdir):
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(sdir, fn)) as fh:
                d = json.load(fh)
            if "pid" in d and "sessionId" in d:
                sess_by_pid[str(d["pid"])] = d
        except Exception:
            pass
except Exception:
    pass

# ppid -> [children] map from /proc, to walk a pane's process tree.
proc_ok = os.path.isdir("/proc/1")
children = {}
if proc_ok:
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % d) as fh:
                st = fh.read()
            # comm (field 2) is parenthesised and may contain spaces — split
            # after the closing paren so ppid (field 4) is read correctly.
            fields = st[st.rfind(")") + 2:].split()
            children.setdefault(fields[1], []).append(d)
        except Exception:
            pass

def tree(pid):
    out = []; seen = set(); stack = [pid]
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p); out.append(p)
        stack.extend(children.get(p, []))
    return out

def find_session(pane_pid, pane_path):
    # Exact: a sessions/<pid>.json for any process in the pane's tree.
    cands = [sess_by_pid[p] for p in tree(pane_pid) if p in sess_by_pid]
    # Fallback (no /proc, or older Claude): match a live session by cwd.
    if not cands:
        cands = [d for d in sess_by_pid.values() if d.get("cwd") == pane_path]
    if not cands:
        return None
    return max(cands, key=lambda d: d.get("updatedAt", 0))

def transcript_title(cwd, sid):
    # Exact transcript for this session id; encoded cwd = "/" -> "-".
    f = os.path.join(PROJ, cwd.replace("/", "-"), "%s.jsonl" % sid)
    return read_title(f) if os.path.exists(f) else None

def newest_title(cwd):
    # mtime fallback for Claude builds that don't write sessions/<pid>.json.
    if not cwd:
        return None
    files = glob.glob(os.path.join(PROJ, cwd.replace("/", "-"), "*.jsonl"))
    if not files:
        return None
    return read_title(max(files, key=lambda x: os.path.getmtime(x)))

def read_title(f):
    title = lp = None
    try:
        for line in open(f, errors="replace"):
            try:
                m = json.loads(line)
            except Exception:
                continue
            t = m.get("type")
            if t == "ai-title":
                title = m.get("aiTitle") or title
            elif t == "last-prompt":
                lp = m.get("lastPrompt") or lp
    except Exception:
        pass
    if title:
        return title
    if lp:
        return "» " + lp[:70]
    return None

def short_path(path):
    if not path:
        return "?"
    if path == HOME:
        return "~"
    return os.path.basename(path.rstrip("/")) or path

# Colour the "claude" tag by status: busy = working, idle = waiting on you.
STATUS_COLOUR = {"busy": C_YEL, "idle": C_CYAN, "shell": C_DIM}

prepared = []
projw = 4
# Unattached sessions first (the ones you're likely jumping into), then most
# recent activity within each group. att=False sorts before att=True; negate
# activity so newest stays on top.
for s in sorted(sessions, key=lambda x: (x["att"], -x["act"])):
    a = active.get(s["name"], {"pid": "", "cmd": "?", "path": ""})
    sd = find_session(a["pid"], a["path"]) if a["pid"] else None
    if sd:
        cwd = sd.get("cwd") or a["path"]
        proj = short_path(cwd)
        title = transcript_title(cwd, sd["sessionId"])
        status = sd.get("status", "idle")
        kind = "claude"
    elif a["cmd"] == "claude":
        proj = short_path(a["path"])
        title = newest_title(a["path"])
        status = "idle"
        kind = "claude"
    else:
        proj = short_path(a["path"])
        title = None
        status = None
        kind = a["cmd"]
    projw = max(projw, len(proj))
    prepared.append((s, proj, kind, status, title))

# Optional multi-host framing, passed as argv: <host_col> <slug> <host>.
# When present, every row is prefixed with the pre-coloured, pre-padded host
# column and carries two extra trailing fields — the slug (safe token for the
# ssh ControlPath) and the host (ssh target) — so the local picker can filter
# by host and attach to the right one. Absent (single-host mode) the output
# format is byte-for-byte unchanged.
host_col = sys.argv[1] if len(sys.argv) > 1 else None
h_slug   = sys.argv[2] if len(sys.argv) > 2 else ""
h_name   = sys.argv[3] if len(sys.argv) > 3 else ""

projw = min(projw, 22)
rows = []
for s, proj, kind, status, title in prepared:
    if kind == "claude":
        tag = "%sclaude%s" % (STATUS_COLOUR.get(status, C_CYAN), C_RST)
        detail = tag if not title else "%s  %s%s%s" % (tag, C_BOLD, title, C_RST)
    else:
        detail = "%s%s%s" % (C_DIM, kind, C_RST)
    dot = (C_GREEN + "●") if s["att"] else (C_DIM + "○")
    p = proj if len(proj) <= projw else proj[:projw - 1] + "…"
    win = ("  %s%sw%s" % (C_DIM, s["win"], C_RST)) if s["win"] != "1" else ""
    display = "%s%s %-*s%s%s  %s" % (dot, C_RST, projw, p, C_RST, win, detail)
    if host_col is None:
        rows.append("%s\t%s" % (display, s["name"]))
    else:
        rows.append("%s%s\t%s\t%s\t%s" % (host_col, display, s["name"], h_slug, h_name))

sys.stdout.write("\n".join(rows) + ("\n" if rows else ""))
PYEOF

# Remote directory query for the <host>:<dir> form. Runs as `sh -s -- <dir> [mk]`
# on the remote (POSIX sh — dash-safe), with <dir> shell-quoted locally via
# ${(q)…} so spaces survive ssh's join-args-with-spaces. Tilde and relative
# paths are expanded here, against the *remote* $HOME (never locally — the
# local and remote homes differ, e.g. /Users vs /home). With "mk" as $2 the
# directory is created first (the create-it? prompt path). Emits TSV:
#   DIR   <resolved absolute path>          (always, first)
#   SESS  <name>                            (every tmux session — collision dodging)
#   MATCH <name>                            (every session rooted in the dir:
#                                            active-pane cwd or session start dir
#                                            equals the target; newest activity
#                                            first, deduped — a session shows one
#                                            active pane per *window*)
# Exits 3 when the directory doesn't exist. Field separators are literal tabs.
read -r -d '' _RTMUX_DIRQ_SH <<'SHEOF'
p=$1
case "$p" in
  "~")   p=$HOME ;;
  "~/"*) p=$HOME/${p#"~/"} ;;
  /*)    : ;;
  *)     p=$HOME/$p ;;
esac
[ "${2-}" = mk ] && mkdir -p -- "$p" 2>/dev/null
cd -- "$p" 2>/dev/null || exit 3
d=$(pwd -P)
printf 'DIR\t%s\n' "$d"
tmux list-sessions -F 'SESS	#{session_name}' 2>/dev/null
tmux list-panes -a -F '#{session_activity}	#{session_name}	#{pane_active}	#{pane_current_path}	#{session_path}' 2>/dev/null |
  awk -F'	' -v d="$d" '$3==1 && ($4==d || $5==d) { print $1 "\t" $2 }' |
  sort -rn | cut -f2- | awk '!seen[$0]++ { print "MATCH\t" $0 }'
SHEOF

# Remote directory *listing* for tab completion (`host:<dir-prefix><Tab>`).
# Same path expansion as the query above; `ls -1p` marks directories with a
# trailing slash (the completion keeps only those). $2 is the ls flags — the
# completion passes -1Ap instead when the typed basename starts with a dot,
# so hidden dirs only appear once asked for.
read -r -d '' _RTMUX_LS_SH <<'SHEOF'
p=$1
case "$p" in
  "~")   p=$HOME ;;
  "~/"*) p=$HOME/${p#"~/"} ;;
  /*)    : ;;
  *)     p=$HOME/$p ;;
esac
cd -- "$p" 2>/dev/null || exit 1
ls ${2:--1p} 2>/dev/null
SHEOF

# Braille spinner shown on stderr while the initial connect + first listing run
# (the live polls afterwards get fzf's own spinner). Spins until $1 — a marker
# file the background job writes when it finishes — exists. No-op off a TTY.
#
# It also polls `_rtmux_int`, a flag the caller's INT trap flips on Ctrl-C
# (visible here via zsh dynamic scoping). Without this, Ctrl-C while the
# background SSH hangs (e.g. VPN down) couldn't break the loop — async `&` jobs
# under `no_monitor` ignore SIGINT, so the marker never appears until
# ConnectTimeout and the spinner would spin on regardless. Returns 130 so the
# caller can distinguish a cancel from a finished connect.
_rtmux_spin() {
  local rcf="$1" msg="$2"
  [[ -t 2 ]] || return 0
  local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local i=1 n=${#frames}
  while [[ ! -e "$rcf" ]]; do
    (( _rtmux_int )) && { printf '\r\033[2K' >&2; return 130; }
    printf '\r\033[36m%s\033[0m %s' "${frames[i]}" "$msg" >&2
    i=$(( i % n + 1 ))
    sleep 0.1
  done
  printf '\r\033[2K' >&2   # clear the spinner line before fzf paints
}

# Prompt for and start a new tmux session on the remote host, then attach to it
# — reusing the established SSH master channel. Shared by the no-sessions path,
# the in-picker ctrl-n binding, and the -n/--new direct path. Reads $host and
# $cm from the rtmux caller via zsh dynamic scoping (same idiom as _rtmux_spin's
# $_rtmux_int). $1 is the prompt text (host already interpolated); an optional
# $2 is a preset session name (from `rtmux <host> -n <name>`) that skips the
# [Y/n/name] prompt and goes straight to the named-session flow.
#
# An empty answer or y/yes starts an auto-named session (tmux picks 0/1/2…);
# n/no declines; anything else becomes the new session's *name*. When a typed
# name matches a project directory under ~/code on the remote ($RTMUX_CODE_DIR,
# default ~/code), rtmux offers — both default-yes — to (a) start the session in
# that directory and (b) launch Claude Code in it. Returns 0 on decline, else
# ssh's exit code.
#
# The remote tmux command is built as one shell-quoted string (zsh ${(q)…}) so
# spaces in the name or directory survive ssh's join-args-with-spaces, and the
# directory's leading ~ is left unquoted so the *remote* shell expands it.
_rtmux_new_session() {
  local reply
  # The caller's connect-spinner INT trap only flips a flag, and zsh *resumes* a
  # `read` after a flag-only trap runs — so Ctrl-C at these prompts would be
  # swallowed and the prompt would hang. Install a returning INT trap instead:
  # Ctrl-C prints a notice and unwinds to the caller, whose EXIT trap tears down
  # the ssh master. local_traps (set by the caller) keeps this scoped here and
  # restores the flag trap on return. It's cleared just before each interactive
  # `ssh -t` so the live session — not rtmux — owns Ctrl-C.
  trap 'printf "\nrtmux: cancelled\n" >&2; return 130' INT
  if [[ -n "${2-}" ]]; then
    reply="$2"                   # preset name from -n <name>: skip the prompt
  else
    printf '\033[36mrtmux:\033[0m %s [Y/n/name] ' "$1" >&2
    read -r reply </dev/tty
    case "$reply" in
      n|N|no|NO) echo "rtmux: cancelled" >&2; return 0 ;;
      ''|y|Y|yes|YES)
        # Auto-named, no project association.
        trap - INT               # live session owns the terminal from here
        ssh -t "${cm[@]}" "$host" tmux new-session
        return $? ;;
    esac
  fi

  local name="$reply"
  local code_dir="${RTMUX_CODE_DIR:-~/code}"   # remote path; ~ expands remotely
  local projdir="" want_claude=0 ans

  # Does ~/code/<name> exist on the remote? One round-trip over the master.
  if ssh "${cm[@]}" "$host" "test -d ${code_dir}/${(q)name}" 2>/dev/null; then
    printf '\033[36mrtmux:\033[0m %s/%s exists — start the session there? [Y/n] ' \
           "$code_dir" "$name" >&2
    read -r ans </dev/tty
    case "$ans" in
      n|N|no|NO) ;;
      *) projdir="${code_dir}/${(q)name}"
         printf '\033[36mrtmux:\033[0m start Claude Code in it? [Y/n] ' >&2
         read -r ans </dev/tty
         case "$ans" in n|N|no|NO) ;; *) want_claude=1 ;; esac ;;
    esac
  fi

  local rcmd
  if (( want_claude )); then
    # Create detached in the project dir, type `claude` into the session's
    # shell (honours the user's claude wrapper/alias, and the shell survives
    # claude exiting), then attach. `\;` reaches tmux as a command separator.
    rcmd="tmux new-session -d -s ${(q)name} -c ${projdir} \\; send-keys -t ${(q)name} claude Enter \\; attach -t ${(q)name}"
  elif [[ -n "$projdir" ]]; then
    rcmd="tmux new-session -s ${(q)name} -c ${projdir}"
  else
    rcmd="tmux new-session -s ${(q)name}"
  fi

  # -t for an interactive pty; reuses the master channel. The rtmux EXIT trap
  # tears the master + temp files down when the caller returns.
  trap - INT                     # live session owns the terminal from here
  ssh -t "${cm[@]}" "$host" "$rcmd"
}

# The <host>:<dir> form: attach to the tmux session already rooted in <dir> on
# the remote, or start one there. One round-trip over the master runs
# $_RTMUX_DIRQ_SH, which resolves the dir remotely (~/relative paths expand
# against the remote $HOME), lists every session name, and finds the sessions
# already rooted there (active-pane cwd or session start dir == target).
# One match + no -n → attach (honouring -d); several matches → a small fzf
# picker over just those sessions (Enter attach, ctrl-n new, Esc cancel).
# No match → a
# session is created with `-c <dir>`, named after the directory (basename made
# tmux-safe, -2/-3… on collision) or the -n <name> preset. On a TTY two
# default-yes prompts mirror the ~/code/<name> flow: "start <name> there?"
# (n cancels outright — nothing is created) and then "launch Claude Code in
# it?"; the first is skipped when intent is already explicit (-n, or a
# just-confirmed mkdir). A missing directory offers (TTY, default-no) to
# create it first. Reads
# $host/$cm/$detach from rtmux() via dynamic scoping, like the helpers above.
_rtmux_dir_session() {
  local dir="$1" force_new="${2:-0}" preset="${3-}"
  # Same returning INT trap rationale as _rtmux_new_session: make the prompts
  # below Ctrl-C-able, and hand the terminal to ssh before anything live runs.
  trap 'printf "\nrtmux: cancelled\n" >&2; return 130' INT

  local out rc mk="" ans
  while :; do
    out="$(print -r -- "$_RTMUX_DIRQ_SH" | ssh "${cm[@]}" "$host" sh -s -- "${(q)dir}" $mk 2>/dev/null)"
    rc=$?
    if (( rc == 3 )); then
      if [[ -z "$mk" && -t 0 && -t 2 ]]; then
        printf '\033[36mrtmux:\033[0m %s does not exist on %s — create it? [y/N] ' "$dir" "$host" >&2
        read -r ans </dev/tty
        case "$ans" in y|Y|yes|YES) mk=mk; continue ;; esac
      fi
      echo "rtmux: no such directory on $host: $dir" >&2
      return 1
    fi
    break
  done
  if (( rc != 0 )) || [[ -z "$out" ]]; then
    echo "rtmux: could not inspect $host (is tmux/sh available?)" >&2
    return 1
  fi

  local resolved="" line
  local -a names=() matches=()
  for line in "${(@f)out}"; do
    case "$line" in
      DIR$'\t'*)   resolved="${line#DIR$'\t'}" ;;
      SESS$'\t'*)  names+=("${line#SESS$'\t'}") ;;
      MATCH$'\t'*) matches+=("${line#MATCH$'\t'}") ;;
    esac
  done
  if [[ -z "$resolved" ]]; then
    echo "rtmux: could not resolve $dir on $host" >&2
    return 1
  fi

  # Which rooted session to attach to? Exactly one → that one. Several → the
  # user picks, never a silent guess: a small fzf picker over *just those
  # sessions* (rows enriched by the same remote inspector the main picker
  # uses, so Claude titles show; the pane preview is up-front since pane
  # content is what tells same-dir sessions apart). ctrl-n falls through to
  # creating another session there; Esc cancels. Without fzf, a plain
  # numbered prompt replaces the picker (Enter = the newest, q cancels);
  # only off a TTY — where no prompt is possible, and an attach is already
  # nonsensical — does it fall back to the newest-activity match.
  local match="" pick_new=0
  if (( ! force_new && ${#matches} )); then
    if (( ${#matches} == 1 )); then
      match="${matches[1]}"
    elif ! command -v fzf >/dev/null 2>&1; then
      if [[ -t 0 && -t 2 ]]; then
        local i
        printf '\033[36mrtmux:\033[0m %d sessions rooted in %s:\n' "${#matches}" "$resolved" >&2
        for i in {1..${#matches}}; do
          printf '  %d) %s\n' "$i" "${matches[i]}" >&2
        done
        printf '\033[36mrtmux:\033[0m attach to [1-%d, Enter=1, q cancels]: ' "${#matches}" >&2
        read -r ans </dev/tty
        case "$ans" in
          '')      match="${matches[1]}" ;;
          q|Q|n|N) echo "rtmux: cancelled" >&2; return 0 ;;
          <->)     (( ans >= 1 && ans <= ${#matches} )) && match="${matches[ans]}" ;;
        esac
        if [[ -z "$match" ]]; then
          echo "rtmux: invalid choice" >&2
          return 2
        fi
      else
        match="${matches[1]}"    # dirq sorts newest-activity first
      fi
    else
      local tsv m
      tsv="$(print -r -- "$_RTMUX_REMOTE_PY" | ssh "${cm[@]}" "$host" python3 - 2>/dev/null)"
      local -a rows=()
      for line in "${(@f)tsv}"; do
        m="${line##*$'\t'}"
        (( ${matches[(Ie)$m]} )) && rows+=("$line")
      done
      # Inspector hiccup → plain session-name rows, same field shape.
      (( ${#rows} )) || for m in "${matches[@]}"; do rows+=("${m}"$'\t'"${m}"); done
      local preview="ssh ${(q)cm[1]} ${(q)cm[2]} ${(q)host} tmux capture-pane -ep -t {2}"
      local fzf_out
      fzf_out="$(printf '%s\n' "${rows[@]}" | fzf \
          --delimiter=$'\t' --with-nth=1 \
          --ansi --no-sort --reverse --height=90% \
          --expect=ctrl-n \
          --header="${#matches} sessions rooted in $resolved — Enter attach · ctrl-n new · Esc cancel" \
          --preview="$preview" \
          --preview-window='down:55%:wrap')"
      local -a fzf_lines=("${(@f)fzf_out}")
      if [[ "${fzf_lines[1]-}" == ctrl-n ]]; then
        pick_new=1
      elif [[ -z "${fzf_lines[2]-}" ]]; then
        return 0                 # Esc / no selection
      else
        match="${fzf_lines[2]##*$'\t'}"
      fi
    fi
  fi

  if [[ -n "$match" ]]; then
    local -a attach=(tmux attach -t "${(q)match}")
    (( detach )) && attach=(tmux attach -d -t "${(q)match}")
    trap - INT                   # live session owns the terminal from here
    ssh -t "${cm[@]}" "$host" "${attach[@]}"
    return $?
  fi

  # No session rooted there (or -n forced a fresh one): create it. Name from
  # the -n preset, else the dir basename with tmux's forbidden . and : swapped
  # out; suffix -2/-3… past any existing session of the same name.
  local name="${preset:-${${resolved:t}//[.:]/_}}"
  if (( ${names[(Ie)$name]} )); then
    local i=2
    while (( ${names[(Ie)$name-$i]} )); do (( i++ )); done
    name="$name-$i"
  fi

  local want_claude=0
  if [[ -t 0 && -t 2 ]]; then
    # Two prompts, mirroring the ~/code/<name> flow: first a real way out —
    # n here cancels the whole thing, nothing is created — then the Claude
    # offer. The way-out prompt is skipped when intent is already explicit:
    # -n (a new session was asked for by flag), ctrl-n in the disambiguation
    # picker, or a just-confirmed mkdir.
    if (( ! force_new && ! pick_new )) && [[ -z "$mk" ]]; then
      printf '\033[36mrtmux:\033[0m no session rooted in %s — start \033[1m%s\033[0m there? [Y/n] ' \
             "$resolved" "$name" >&2
      read -r ans </dev/tty
      case "$ans" in n|N|no|NO) echo "rtmux: cancelled" >&2; return 0 ;; esac
    fi
    printf '\033[36mrtmux:\033[0m launch Claude Code in it? [Y/n] ' >&2
    read -r ans </dev/tty
    case "$ans" in n|N|no|NO) ;; *) want_claude=1 ;; esac
  fi

  local rcmd
  if (( want_claude )); then
    # Same shape as _rtmux_new_session's claude path: create detached, type
    # `claude` into the session's shell, then attach.
    rcmd="tmux new-session -d -s ${(q)name} -c ${(q)resolved} \\; send-keys -t ${(q)name} claude Enter \\; attach -t ${(q)name}"
  else
    rcmd="tmux new-session -s ${(q)name} -c ${(q)resolved}"
  fi
  trap - INT                     # live session owns the terminal from here
  ssh -t "${cm[@]}" "$host" "$rcmd"
}

# Multi-remote picker: query several hosts, merge their sessions into one fzf
# list with a coloured per-host column, and offer a Tab-through tab bar
# (All / per-host) that filters the merged view. Attach, preview, and ctrl-n
# each target the host carried on the selected row. Called by rtmux() when host
# resolution yields 2+ remotes; inherits $detach/$watch/$interval by zsh dynamic
# scoping (same idiom the other helpers use).
#
# Each row is a 4-field TSV:  <display>\t<session>\t<slug>\t<host>
#   display : host column (colour + padded name) + the single-host row body
#   session : tmux session name (attach/preview target)
#   slug    : filesystem/ControlPath-safe token for the host
#   host    : ssh target (alias or user@host)
# fzf shows only field 1 (--with-nth=1); fields 3/4 drive preview/attach.
#
# Because fzf reload/preview binds run under plain `sh`, the fetch/emit/header/
# tab-advance logic is emitted as small generated sh scripts on disk (paths and
# per-host colour columns baked in, ANSI single-quoted so `sh` keeps it literal).
# The tab bar needs fzf 0.38+ (transform-header); below that it degrades to a
# static merged list with no tab switching.
_rtmux_multi() {
  local -a hosts=("$@")
  local n=${#hosts}

  if ! command -v fzf >/dev/null 2>&1; then
    echo "rtmux: fzf is required locally (brew install fzf)" >&2
    return 1
  fi

  # fzf version (same parse as the single-host path). Multi-host tab switching
  # needs transform-header (0.38+); auto-refresh needs the load event (0.36+);
  # stable cursor across reloads needs --id-nth (0.71+).
  local fzf_ver="${$(fzf --version 2>/dev/null)%% *}"
  local fzf_minor="${fzf_ver#*.}"; fzf_minor="${fzf_minor%%.*}"
  [[ "$fzf_minor" == <-> ]] || fzf_minor=0
  local tabs=1; (( fzf_minor >= 38 )) || tabs=0

  # Per-host slug (ControlPath/filename-safe) + a pre-padded, pre-coloured host
  # column reused for every one of that host's rows (alignment is stable because
  # the pad width is the max host-name length).
  local RST=$'\033[0m' DIM=$'\033[2m' BOLD=$'\033[1m' REV=$'\033[7m'
  local -a palette=($'\033[36m' $'\033[35m' $'\033[33m' $'\033[32m' $'\033[34m' $'\033[31m')
  local -a slugs hostcols
  local hw=3 h i nm pad
  for h in "${hosts[@]}"; do (( ${#h} > hw )) && hw=${#h}; done
  (( hw > 14 )) && hw=14
  # nm/pad are declared once above, not `local` inside the loop: a freshly
  # loop-local var used as `printf -v`'s target echoes "name=value" to stdout
  # on zsh 5.9 (harmless-looking but it corrupts the picker's first row).
  for i in {1..$n}; do
    slugs+=("${hosts[i]//[^A-Za-z0-9_.-]/_}")
    nm="${hosts[i]}"; (( ${#nm} > hw )) && nm="${nm[1,hw-1]}…"
    printf -v pad "%-${hw}s" "$nm"
    hostcols+=("${palette[$(( (i-1) % ${#palette} + 1 ))]}${pad}${RST} ")
  done

  # Human-readable host list for messages: "prod & dev", "prod, dev & foo".
  local hostlist
  if (( n <= 2 )); then
    hostlist="${(j: & :)hosts}"
  else
    hostlist="${(j:, :)hosts[1,-2]} & ${hosts[-1]}"
  fi

  # Temp files. One ControlMaster per host at $cpbase-$slug; the merged listing
  # at $outf; the current tab index in $tabf; and the generated sh helpers.
  local cpbase="${TMPDIR:-/tmp}/rtmux-cm-$$-$RANDOM"
  local scriptf="${TMPDIR:-/tmp}/rtmux-py-$$-$RANDOM"
  print -r -- "$_RTMUX_REMOTE_PY" > "$scriptf"
  local outf="${TMPDIR:-/tmp}/rtmux-out-$$-$RANDOM"
  local errf="${outf}.err" rcf="${outf}.rc" failf="${outf}.fail"
  local tabf="${outf}.tab"; print -r -- 0 > "$tabf"
  local fetchf="${outf}.fetch" emitf="${outf}.emit" hdrf="${outf}.hdr" advf="${outf}.adv"

  # --- fetch: query every host in parallel (over its master), then concatenate
  # the per-host outputs in host order into $outf via an atomic rename. Passing
  # the host column + slug + host as argv makes the remote python emit the
  # 4-field multi-host rows. ANSI in the host column is single-quoted ((qq)) so
  # `sh` treats it literally rather than as zsh $'…'.
  {
    print -r -- "#!/bin/sh"
    for i in {1..$n}; do
      print -r -- "ssh -o ControlPath=${(q)cpbase}-${(q)slugs[i]} ${(q)hosts[i]} python3 - ${(qq)hostcols[i]} ${(q)slugs[i]} ${(q)hosts[i]} < ${(q)scriptf} > ${(q)outf}.h.${(q)slugs[i]} 2>/dev/null &"
    done
    print -r -- "wait"
    print -r -- ": > ${(q)outf}.tmp"
    for i in {1..$n}; do
      print -r -- "cat ${(q)outf}.h.${(q)slugs[i]} >> ${(q)outf}.tmp 2>/dev/null"
    done
    print -r -- "mv ${(q)outf}.tmp ${(q)outf}"
  } > "$fetchf"

  # --- emit: print the merged list filtered to the current tab (0 = All, k =
  # the k-th host, matched on the slug field $3). Fast; reads only $outf.
  {
    print -r -- "#!/bin/sh"
    print -r -- "tab=\$(cat ${(q)tabf} 2>/dev/null || echo 0)"
    print -r -- "case \"\$tab\" in"
    print -r -- "0) cat ${(q)outf} 2>/dev/null ;;"
    for i in {1..$n}; do
      print -r -- "$i) awk -F'\\t' -v s=${(q)slugs[i]} '\$3==s' ${(q)outf} 2>/dev/null ;;"
    done
    print -r -- "*) cat ${(q)outf} 2>/dev/null ;;"
    print -r -- "esac"
  } > "$emitf"

  # --- header: the tab bar (active entry reverse-video) plus the key hints,
  # rendered per tab value so transform-header can repaint it on Tab. One case
  # arm per possible active index; bars are pre-composed here and single-quoted.
  local hint='Enter attach · Tab/S-Tab host · ctrl-n new · ctrl-r refresh · → preview · Esc'
  {
    print -r -- "#!/bin/sh"
    print -r -- "tab=\$(cat ${(q)tabf} 2>/dev/null || echo 0)"
    print -r -- "case \"\$tab\" in"
    local a
    for a in {0..$n}; do
      local -a parts=()
      if (( a == 0 )); then parts+=("${REV}${BOLD} All ${RST}"); else parts+=("${DIM}All${RST}"); fi
      for i in {1..$n}; do
        if (( a == i )); then
          parts+=("${REV}${BOLD} ${hosts[i]} ${RST}")
        else
          parts+=("${palette[$(( (i-1) % ${#palette} + 1 ))]}${hosts[i]}${RST}")
        fi
      done
      local bar="${(j:  :)parts}"
      print -r -- "$a) printf '%s\\n%s\\n' ${(qq)bar} ${(qq)hint} ;;"
    done
    print -r -- "*) printf '%s\\n' ${(qq)hint} ;;"
    print -r -- "esac"
  } > "$hdrf"

  # --- tab advance: bump $tabf forward ("next") or back ("prev") mod (n+1).
  {
    print -r -- "#!/bin/sh"
    print -r -- "m=$(( n + 1 )); t=\$(cat ${(q)tabf} 2>/dev/null || echo 0)"
    print -r -- "case \"\$1\" in"
    print -r -- "prev) echo \$(( (t + m - 1) % m )) > ${(q)tabf} ;;"
    print -r -- "*)    echo \$(( (t + 1) % m )) > ${(q)tabf} ;;"
    print -r -- "esac"
  } > "$advf"

  # Tear down every master + all temp files on any exit path. Same INT-flag
  # idiom as the single-host path: the trap flips a flag the spinner polls.
  local _rtmux_int=0
  local cleanup="rm -f ${(q)scriptf} ${(q)outf} ${(q)outf}.tmp ${(q)errf} ${(q)rcf} ${(q)failf} ${(q)tabf} ${(q)fetchf} ${(q)emitf} ${(q)hdrf} ${(q)advf}"
  for i in {1..$n}; do
    cleanup+=" ${(q)outf}.h.${(q)slugs[i]}"
    cleanup+="; ssh -O exit -o ControlPath=${(q)cpbase}-${(q)slugs[i]} ${(q)hosts[i]} 2>/dev/null"
  done
  trap "$cleanup" EXIT
  trap '_rtmux_int=1' INT

  # Open every master in parallel and pull the first listing, behind the spinner.
  # A host that fails to connect logs its name to $failf and simply contributes
  # no rows. The job writes its exit code to $rcf last (spinner completion).
  {
    for i in {1..$n}; do
      ( ssh -o ControlMaster=auto -o ControlPath="${cpbase}-${slugs[i]}" \
            -o ControlPersist=30 -o ConnectTimeout=10 -o LogLevel=ERROR \
            "${hosts[i]}" true 2>>"$errf" || print -r -- "${hosts[i]}" >> "$failf" ) &
    done
    wait
    sh "$fetchf"
    print -r -- $? >"$rcf"
  } &!
  local jpid=$!
  _rtmux_spin "$rcf" "connecting to ${hostlist}…"
  if (( _rtmux_int )); then
    kill $jpid 2>/dev/null
    echo "rtmux: cancelled" >&2
    return 130
  fi

  # $failf only exists if a host failed to connect; the $(<file) form ignores a
  # 2>/dev/null redirect, so guard on existence rather than suppressing.
  local data failed=""
  data="$([[ -f "$outf" ]] && <"$outf")"
  [[ -f "$failf" ]] && failed="$(<"$failf")"
  if [[ -z "$data" ]]; then
    if [[ -n "$failed" ]]; then
      echo "rtmux: could not connect to: ${failed//$'\n'/, }" >&2
      [[ -s "$errf" ]] && print -r -- "$(<"$errf")" >&2
    else
      echo "rtmux: no tmux sessions on any of: ${hostlist}" >&2
    fi
    return 1
  fi
  # Note any partial failures but keep going (we still have sessions to show).
  [[ -n "$failed" ]] && echo "rtmux: (skipped unreachable: ${failed//$'\n'/, })" >&2

  # Preview + attach target the slug ({3}) and host ({4}) carried on the row, so
  # they work regardless of which tab is active. ControlPath reuses that host's
  # master; capture-pane keys off the session name ({2}).
  local preview="ssh -o ControlPath=${(q)cpbase}-{3} {4} tmux capture-pane -ep -t {2}"
  local emit_cmd="sh ${(q)emitf}" fetch_cmd="sh ${(q)fetchf}" hdr_cmd="sh ${(q)hdrf}"

  # Preview-window syntax + show/hide actions gated the same way as single-host.
  local pw; local -a prevbinds
  if (( fzf_minor >= 38 )); then
    prevbinds=(--bind 'right:show-preview' --bind 'left:hide-preview')
    pw='hidden,down,55%,wrap'
  else
    prevbinds=(--bind 'right:toggle-preview' --bind 'left:toggle-preview')
    pw='down:55%:wrap:hidden'
  fi

  # Bindings: ctrl-r refetches; Tab/Shift-Tab advance the tab, re-emit the
  # filtered list, and repaint the header (transform-header, 0.38+); the load
  # event self-perpetuates the poll loop (0.36+). Below 0.38 there are no tabs —
  # just the static merged list.
  local -a binds=(--bind "ctrl-r:reload($fetch_cmd; $emit_cmd)")
  if (( tabs )); then
    binds+=(--bind "tab:execute-silent(sh ${(q)advf} next)+reload($emit_cmd)+transform-header($hdr_cmd)")
    binds+=(--bind "btab:execute-silent(sh ${(q)advf} prev)+reload($emit_cmd)+transform-header($hdr_cmd)")
  fi
  if (( watch && fzf_minor >= 36 )); then
    binds+=(--bind "load:reload(sleep $interval; $fetch_cmd; $emit_cmd)")
  fi

  local -a idnth=(); (( fzf_minor >= 71 )) && idnth=(--id-nth=2,4)
  local header0; header0="$(sh "$hdrf")"   # tab 0 (All) header
  (( tabs )) || header0="${header0}"$'\n'"(host tabs need fzf≥0.38 — showing all)"

  local fzf_out
  fzf_out="$(sh "$emitf" | fzf \
      --delimiter=$'\t' --with-nth=1 "${idnth[@]}" \
      --ansi --no-sort --reverse --height=90% \
      --expect=ctrl-n \
      --header="$header0" \
      --preview="$preview" \
      --preview-window="$pw" \
      "${prevbinds[@]}" \
      "${binds[@]}")"

  local -a fzf_lines=("${(@f)fzf_out}")
  local key="${fzf_lines[1]}" selected="${fzf_lines[2]}"
  # Split the row on its literal tabs — the `p` flag makes `\t` a tab inside the
  # (s:…:) delimiter (a bare $'\t' there is taken as four literal characters).
  local -a f=("${(@ps:\t:)selected}")
  local session="${f[2]}" rslug="${f[3]}" rhost="${f[4]}"

  if [[ "$key" == ctrl-n ]]; then
    # Start on the selected row's host (fall back to the first remote).
    local host="${rhost:-${hosts[1]}}"
    local -a cm=(-o ControlPath="${cpbase}-${rslug:-${slugs[1]}}")
    _rtmux_new_session "start a new session on $host?"
    return $?
  fi

  [[ -z "$selected" || -z "$session" ]] && return 0

  local -a cm=(-o ControlPath="${cpbase}-${rslug}")
  local -a attach=(tmux attach -t "$session")
  (( detach )) && attach=(tmux attach -d -t "$session")
  ssh -t "${cm[@]}" "$rhost" "${attach[@]}"
  return $?
}

rtmux() {
  emulate -L zsh
  setopt local_options local_traps no_monitor no_notify

  local detach=0 all=0 newsess=0
  # Auto-refresh (live polling) defaults; override via env or flags.
  local watch="${RTMUX_WATCH:-1}"                 # 1 = poll, 0 = off
  local interval="${RTMUX_WATCH_INTERVAL:-1}"     # seconds between polls
  # Options may come before or after the host args (`rtmux dev -n` reads more
  # naturally than `rtmux -n dev`), so parse the whole argv, collecting
  # non-option words as positionals. `--` ends option parsing as usual.
  local -a pos=()
  while (( $# )); do
    case "$1" in
      -d|--detach) detach=1 ;;
      -a|--all) all=1 ;;
      -n|--new) newsess=1 ;;
      -i|--interval) interval="$2"; shift ;;
      -W|--no-watch) watch=0 ;;
      -h|--help)
        cat <<'EOF'
usage: rtmux [-d] [-n] [-i SECS] [-W] [host[:dir] …] [name]

  Pick a remote tmux session in fzf and ssh-attach to it. Rows show the
  attached marker (●/○), the project (the pane's cwd basename), the main
  process, and — for Claude Code sessions — the conversation title, with the
  "claude" tag coloured by status (yellow=busy, cyan=idle, dim=shell). The
  list auto-refreshes so all of this stays current while the picker is open.

    rtmux <host>       host = ssh alias or user@host (or set $RTMUX_HOST)
    rtmux <h1> <h2> …  query several remotes; merged picker with a per-host
                       tab bar (or set RTMUX_HOSTS="prod dev" in the repo-root .env)
    rtmux <host>:<dir> attach to the session rooted in <dir> on <host>
                       (e.g. rtmux dev:~/code/project). Several sessions
                       rooted there → a picker over just those (Enter attach,
                       ctrl-n new, Esc cancel). None → start one (named after
                       the dir) behind two default-yes prompts — start
                       there? (n cancels), launch Claude Code? ~ / relative
                       paths resolve against the remote home. Tab completes
                       the remote directories. With -n a fresh session is
                       started even if one is rooted there.
    -n, --new          skip the picker: start a new session on the host right
                       away. `rtmux <host> -n` prompts for a name (Enter =
                       auto-named); `rtmux <host> -n <name>` starts <name>
                       directly. The ~/code/<name> project offers still apply.
    -a, --all          fan out across the whole $RTMUX_HOSTS pool, ignoring
                       any $RTMUX_HOST default
    -d, --detach       attach with -d (detach other clients first)
    -i, --interval     poll interval in seconds (default 1; fractional ok)
    -W, --no-watch     disable auto-refresh (use ctrl-r to refresh manually)

  Picker keys: Enter attach · ctrl-n new session · ctrl-r refresh now
               · → live pane preview · ← hide · Esc cancel
  Multi-host:  Tab / Shift-Tab cycle the host tabs (All / per-host)
EOF
        return 0 ;;
      --) shift; pos+=("$@"); break ;;
      -*) echo "rtmux: unknown option $1" >&2; return 2 ;;
      *) pos+=("$1") ;;
    esac
    shift
  done
  if [[ -n "$interval" && ! "$interval" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "rtmux: --interval must be a number (got '$interval')" >&2
    return 2
  fi

  # -n/--new: the second positional (if any) is the new session's name, not a
  # second host — `rtmux dev -n myproj`. Peel it off before host
  # resolution so the host rules below see only the host.
  local newname=""
  if (( newsess )); then
    if (( all )); then
      echo "rtmux: -n/--new and -a/--all don't combine" >&2
      return 2
    fi
    if (( ${#pos} > 2 )); then
      echo "rtmux: -n/--new takes at most a host and a session name" >&2
      return 2
    fi
    if (( ${#pos} == 2 )); then
      newname="${pos[2]}"
      pos=("${pos[1]}")
    fi
  fi

  # Host resolution. Explicit args always win; otherwise a set RTMUX_HOST acts
  # as the *default* single remote, and only when no default exists do we fan
  # out across the whole RTMUX_HOSTS pool. `--all` forces the fan-out even when
  # a default is set. Values may come from the shell env or the repo-root .env (the
  # latter sourced function-locally so it never leaks into the interactive
  # shell). Precedence, highest first:
  #   1. explicit argument(s)                     — one or more remotes
  #   2. --all  → the RTMUX_HOSTS pool (multi)
  #   3. RTMUX_HOST (default single remote)       → single-host picker
  #   4. RTMUX_HOSTS pool                          → multi-host picker
  # Any resolution yielding 2+ hosts routes to the merged, tabbed picker.
  local env_host="$RTMUX_HOST" env_hosts="$RTMUX_HOSTS"
  local RTMUX_HOST="" RTMUX_HOSTS=""
  # Repo-root .env — rtmux.zsh sits in the repo root, so it's alongside this
  # file; RTMUX_ENV_FILE overrides (used by the test suite to inject a fixture).
  source "${RTMUX_ENV_FILE:-${${(%):-%x}:A:h}/.env}" 2>/dev/null
  local def_host="${env_host:-$RTMUX_HOST}"          # default single remote
  local pool="${env_hosts:-$RTMUX_HOSTS}"            # full fan-out pool
  local -a hosts
  if (( ${#pos} )); then
    hosts=("${pos[@]}")
  elif (( all )); then
    hosts=(${=pool})
    if (( ${#hosts} == 0 )); then
      echo "rtmux: --all needs \$RTMUX_HOSTS set (see .env.example in the repo root)" >&2
      return 2
    fi
  elif [[ -n "$def_host" ]]; then
    hosts=("$def_host")
  elif [[ -n "$pool" ]]; then
    hosts=(${=pool})
  fi
  if (( ${#hosts} == 0 )); then
    echo "rtmux: no host given — pass one or more, or set \$RTMUX_HOST (default remote)" >&2
    echo "       and/or \$RTMUX_HOSTS (fan-out pool) in the repo-root .env. rtmux -h for help." >&2
    return 2
  fi

  # <host>:<dir> target — `rtmux dev:~/code/project` attaches to the session
  # rooted in that remote directory, or starts one there. Single host only.
  # A bare `host:` targets the remote home. (An IPv6-literal host would
  # false-positive on the colon — use an ssh alias for those.)
  local hostdir=""
  if (( ${#hosts} == 1 )) && [[ "${hosts[1]}" == *:* ]]; then
    hostdir="${hosts[1]#*:}"
    hosts[1]="${hosts[1]%%:*}"
    [[ -z "$hostdir" ]] && hostdir="~"
    if [[ -z "${hosts[1]}" ]]; then
      echo "rtmux: empty host in host:dir target" >&2
      return 2
    fi
  elif [[ "${hosts[*]}" == *:* ]]; then
    echo "rtmux: a host:dir target needs a single host (got: ${hosts[*]})" >&2
    return 2
  fi

  # -n/--new needs exactly one target — a merged fan-out has no single host to
  # start the session on (an explicit `rtmux h1 h2 -n` never gets here: the
  # second positional is taken as the session name above).
  if (( newsess && ${#hosts} > 1 )); then
    echo "rtmux: -n/--new needs a single host (resolved: ${hosts[*]})" >&2
    return 2
  fi

  # Two or more remotes → merged, tabbed multi-host picker (own helper).
  if (( ${#hosts} > 1 )); then
    _rtmux_multi "${hosts[@]}"
    return $?
  fi

  local host="${hosts[1]}"

  # Direct paths that skip the listing + picker (fzf not needed): the -n/--new
  # new-session flow, and the <host>:<dir> attach-or-create flow. Both open
  # the master behind the spinner, then hand off to their helper.
  if (( newsess )) || [[ -n "$hostdir" ]]; then
    local cp="${TMPDIR:-/tmp}/rtmux-cm-$$-$RANDOM"
    local -a cm=(-o ControlPath="$cp")
    local rcf="${TMPDIR:-/tmp}/rtmux-rc-$$-$RANDOM"
    local errf="${rcf}.err"
    local _rtmux_int=0
    trap "ssh -O exit ${(q)cm[1]} ${(q)cm[2]} ${(q)host} 2>/dev/null; rm -f ${(q)rcf} ${(q)errf}" EXIT
    trap '_rtmux_int=1' INT
    {
      ssh -o ControlMaster=auto "${cm[@]}" -o ControlPersist=30 \
          -o ConnectTimeout=10 -o LogLevel=ERROR "$host" true 2>"$errf"
      print -r -- $? >"$rcf"
    } &!
    local jpid=$!
    _rtmux_spin "$rcf" "connecting to $host…"
    if (( _rtmux_int )); then
      kill $jpid 2>/dev/null
      echo "rtmux: cancelled" >&2
      return 130
    fi
    if [[ "$(<"$rcf")" != 0 ]]; then
      echo "rtmux: could not connect to $host" >&2
      [[ -s "$errf" ]] && print -r -- "$(<"$errf")" >&2
      return 1
    fi
    if [[ -n "$hostdir" ]]; then
      _rtmux_dir_session "$hostdir" "$newsess" "$newname"
    else
      _rtmux_new_session "start a new session on $host?" "$newname"
    fi
    return $?
  fi

  if ! command -v fzf >/dev/null 2>&1; then
    echo "rtmux: fzf is required locally (brew install fzf)" >&2
    return 1
  fi

  # Multiplexed SSH connection (one master reused for listing, previews, attach)
  # plus a temp copy of the remote inspector that fzf's reload binds can re-run
  # (their child shell is plain `sh`, where a heredstring isn't available).
  local cp="${TMPDIR:-/tmp}/rtmux-cm-$$-$RANDOM"
  local -a cm=(-o ControlPath="$cp")
  local scriptf="${TMPDIR:-/tmp}/rtmux-py-$$-$RANDOM"
  print -r -- "$_RTMUX_REMOTE_PY" > "$scriptf"
  local outf="${TMPDIR:-/tmp}/rtmux-out-$$-$RANDOM"
  local errf="${outf}.err" rcf="${outf}.rc"

  # Tear down the master + all temp files on any exit path (return / Ctrl-C).
  # local_traps keeps both traps scoped to this function. The INT trap only
  # flips a flag the connect-spinner polls — cleanup runs via the EXIT trap on
  # the subsequent return — so Ctrl-C during a hung connect returns promptly
  # instead of waiting out ConnectTimeout (the async connect job ignores SIGINT).
  local _rtmux_int=0
  trap "ssh -O exit ${(q)cm[1]} ${(q)cm[2]} ${(q)host} 2>/dev/null; rm -f ${(q)scriptf} ${(q)outf} ${(q)errf} ${(q)rcf}" EXIT
  trap '_rtmux_int=1' INT

  # The list command — used for the initial paint, ctrl-r, and the poll loop.
  local listcmd="ssh ${(q)cm[1]} ${(q)cm[2]} ${(q)host} python3 - < ${(q)scriptf} 2>/dev/null"

  # Open the master + pull the first listing in the background, behind a spinner.
  # The master's stderr (which carries the server's one-time login banner) goes
  # to $errf and is only resurfaced on failure. The job writes its exit code to
  # $rcf last — that file's appearance is the spinner's completion signal.
  # `&!` disowns the job at creation so that, on a Ctrl-C cancel below, the kill
  # is silent — a still-tracked job would print a "[n] terminated" line at the
  # next prompt. Communication is via files, not job control, so disowning is free.
  {
    if ssh -o ControlMaster=auto "${cm[@]}" -o ControlPersist=30 \
           -o ConnectTimeout=10 -o LogLevel=ERROR "$host" true 2>"$errf"; then
      eval "$listcmd" >"$outf" 2>>"$errf"
      print -r -- $? >"$rcf"
    else
      print -r -- 10 >"$rcf"
    fi
  } &!
  local jpid=$!
  _rtmux_spin "$rcf" "connecting to $host…"
  if (( _rtmux_int )); then
    kill $jpid 2>/dev/null      # stop the hung connect (disowned → silent); orphaned ssh times out harmlessly
    echo "rtmux: cancelled" >&2
    return 130                  # EXIT trap tears down the master + temp files
  fi
  # Spinner only returns once the job wrote $rcf, so the listing is complete.
  local rc; rc="$(<"$rcf")"

  if [[ "$rc" == 10 ]]; then
    echo "rtmux: could not connect to $host" >&2
    [[ -s "$errf" ]] && print -r -- "$(<"$errf")" >&2
    return 1
  fi

  local tsv; tsv="$(<"$outf")"
  if [[ -z "$tsv" ]]; then
    # No sessions to pick. Offer to start one over the same master channel
    # instead of just bailing. Only prompt on a TTY; piped/non-interactive
    # callers keep the old quiet behaviour.
    if [[ -t 0 && -t 2 ]]; then
      _rtmux_new_session "no tmux sessions on $host — start one?"
      return $?
    fi
    echo "rtmux: no tmux sessions on $host" >&2
    return 0
  fi

  local preview="ssh ${(q)cm[1]} ${(q)cm[2]} ${(q)host} tmux capture-pane -ep -t {2}"
  local header='Enter attach · ctrl-n new · ctrl-r refresh · → preview · ← hide · Esc cancel'

  # fzf feature compatibility. iSH/Alpine ships an old fzf (0.27 seen in the
  # wild), so detect the minor version once and degrade gracefully instead of
  # aborting on an unknown option/action/event. Thresholds verified against
  # fzf's CHANGELOG:
  #   - `load` event (drives auto-refresh)       -> fzf 0.36+  (else ctrl-r only)
  #   - show-preview / hide-preview actions       -> fzf 0.38+  (else toggle-preview)
  #   - comma-separated --preview-window syntax   -> present by 0.38 (else colon form)
  #   - --id-nth (stable cursor across reloads)   -> fzf 0.71+  (else omit)
  # fzf has been 0.x for its whole life, so the minor number is the version.
  local fzf_ver="${$(fzf --version 2>/dev/null)%% *}"   # "0.27 (devel)" -> "0.27"
  local fzf_minor="${fzf_ver#*.}"; fzf_minor="${fzf_minor%%.*}"
  [[ "$fzf_minor" == <-> ]] || fzf_minor=0              # parse failed -> assume ancient

  # Reload binds: ctrl-r refreshes immediately; with --watch the `load` event
  # (fired after every list completes) schedules the next `reload(sleep N; …)`,
  # giving a self-perpetuating poll loop. The `load` event needs fzf 0.36+.
  local -a watchbinds=(--bind "ctrl-r:reload($listcmd)")
  if (( watch && fzf_minor >= 36 )); then
    watchbinds+=(--bind "load:reload(sleep $interval; $listcmd)")
    header="$header   (live, every ${interval}s)"
  elif (( watch )); then
    header="$header   (auto-refresh needs fzf≥0.36 — press ctrl-r)"
  fi

  local -a idnth=()
  (( fzf_minor >= 71 )) && idnth=(--id-nth=2)

  # show-preview/hide-preview actions and the comma-form --preview-window are
  # both present from fzf 0.38; older fzf gets toggle-preview (both arrows
  # toggle) + the original colon-delimited preview-window syntax.
  local pw; local -a prevbinds
  if (( fzf_minor >= 38 )); then
    prevbinds=(--bind 'right:show-preview' --bind 'left:hide-preview')
    pw='hidden,down,55%,wrap'
  else
    prevbinds=(--bind 'right:toggle-preview' --bind 'left:toggle-preview')
    pw='down:55%:wrap:hidden'
  fi

  # --expect=ctrl-n lets the picker complete on ctrl-n as well as Enter; fzf
  # then prints the pressed key as its first output line (empty for Enter) and
  # the selection on the second. ctrl-n → start a new session (this shadows
  # fzf's default ctrl-n=down, but the arrow keys still navigate). --expect
  # predates the ancient fzf 0.27 on iSH, so no version gate is needed.
  local fzf_out
  fzf_out="$(printf '%s\n' "$tsv" | fzf \
      --delimiter=$'\t' --with-nth=1 "${idnth[@]}" \
      --ansi --no-sort --reverse --height=90% \
      --expect=ctrl-n \
      --header="$host  —  $header" \
      --preview="$preview" \
      --preview-window="$pw" \
      "${prevbinds[@]}" \
      "${watchbinds[@]}")"

  local -a fzf_lines=("${(@f)fzf_out}")
  local key="${fzf_lines[1]}" selected="${fzf_lines[2]}"

  if [[ "$key" == ctrl-n ]]; then
    _rtmux_new_session "start a new session on $host?"
    return $?
  fi

  if [[ -z "$selected" ]]; then
    return 0
  fi

  local session="${selected##*$'\t'}"
  local -a attach=(tmux attach -t "$session")
  (( detach )) && attach=(tmux attach -d -t "$session")

  # -t for an interactive pty; reuses the master channel. Cleanup (master +
  # temp script) runs via the EXIT trap when the function returns.
  ssh -t "${cm[@]}" "$host" "${attach[@]}"
  return $?
}

# --- tab completion ---------------------------------------------------------
# `rtmux <Tab>` completes hosts: the RTMUX_HOST/RTMUX_HOSTS pool (shell env or
# the repo-root .env, sourced in a subshell so nothing leaks) plus non-wildcard
# Host aliases from ~/.ssh/config. Hosts complete with *no* trailing space so
# the host:dir form is just a `:` away (type a space yourself for the plain
# forms). `host:<Tab>` completes *remote* directories: one ssh round-trip
# running $_RTMUX_LS_SH (BatchMode + 3s timeout — never prompts for a
# password; instant when your ssh config multiplexes connections). Hidden
# directories appear once the typed basename starts with a dot.
_rtmux_complete() {
  emulate -L zsh
  local cur="${words[CURRENT]}"

  if [[ "$cur" == -* ]]; then
    compadd -- -d --detach -n --new -a --all -i --interval -W --no-watch -h --help
    return
  fi

  if [[ "$cur" == *:* ]]; then
    # Remote directory completion for host:dir.
    local rhost="${cur%%:*}" rpath="${cur#*:}"
    [[ -z "$rhost" ]] && return 1
    local dirpart=""
    [[ "$rpath" == */* ]] && dirpart="${rpath%/*}/"
    local remdir="${dirpart:-~}"                 # empty → remote home
    local lsf="-1p"
    [[ "${rpath##*/}" == .* ]] && lsf="-1Ap"
    local -a ents
    ents=("${(@f)$(print -r -- "$_RTMUX_LS_SH" | command ssh \
        -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR \
        "$rhost" sh -s -- "${(q)remdir}" "$lsf" 2>/dev/null)}")
    ents=("${(@M)ents:#*/}")                     # dirs only (ls -p suffix)
    ents=("${(@)ents%/}")
    (( ${#ents} )) || return 1
    compset -P '*:'                              # match on the path part…
    compset -P '*/'                              # …after the last slash
    compadd -q -S/ -- "${(@)ents}"
    return
  fi

  # Hosts. Pool first (env beats .env, mirroring rtmux()'s resolution), then
  # ssh-config aliases; -U on the array dedupes while keeping first-seen order.
  local pool="${RTMUX_HOSTS-} ${RTMUX_HOST-}"
  if [[ -z "${pool// /}" ]]; then
    local envf="${RTMUX_ENV_FILE:-${${(%):-%x}:A:h}/.env}"
    pool="$( (source "$envf" >/dev/null 2>&1; print -r -- "${RTMUX_HOSTS-} ${RTMUX_HOST-}") )"
  fi
  local -aU hosts
  hosts=(${=pool})
  hosts+=(${(f)"$(awk 'tolower($1)=="host" { for (i=2; i<=NF; i++) if ($i !~ /[*?!]/) print $i }' \
                  ~/.ssh/config 2>/dev/null)"})
  (( ${#hosts} )) || return 1
  compadd -S '' -- "${(@)hosts}"
}

# Register with compsys. If rtmux.zsh is sourced before compinit has run,
# defer the compdef to the first prompt (then unhook) instead of dropping it.
if (( $+functions[compdef] )); then
  compdef _rtmux_complete rtmux
else
  _rtmux_compdef_later() {
    (( $+functions[compdef] )) && compdef _rtmux_complete rtmux
    add-zsh-hook -d precmd _rtmux_compdef_later
    unfunction _rtmux_compdef_later 2>/dev/null
  }
  autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _rtmux_compdef_later
fi
