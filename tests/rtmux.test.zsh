#!/usr/bin/env zsh
# Regression tests for rtmux.zsh — focused on the multi-remote picker.
#
# No network, ssh, or tmux is required: `ssh` and `fzf` are stubbed on $PATH so
# the whole flow (per-host fetch → merge → tab filter → attach/ctrl-n routing)
# runs deterministically. A couple of tmux-backed checks of the remote Python
# inspector run only when a real `tmux` is available, and are skipped otherwise.
#
#   Run:  zsh rtmux/tests/rtmux.test.zsh   (from the repo root)
#   Exit: 0 all passed · 1 one or more failed · 2 setup error
#
# Why this exists: rtmux generates small `sh` helper scripts on the fly (ANSI
# passed through `sh`, awk field filters, tab-split flags, mod arithmetic) that
# are easy to break in ways that don't show up until you're staring at a live
# picker. These lock the behaviour down.

emulate -L zsh
setopt no_unset warn_create_global

SCRIPT_DIR=${0:A:h}
RTMUX="$SCRIPT_DIR/../rtmux.zsh"
[[ -r "$RTMUX" ]] || { print -u2 "rtmux.test: cannot read $RTMUX"; exit 2 }

# ---------------------------------------------------------------------------
# Scratch sandbox + stubbed PATH.
# ---------------------------------------------------------------------------
typeset WORK; WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT
typeset -gx TMPDIR="$WORK/tmp";      mkdir -p "$TMPDIR"
typeset MOCK="$WORK/bin";            mkdir -p "$MOCK"
typeset -gx MOCK_ASSERT="$WORK/assert"; mkdir -p "$MOCK_ASSERT"
typeset -gx PATH="$MOCK:$PATH"
# Deterministic behaviour knobs the stubbed fzf reads.
typeset -gx FZF_MODE=select FZF_KEY='' FZF_ROW=1

# ---------------------------------------------------------------------------
# Tiny assertion framework.
# ---------------------------------------------------------------------------
integer PASS=0 FAIL=0
ok()  { (( PASS++ )); print -r -- "  ok   - $1" }
bad() { (( FAIL++ )); print -r -- "  FAIL - $1"; [[ -n "${2-}" ]] && print -r -- "         $2" }
is()       { [[ "$2" == "$3" ]]   && ok "$1" || bad "$1" "want [$3] got [$2]" }
has()      { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "[$2] missing [$3]" }
hasnt()    { [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "[$2] should not contain [$3]" }
section()  { print -r -- "» $1" }

# ---------------------------------------------------------------------------
# Stub: ssh. Classifies the invocation by scanning argv and logs the ones the
# tests assert on. Fetch calls synthesise this host's rows from the argv the
# real remote Python would have received (2-field single / 4-field multi).
# ---------------------------------------------------------------------------
cat > "$MOCK/ssh" <<'SSH'
#!/usr/bin/env zsh
args=("$@"); last="${args[-1]}"
[[ " ${args[*]} " == *" -O exit "* ]] && exit 0            # master teardown
[[ " ${args[*]} " == *" test -d "* ]] && exit 1            # no ~/code/<name>
if [[ " ${args[*]} " == *" sh -s -- "* ]]; then            # host:dir query
  cat > /dev/null                                          # drain the script
  print -r -- "DIRQ ${args[*]}" >> "$MOCK_ASSERT/dirq.log"
  case "${RTMUX_DIRQ_MODE:-nomatch}" in
    missing) exit 3 ;;
    match)   printf 'DIR\t/home/u/code/proj1\nSESS\tproj1work\nMATCH\tproj1work\n' ;;
    collide) printf 'DIR\t/home/u/code/proj1\nSESS\tproj1\nSESS\tproj1-2\n' ;;
    multi)   printf 'DIR\t/home/u/code/proj1\nSESS\tdemo\nSESS\tdemo-2\nSESS\tother\nMATCH\tdemo-2\nMATCH\tdemo\n' ;;
    *)       printf 'DIR\t/home/u/code/proj1\nSESS\tother\n' ;;
  esac
  exit 0
fi
if [[ " ${args[*]} " == *" new-session"* ]]; then
  print -r -- "NEW ${args[*]}" >> "$MOCK_ASSERT/new.log"; exit 0
fi
if [[ "$last" == true ]]; then                             # master open
  # host is the arg just before the trailing `true`
  print -r -- "${args[-2]}" >> "$MOCK_ASSERT/open.log"; exit 0
fi
if [[ " ${args[*]} " == *" python3 "* ]]; then             # session listing
  local i hc='' sl='' hn=''
  for (( i=1; i<=${#args}; i++ )); do
    if [[ "${args[i]}" == python3 && "${args[i+1]}" == - ]]; then
      hc="${args[i+2]-}"; sl="${args[i+3]-}"; hn="${args[i+4]-}"; break
    fi
  done
  if [[ -z "$hn" ]]; then                                  # single-host: 2 fields
    printf '\xe2\x97\x8b ping\t%s\n' "sess1"
    printf '\xe2\x97\x8f 0\t%s\n'    "0"
  else                                                     # multi-host: 4 fields
    printf '%s\xe2\x97\x8b ping\t%s\t%s\t%s\n' "$hc" "work-$hn" "$sl" "$hn"
    printf '%s\xe2\x97\x8f 0\t%s\t%s\t%s\n'    "$hc" "0"        "$sl" "$hn"
  fi
  exit 0
fi
if [[ " ${args[*]} " == *" attach "* ]]; then
  print -r -- "ATTACH ${args[*]}" >> "$MOCK_ASSERT/attach.log"; exit 0
fi
exit 0
SSH
chmod +x "$MOCK/ssh"

# ---------------------------------------------------------------------------
# Stub: fzf. Two modes:
#   select  — exercise the generated emit/hdr/adv scripts (capturing their
#             output for assertions), then emit FZF_KEY + the FZF_ROW-th row.
#   resolve — just drain stdin and return an empty selection (used by the
#             host-resolution tests, which only care which hosts were queried).
# The --version probe must never read stdin.
# ---------------------------------------------------------------------------
cat > "$MOCK/fzf" <<'FZF'
#!/usr/bin/env zsh
[[ " $* " == *" --version "* ]] && { print -r -- "0.74.0 (mock)"; exit 0 }
A="$MOCK_ASSERT"; cat > "$A/picker_input"
if [[ "$FZF_MODE" == select ]]; then
  # The generated helper files only exist in the multi-host picker; the
  # single-host and host:dir pickers have none — just emit key + row then.
  emitf=(${TMPDIR}/rtmux-out-*.emit(N)); emitf="${emitf[1]-}"
  if [[ -n "$emitf" ]]; then
    advf=(${TMPDIR}/rtmux-out-*.adv(N));   advf="${advf[1]}"
    hdrf=(${TMPDIR}/rtmux-out-*.hdr(N));   hdrf="${hdrf[1]}"
    tabf=(${TMPDIR}/rtmux-out-*.tab(N));   tabf="${tabf[1]}"
    print -r -- 0 > "$tabf"; sh "$emitf" > "$A/emit_tab0"; sh "$hdrf" > "$A/hdr_tab0"
    sh "$advf" next; sh "$emitf" > "$A/emit_tab1"; sh "$hdrf" > "$A/hdr_tab1"
    sh "$advf" next; sh "$emitf" > "$A/emit_tab2"
    sh "$advf" next; print -r -- "$(<"$tabf")" > "$A/wrap"   # wrap n+1 -> 0
    print -r -- 0 > "$tabf"
  fi
  print -r -- "$FZF_KEY"
  sed -n "${FZF_ROW}p" "$A/picker_input"
fi
exit 0
FZF
chmod +x "$MOCK/fzf"

# ---------------------------------------------------------------------------
# Load the code under test. Replace the connect-spinner with a headless waiter
# (the real one only spins on a TTY and returns immediately otherwise, which
# would race the background fetch in a non-interactive test).
# ---------------------------------------------------------------------------
source "$RTMUX"
_rtmux_spin() {
  local rcf="$1" n=0
  while [[ ! -e "$rcf" ]]; do sleep 0.02; (( ++n > 500 )) && break; done
  return 0
}

reset_logs() {
  setopt local_options null_glob   # empty globs vanish instead of erroring
  rm -f "$MOCK_ASSERT"/*.log "$MOCK_ASSERT"/emit_tab* \
        "$MOCK_ASSERT"/hdr_tab* "$MOCK_ASSERT"/wrap "$MOCK_ASSERT"/picker_input
  return 0
}

# Run the real multi-host picker with the ambient detach/watch/interval locals
# it expects from rtmux() (watch=0 avoids scheduling the poll loop).
call_multi() { local detach=0 watch=0 interval=1; _rtmux_multi "$@" }

# ===========================================================================
section "multi-host: merge, tab filter, header, attach"
# ===========================================================================
reset_logs
FZF_MODE=select FZF_KEY='' FZF_ROW=1
call_multi prod dev
typeset out="$MOCK_ASSERT"

is  "picker merges both hosts (4 rows)" "$(grep -c . $out/picker_input)" 4
has "row carries prod host field"       "$(cut -f4 $out/picker_input | sort -u | tr '\n' ' ')" "prod"
has "row carries dev host field"       "$(cut -f4 $out/picker_input | sort -u | tr '\n' ' ')" "dev"
is  "All tab shows every row"           "$(grep -c . $out/emit_tab0)" 4
is  "tab 1 filters to first host only"  "$(cut -f4 $out/emit_tab1 | sort -u | tr '\n' ' ')" "prod "
is  "tab 2 filters to second host only" "$(cut -f4 $out/emit_tab2 | sort -u | tr '\n' ' ')" "dev "
is  "tab wraps n+1 back to All (0)"     "$(cat $out/wrap)" 0
has "All-tab header highlights All"     "$(cat $out/hdr_tab0)" "All"
has "host-tab header names the host"    "$(cat $out/hdr_tab1)" "prod"

# Enter on row 1 (prod) → attach to prod's session over prod's master.
has "attach targets selected host"      "$(cat $out/attach.log)" " prod tmux attach -t work-prod"
has "attach reuses that host's master"  "$(cat $out/attach.log)" "ControlPath=$TMPDIR/rtmux-cm-"
has "attach master path is per-host"    "$(cat $out/attach.log)" "-prod "

# ===========================================================================
section "multi-host: attach follows the selected row across hosts"
# ===========================================================================
reset_logs
FZF_MODE=select FZF_KEY='' FZF_ROW=3     # row 3 = first dev row
call_multi prod dev
has "row-3 selection attaches to dev"  "$(cat $out/attach.log)" " dev tmux attach -t work-dev"
hasnt "row-3 selection does not hit prod" "$(cat $out/attach.log)" "work-prod"

# ===========================================================================
section "multi-host: ctrl-n starts a session on the selected row's host"
# ===========================================================================
reset_logs
FZF_MODE=select FZF_KEY=ctrl-n FZF_ROW=3   # dev row
call_multi prod dev
has "ctrl-n new-session targets dev"   "$(cat $out/new.log)" " dev tmux new-session"
has "ctrl-n uses dev's master"         "$(cat $out/new.log)" "-dev "

reset_logs
FZF_MODE=select FZF_KEY=ctrl-n FZF_ROW=1   # prod row
call_multi prod dev
has "ctrl-n new-session targets prod"   "$(cat $out/new.log)" " prod tmux new-session"

# ===========================================================================
section "new-session prompt is Ctrl-C-cancellable (returning INT trap)"
# ===========================================================================
# The prompt reads from /dev/tty, so a full Ctrl-C repro needs a pty (verified
# by hand). This static guard stops a regression to a flag-only INT trap, which
# zsh resumes `read` past — leaving the prompt un-cancellable. See the trap in
# _rtmux_new_session.
typeset ns_def; ns_def="$(functions _rtmux_new_session)"
has  "prompt installs an INT trap"                 "$ns_def" "INT"
has  "the INT trap returns (aborts the read)"      "$ns_def" "return 130"
has  "trap is cleared before the live ssh session" "$ns_def" "trap - INT"

# ===========================================================================
section "multi-host: no stray output on stdout (zsh printf -v quirk guard)"
# ===========================================================================
reset_logs
FZF_MODE=select FZF_KEY='' FZF_ROW=1
typeset stray; stray="$(call_multi prod dev 2>/dev/null)"
is "function prints nothing to stdout itself" "$stray" ""

# ===========================================================================
section "host resolution precedence (via rtmux, _rtmux_multi stubbed)"
# ===========================================================================
# Record how rtmux() routed: multi-host → the stub logs the host list; single
# host → the real single path opens exactly one master (logged by the ssh stub).
_orig_multi=$(functions _rtmux_multi)
_rtmux_multi() { print -r -- "MULTI ${(j: :)@}" >> "$MOCK_ASSERT/route.log"; return 0 }

# Controlled env file: RTMUX_ENV_FILE points rtmux()'s .env source at our
# fixture (rtmux resolves the repo-root .env relative to its own file, so a
# fake HOME alone no longer redirects it).
typeset FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME/.zsh"
write_env() { print -r -- "$1" > "$FAKEHOME/.zsh/.env" }

route() {   # route <expected: MULTI a b | SINGLE h> -- <rtmux args...>
  local want="$1"; shift; [[ "$1" == -- ]] && shift
  reset_logs
  ( export HOME="$FAKEHOME" RTMUX_ENV_FILE="$FAKEHOME/.zsh/.env" RTMUX_WATCH=0 FZF_MODE=resolve
    unset RTMUX_HOST RTMUX_HOSTS
    [[ -n "$_ENV_HOST"  ]] && export RTMUX_HOST="$_ENV_HOST"
    [[ -n "$_ENV_HOSTS" ]] && export RTMUX_HOSTS="$_ENV_HOSTS"
    rtmux "$@" ) >/dev/null 2>&1
  local got
  if [[ -s "$MOCK_ASSERT/route.log" ]]; then
    got="$(<"$MOCK_ASSERT/route.log")"
  else
    got="SINGLE $(<"$MOCK_ASSERT/open.log" 2>/dev/null)"
  fi
  is "$want  ← ${_DESC}" "${got//$'\n'/,}" "$want"
}

typeset _ENV_HOST='' _ENV_HOSTS='' _DESC=''

# 1. explicit args win over everything (and pick multi when 2+).
write_env ''; _ENV_HOST='dev' _ENV_HOSTS='a b c' _DESC='args override env (multi)' \
  route "MULTI prod dev" -- prod dev
# 2. a single explicit arg → single path.
_ENV_HOST='dev' _ENV_HOSTS='a b c' _DESC='single arg → single' \
  route "SINGLE prod" -- prod
# 3. bare rtmux with RTMUX_HOST set → that default single host.
_ENV_HOST='dev' _ENV_HOSTS='a b c' _DESC='RTMUX_HOST is the default single' \
  route "SINGLE dev" --
# 4. bare rtmux, no default, RTMUX_HOSTS set → fan out over the pool.
_ENV_HOST='' _ENV_HOSTS='prod dev' _DESC='no default → fan out over pool' \
  route "MULTI prod dev" --
# 5. --all forces the pool even when a default is set.
_ENV_HOST='dev' _ENV_HOSTS='prod dev' _DESC='--all overrides the default' \
  route "MULTI prod dev" -- --all
# 6. .env fixture (not just exported env) is honoured.
write_env 'typeset RTMUX_HOSTS="prod dev"'
_ENV_HOST='' _ENV_HOSTS='' _DESC='.env RTMUX_HOSTS pool' \
  route "MULTI prod dev" --

# restore the real implementation (in case more tests are appended later).
eval "function $_orig_multi"

# ===========================================================================
section "-n/--new: direct new-session path (skips the picker)"
# ===========================================================================
# With a preset name the flow is fully non-interactive (no [Y/n/name] prompt,
# no fzf): connect the master, `test -d ~/code/<name>` (stub says no), then
# `tmux new-session -s <name>` over the master.
reset_logs
( export HOME="$FAKEHOME" RTMUX_WATCH=0
  unset RTMUX_HOST RTMUX_HOSTS
  rtmux dev -n proj1 ) >/dev/null 2>&1
has "named -n creates the session directly" "$(cat $out/new.log 2>/dev/null)" " dev tmux new-session -s proj1"
is  "-n never opens the picker" "$([[ -f $out/picker_input ]] && echo yes || echo no)" no

# Options parse on either side of the host: `rtmux -n dev proj1` ≡ `rtmux dev -n proj1`.
reset_logs
( export HOME="$FAKEHOME" RTMUX_WATCH=0
  unset RTMUX_HOST RTMUX_HOSTS
  rtmux -n dev proj1 ) >/dev/null 2>&1
has "options may precede the host too" "$(cat $out/new.log 2>/dev/null)" " dev tmux new-session -s proj1"

# Guard rails: -n has no meaning across a fan-out.
write_env 'typeset RTMUX_HOSTS="prod dev"'
typeset nerr
nerr="$( ( export HOME="$FAKEHOME" RTMUX_ENV_FILE="$FAKEHOME/.zsh/.env"; unset RTMUX_HOST RTMUX_HOSTS; rtmux -n ) 2>&1 )"
has "-n over a multi-host pool is rejected" "$nerr" "single host"
nerr="$( ( export HOME="$FAKEHOME" RTMUX_ENV_FILE="$FAKEHOME/.zsh/.env"; unset RTMUX_HOST RTMUX_HOSTS; rtmux -n -a dev ) 2>&1 )"
has "-n and --all don't combine" "$nerr" "don't combine"

# ===========================================================================
section "host:dir target — attach to / create a session rooted in a remote dir"
# ===========================================================================
# Off a TTY the create-dir and Claude prompts are skipped, so every flow here
# is fully non-interactive. The ssh stub answers the `sh -s --` dir query per
# $RTMUX_DIRQ_MODE (match / nomatch / collide / missing).
dirsess() {   # dirsess <mode> <rtmux args...>
  local mode="$1"; shift
  reset_logs
  ( export RTMUX_DIRQ_MODE="$mode" RTMUX_WATCH=0
    unset RTMUX_HOST RTMUX_HOSTS
    rtmux "$@" ) >/dev/null 2>&1
}

# A session already rooted in the dir → straight attach, no picker, no create.
dirsess match 'dev:~/code/proj1'
has "query goes to the right host"        "$(cat $out/dirq.log 2>/dev/null)" " dev sh -s -- "
has "query carries the requested dir"     "$(cat $out/dirq.log 2>/dev/null)" "code/proj1"
has "match → attaches to the rooted session" "$(cat $out/attach.log 2>/dev/null)" " dev tmux attach -t proj1work"
is  "match → nothing is created"          "$([[ -f $out/new.log ]] && echo yes || echo no)" no
is  "host:dir never opens the picker"     "$([[ -f $out/picker_input ]] && echo yes || echo no)" no

# -d rides along on the attach.
dirsess match -d 'dev:~/code/proj1'
has "-d attaches with detach"             "$(cat $out/attach.log 2>/dev/null)" "tmux attach -d -t proj1work"

# No session there → create one in the dir, named after its basename.
dirsess nomatch 'dev:~/code/proj1'
has "no match → new session in the dir"   "$(cat $out/new.log 2>/dev/null)" "tmux new-session -s proj1 -c /home/u/code/proj1"
is  "no match → no attach to old session" "$([[ -f $out/attach.log ]] && echo yes || echo no)" no

# Name collisions get a -2/-3… suffix (proj1 and proj1-2 already exist).
dirsess collide 'dev:~/code/proj1'
has "taken names are suffix-dodged"       "$(cat $out/new.log 2>/dev/null)" "tmux new-session -s proj1-3 -c /home/u/code/proj1"

# -n forces a fresh session even when one is rooted in the dir.
dirsess match 'dev:~/code/proj1' -n
has "-n forces a new session"             "$(cat $out/new.log 2>/dev/null)" "tmux new-session -s proj1 -c /home/u/code/proj1"
is  "-n never attaches to the match"      "$([[ -f $out/attach.log ]] && echo yes || echo no)" no

# -n <name> presets the session name.
dirsess match 'dev:~/code/proj1' -n api
has "-n NAME names the forced session"    "$(cat $out/new.log 2>/dev/null)" "tmux new-session -s api -c /home/u/code/proj1"

# Several sessions rooted in the dir → a picker over just those (the stubbed
# inspector's rows don't name them, so the plain-row fallback feeds fzf).
FZF_MODE=select FZF_KEY='' FZF_ROW=2
dirsess multi 'dev:~/code/proj1'
is  "multi-match opens the mini picker"   "$(grep -c . $out/picker_input)" 2
has "picker rows are the rooted sessions" "$(cut -f2 $out/picker_input | tr '\n' ' ')" "demo-2 demo "
has "picked row attaches to that session" "$(cat $out/attach.log 2>/dev/null)" " dev tmux attach -t demo"
hasnt "picked row is not the newest one"  "$(cat $out/attach.log 2>/dev/null)" "demo-2"
is  "picking creates nothing"             "$([[ -f $out/new.log ]] && echo yes || echo no)" no

# ctrl-n in the mini picker → create another session rooted there instead.
FZF_MODE=select FZF_KEY=ctrl-n FZF_ROW=1
dirsess multi 'dev:~/code/proj1'
has "ctrl-n creates another session there" "$(cat $out/new.log 2>/dev/null)" "tmux new-session -s proj1 -c /home/u/code/proj1"
is  "ctrl-n does not attach"              "$([[ -f $out/attach.log ]] && echo yes || echo no)" no
FZF_MODE=select FZF_KEY='' FZF_ROW=1

# No fzf + no TTY (a prompt is impossible) → newest-activity match. The TTY
# path shows a numbered pick instead — guarded statically below since the
# prompt reads /dev/tty. A fully controlled PATH (stub ssh + the few binaries
# the flow needs, and *no* fzf from anywhere) keeps this deterministic — just
# dropping $MOCK from $path would expose the system fzf.
typeset MOCK_NOFZF="$WORK/bin-nofzf"; mkdir -p "$MOCK_NOFZF"
ln -sf "$MOCK/ssh" "$MOCK_NOFZF/ssh"
typeset _c
for _c in zsh sleep cat rm; do ln -sf "$(command -v $_c)" "$MOCK_NOFZF/$_c"; done
reset_logs
( export RTMUX_DIRQ_MODE=multi RTMUX_WATCH=0; unset RTMUX_HOST RTMUX_HOSTS
  path=("$MOCK_NOFZF")
  rtmux 'dev:~/code/proj1' ) >/dev/null 2>&1
has "no-fzf non-TTY falls back to newest" "$(cat $out/attach.log 2>/dev/null)" " dev tmux attach -t demo-2"
typeset dsp_def; dsp_def="$(functions _rtmux_dir_session)"
has "no-fzf TTY path is a numbered pick"  "$dsp_def" "sessions rooted in"

# Missing directory (non-TTY: no create-it? prompt) → clear error, no session.
reset_logs
typeset derr
derr="$( ( export RTMUX_DIRQ_MODE=missing RTMUX_WATCH=0; unset RTMUX_HOST RTMUX_HOSTS
           rtmux 'dev:~/nope' ) 2>&1 )"
has "missing dir errors out"              "$derr" "no such directory"
is  "missing dir creates nothing"         "$([[ -f $out/new.log ]] && echo yes || echo no)" no

# Guard rails.
derr="$( (unset RTMUX_HOST RTMUX_HOSTS; rtmux prod 'dev:~/x') 2>&1 )"
has "host:dir with two hosts is rejected" "$derr" "single host"
derr="$( (unset RTMUX_HOST RTMUX_HOSTS; rtmux ':~/x') 2>&1 )"
has "empty host is rejected"              "$derr" "empty host"

# The interactive prompts read /dev/tty (no pty here) — statically guard that
# the create flow offers a real way out *before* creating: a "start there?"
# prompt whose n-branch cancels with return 0, separate from the Claude offer.
typeset ds_def; ds_def="$(functions _rtmux_dir_session)"
has "create flow asks before starting"    "$ds_def" "no session rooted in"
has "declining cancels without creating"  "$ds_def" "rtmux: cancelled"
has "Claude offer is a separate question" "$ds_def" "launch Claude Code in it"

# ===========================================================================
section "dir-query script: remote path expansion (runs locally under sh)"
# ===========================================================================
# $_RTMUX_DIRQ_SH is what actually runs on the remote; exercise its ~/relative
# expansion and exit codes with a scratch HOME. (A live local tmux may add
# SESS lines — assertions only look at the DIR line and the exit code.)
typeset DQHOME="$WORK/dqhome"; mkdir -p "$DQHOME/code/proj one"
typeset dq1 dq2
print -r -- "$_RTMUX_DIRQ_SH" | HOME="$DQHOME" sh -s -- '~/code/proj one' >/dev/null 2>&1
is  "tilde dir resolves (exit 0)"      "$?" 0
dq1="$(print -r -- "$_RTMUX_DIRQ_SH" | HOME="$DQHOME" sh -s -- '~/code/proj one' | head -1)"
has "DIR line is tab-prefixed + resolved" "$dq1" $'DIR\t'
has "DIR line reaches the target dir"  "$dq1" "code/proj one"
dq2="$(print -r -- "$_RTMUX_DIRQ_SH" | HOME="$DQHOME" sh -s -- 'code/proj one' | head -1)"
is  "relative dir == tilde dir"        "$dq2" "$dq1"
print -r -- "$_RTMUX_DIRQ_SH" | HOME="$DQHOME" sh -s -- '~/nope' >/dev/null 2>&1
is  "missing dir exits 3"              "$?" 3
print -r -- "$_RTMUX_DIRQ_SH" | HOME="$DQHOME" sh -s -- '~/mkme/sub' mk >/dev/null 2>&1
is  "mk flag creates the dir first"    "$([[ -d "$DQHOME/mkme/sub" ]] && echo yes || echo no)" yes

# ===========================================================================
section "remote Python inspector output shape (needs tmux; skipped otherwise)"
# ===========================================================================
if command -v tmux >/dev/null 2>&1 && tmux new-session -d -s rtmuxtest 2>/dev/null; then
  typeset PY="$WORK/remote.py"
  awk '/<<.PYEOF.$/{f=1;next} /^PYEOF$/{f=0} f' "$RTMUX" > "$PY"
  typeset single multi
  single="$(python3 "$PY" 2>/dev/null | head -1)"
  multi="$(python3 "$PY" $'\033[36mprod\033[0m ' prod prod 2>/dev/null | head -1)"
  is  "single-host rows have 2 tab fields" "$(print -r -- "$single" | awk -F'\t' '{print NF}')" 2
  is  "multi-host rows have 4 tab fields"  "$(print -r -- "$multi"  | awk -F'\t' '{print NF}')" 4
  is  "multi row's slug field is the host slug" "$(print -r -- "$multi" | cut -f3)" prod
  is  "multi row's host field is the host"       "$(print -r -- "$multi" | cut -f4)" prod
  tmux kill-session -t rtmuxtest 2>/dev/null
else
  print -r -- "  skip - tmux unavailable; Python inspector shape not checked"
fi

# ===========================================================================
print -r -- ""
print -r -- "rtmux.test: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
exit 0
