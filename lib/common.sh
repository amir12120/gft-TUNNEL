#!/usr/bin/env bash
# ============================================================
# gft-TUNNEL — lib/common.sh
# Logging, path resolution, state (config.env) handling,
# interactive prompts and the menu helper.
#
# Everything that touches the filesystem goes through a
# GFT_* variable so the test suite can point the whole CLI
# at a temporary directory and stub out ip/iptables/systemctl.
# ============================================================

[ -n "${GFT_COMMON_LOADED:-}" ] && return 0
GFT_COMMON_LOADED=1

# ------------------------------------------------------------
# Paths — every one of them is overridable from the environment
# (used by test/smoke.sh and by `GFT_DRY_RUN=1` runs).
# ------------------------------------------------------------
GFT_APP_NAME="gft-TUNNEL"
GFT_CLI_NAME="gft"
GFT_NO_TTY="${GFT_NO_TTY:-0}"
GFT_MENU_MODE=0

GFT_STATE_DIR="${GFT_STATE_DIR:-/etc/gft-tunnel}"
GFT_LOG_DIR="${GFT_LOG_DIR:-/var/log/gft-tunnel}"
GFT_RUN_DIR="${GFT_RUN_DIR:-/run/gft-tunnel}"
GFT_FRP_ETC_DIR="${GFT_FRP_ETC_DIR:-/etc/frp}"
GFT_BIN_DIR="${GFT_BIN_DIR:-/usr/local/bin}"
GFT_SYSTEMD_DIR="${GFT_SYSTEMD_DIR:-/etc/systemd/system}"
GFT_SYSCTL_DIR="${GFT_SYSCTL_DIR:-/etc/sysctl.d}"
GFT_MODULES_LOAD_DIR="${GFT_MODULES_LOAD_DIR:-/etc/modules-load.d}"

GFT_STATE_FILE="$GFT_STATE_DIR/config.env"
GFT_LOG_FILE="$GFT_LOG_DIR/gft-tunnel.log"
GFT_OPT_LOG="$GFT_LOG_DIR/optimize.log"
GFT_SYSCTL_FILE="$GFT_SYSCTL_DIR/99-gft-tunnel.conf"

# Behaviour switches
GFT_DRY_RUN="${GFT_DRY_RUN:-0}"          # 1 = print, never touch the host
GFT_NONINTERACTIVE="${GFT_NONINTERACTIVE:-0}"
GFT_ALLOW_NON_ROOT="${GFT_ALLOW_NON_ROOT:-0}"
GFT_TUN_DEV="${GFT_TUN_DEV:-gft0}"
GFT_SSH_PORT_GUARD="${GFT_SSH_PORT_GUARD:-1}"

# Default tunnel parameters
GFT_DEFAULT_NET="10.99.99"
GFT_DEFAULT_GRE_IP_IRAN="10.99.99.1"
GFT_DEFAULT_GRE_IP_FOREIGN="10.99.99.2"
GFT_DEFAULT_CTRL_PORT="40001"
GFT_DEFAULT_MTU="1472"
GFT_DEFAULT_TTL="64"

# ------------------------------------------------------------
# Colours / logging
# ------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'
  C_B=$'\033[0;34m'; C_M=$'\033[0;35m'; C_C=$'\033[0;36m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_M=''; C_C=''; C_BOLD=''; C_DIM=''; C_0=''
fi

gft_logfile_init() {
  mkdir -p "$GFT_LOG_DIR" 2>/dev/null || true
  [ -w "$GFT_LOG_DIR" ] || GFT_LOG_FILE="/dev/null"
}

_log() {
  local lvl="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$lvl" "$*" \
    >>"$GFT_LOG_FILE" 2>/dev/null || true
}

info()  { printf '%s %s\n' "${C_C}•${C_0}" "$*";    _log INFO "$*"; }
ok()    { printf '%s %s\n' "${C_G}✔${C_0}" "$*";    _log OK   "$*"; }
warn()  { printf '%s %s\n' "${C_Y}!${C_0}" "$*" >&2; _log WARN "$*"; }
err()   { printf '%s %s\n' "${C_R}✘${C_0}" "$*" >&2; _log ERR  "$*"; }
step()  { printf '\n%s%s%s\n' "${C_BOLD}${C_B}" "$*" "${C_0}"; _log STEP "$*"; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_0"; }
die()   { err "$*"; exit 1; }

hr() { printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────${C_0}"; }

# Banner
banner() {
  printf '%s' "$C_M"
  cat <<'BANNER'
       __ _  __ _| |_      _____ _   _ _   _ _   _ _____ _
      / _` |/ _` | __|    |_   _| | | | \ | | \ | | ____| |
     | (_| | (_| | |_       | | | | | |  \| |  \| |  _| | |
      \__, |\__,_|\__|      | | | |_| | |\  | |\  | |___| |___
      |___/                |_|  \___/|_| \_|_| \_|_____|_____|
BANNER
  printf '%s' "$C_0"
  dim "  fast GRE tunnel + reverse FRP tunnel for Iran ⇄ foreign servers"
  dim "  v${GFT_VERSION:-dev}"
  printf '\n'
}

# ------------------------------------------------------------
# Running commands (honours GFT_DRY_RUN)
# ------------------------------------------------------------
run() {
  if [ "$GFT_DRY_RUN" = "1" ]; then
    printf '%s+ %s%s\n' "$C_DIM" "$*" "$C_0"
    _log DRY "$*"
    return 0
  fi
  "$@"
}

# Run and keep going if it fails
try() {
  run "$@" || warn "command failed: $*"
}

quiet() { "$@" >/dev/null 2>&1; }

# ------------------------------------------------------------
# Mutating helpers — these are the ONLY place the CLI is allowed
# to change the host. In dry-run mode they only print.
# ------------------------------------------------------------
mut() {  # mutate, keep output
  if [ "$GFT_DRY_RUN" = "1" ]; then printf '%s  + %s%s\n' "$C_DIM" "$*" "$C_0"; _log DRY "$*"; return 0; fi
  "$@"
}

mutq() { # mutate, stay quiet
  if [ "$GFT_DRY_RUN" = "1" ]; then printf '%s  + %s%s\n' "$C_DIM" "$*" "$C_0"; _log DRY "$*"; return 0; fi
  "$@" >/dev/null 2>&1
}

# put_file PATH   — content arrives on stdin
put_file() {
  local f="$1"
  if [ "$GFT_DRY_RUN" = "1" ]; then
    printf '%s  + write %s%s\n' "$C_DIM" "$f" "$C_0"
    _log DRY "write $f"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  cat >"$f"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------
# Root / environment checks
# ------------------------------------------------------------
require_root() {
  if [ "$(id -u)" = "0" ]; then return 0; fi
  if [ "$GFT_ALLOW_NON_ROOT" = "1" ]; then
    warn "not running as root — continuing because GFT_ALLOW_NON_ROOT=1"
    return 0
  fi
  if [ "$GFT_DRY_RUN" = "1" ]; then
    warn "not running as root — continuing because GFT_DRY_RUN=1"
    return 0
  fi
  die "This command must be run as root (use: sudo $GFT_CLI_NAME $*)"
}

is_systemd() {
  # the smoke tests force this on/off so they behave the same everywhere
  [ "${GFT_NO_SYSTEMD:-0}" = "1" ] && return 1
  [ "${GFT_FORCE_SYSTEMD:-0}" = "1" ] && return 0
  have systemctl && [ -d /run/systemd/system ]
}

gft_lock_init() {
  mkdir -p "$GFT_RUN_DIR" 2>/dev/null || true
  GFT_LOCK="$GFT_RUN_DIR/lock"
}

# ------------------------------------------------------------
# State — a simple KEY=value file
# ------------------------------------------------------------
cfg_load() {
  [ -f "$GFT_STATE_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$GFT_STATE_FILE"
}

# Indirect lookups go through eval on purpose: bash's ${!name} raises
# "invalid indirect expansion" when the target variable is unset, and our
# config keys are frequently unset (fresh install, optional features).
cfg_has() {
  cfg_load
  eval "[ -n \"\${$1+x}\" ]"
}

cfg_loaded() { [ -f "$GFT_STATE_FILE" ]; }

cfg_get() { # cfg_get KEY [default]
  local k="$1" d="${2:-}" v=""
  cfg_load
  eval "v=\${$k:-}"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$d"
}

cfg_is_set() { # true when KEY exists and is non-empty
  local v=""
  cfg_load
  eval "v=\${$1:-}"
  [ -n "$v" ]
}

cfg_set_file() { # file key value
  local file="$1" k="$2" v="$3" tmp
  if [ "$GFT_DRY_RUN" = "1" ]; then
    printf '%s  + %s: %s=%s%s\n' "$C_DIM" "$file" "$k" "$v" "$C_0"
    return 0
  fi
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  [ -f "$file" ] || : >"$file"
  tmp="$(mktemp)" || return 1
  # values that bash would mangle when the file is sourced again (spaces,
  # globs, …) get single-quoted so `cfg_load` always restores them verbatim
  case "$v" in
    *[!A-Za-z0-9_.,:/@%+-]*|'')
      v="'$(printf '%s' "$v" | sed "s/'/'\\\\''/g")'"
      ;;
  esac
  # replace the key in place (keeping a stable file layout) or append it
  if [ ! -f "$file" ]; then : >"$file"; fi
  awk -v k="$k" -v v="$v" '
    BEGIN { done = 0 }
    $0 ~ ("^" k "=") { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" >"$tmp" || return 1
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

cfg_set() { cfg_set_file "$GFT_STATE_FILE" "$1" "$2"; }

# ------------------------------------------------------------
# Interaction
# ------------------------------------------------------------
gft_interactive() {
  [ "$GFT_NONINTERACTIVE" = "1" ] && return 1
  [ "$GFT_NO_TTY" = "1" ] && return 1
  [ -t 0 ] && return 0
  # no tty on stdin: try /dev/tty
  [ -r /dev/tty ] && return 0
  return 1
}

# Reads one line into the named variable. Returns non-zero on EOF.
# In menu mode (a scripted TUI session) the answers come from stdin, which
# also makes the whole CLI scriptable.
_read_line() {
  local __v="$1" line=""
  if [ "$GFT_MENU_MODE" = "1" ] || [ ! -r /dev/tty ]; then
    IFS= read -r line || return 1
  else
    IFS= read -r line </dev/tty || return 1
  fi
  printf -v "$__v" '%s' "$line"
  return 0
}

_ask() { # prints the prompt to a tty when possible, then reads a line
  local text="$1" __v="$2"
  if [ "$GFT_MENU_MODE" = "1" ] || [ -t 0 ] || [ ! -r /dev/tty ]; then
    printf '%s' "$text"
  else
    printf '%s' "$text" >/dev/tty
  fi
  _read_line "$__v"
}

# prompt VAR "question" [default] [validate_fn]
prompt() {
  local __var="$1" q="$2" def="${3:-}" validator="${4:-}" ans=""
  local shown="$q"
  [ -n "$def" ] && shown="$q [${C_DIM}$def${C_0}]"
  local asked=0 eof=0
  while :; do
    if [ "$GFT_MENU_MODE" = "1" ] || gft_interactive; then
      if _ask "${C_C}?${C_0} $shown: " ans; then
        asked=$(( asked + 1 ))
      else
        eof=1; ans=""
      fi
    else
      ans=""
    fi
    [ -n "$ans" ] || ans="$def"
    if [ -z "$validator" ] || "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      return 0
    fi
    err "invalid value: ${ans:-<empty>}"
    if [ "$eof" = "1" ] || [ -z "$def" ]; then
      printf -v "$__var" '%s' ""
      return 1
    fi
    [ "$asked" -gt 12 ] && { printf -v "$__var" '%s' "$def"; return 0; }
  done
}

# confirm "question" [default: y|n]  -> 0 yes / 1 no
confirm() {
  local q="$1" def="${2:-y}" ans=""
  if [ "$GFT_MENU_MODE" != "1" ] && ! gft_interactive; then
    [ "$def" = "y" ] && return 0 || return 1
  fi
  if ! _ask "${C_C}?${C_0} $q " ans; then
    [ "$def" = "y" ] && return 0 || return 1
  fi
  ans="${ans:-$def}"
  case "$ans" in y|Y|yes|YES|بله|ب) return 0 ;; *) return 1 ;; esac
}

pause_enter() {
  [ "$GFT_MENU_MODE" = "1" ] && return 0
  gft_interactive || return 0
  printf '%s' "${C_DIM}— press Enter to continue —${C_0}"
  _read_line _ || true
}

# _menu_draw <tty> <title> <selected-index> <items...>
_menu_draw() {
  local tty_in="$1" title="$2" sel="$3"; shift 3
  local -a items=("$@")
  local i
  printf '\033[?25l' >"$tty_in"
  printf '%s\n' "${C_BOLD}$title${C_0}" >"$tty_in"
  for i in "${!items[@]}"; do
    if [ "$i" = "$sel" ]; then
      printf '  %s❯ %s%s\n' "$C_C" "${items[$i]}" "$C_0" >"$tty_in"
    else
      printf '    %s\n' "${items[$i]}" >"$tty_in"
    fi
  done
}

# menu "title" <item...>  -> prints the 0-based index to stdout
menu() {
  local title="$1"; shift
  local -a items=("$@")
  local i n=${#items[@]} sel=0

  if ! gft_interactive; then
    # numbered fallback — also what `printf '7\n16\n' | gft menu` drives
    GFT_MENU_MODE=1
    printf '%s\n' "$title" >&2
    for i in "${!items[@]}"; do
      printf '  %2d) %s\n' "$((i + 1))" "${items[$i]}" >&2
    done
    local ans=""
    printf 'choice: ' >&2
    if ! _read_line ans; then
      printf '%s' "-1"   # end of input → quit
      return 0
    fi
    case "$ans" in ''|*[!0-9]*) ans=1 ;; esac
    [ "$ans" -lt 1 ] && ans=1
    [ "$ans" -gt "$n" ] && ans="$n"
    printf '%s' "$((ans - 1))"
    return 0
  fi

  # arrow-key menu on a real tty
  local tty_in=/dev/tty
  _menu_draw "$tty_in" "$title" "$sel" "${items[@]}"
  while :; do
    local key
    IFS= read -rsn1 key <"$tty_in" || key=""
    case "$key" in
      $'\033')
        local k2 k3
        IFS= read -rsn1 -t 0.05 k2 <"$tty_in" || k2=""
        IFS= read -rsn1 -t 0.05 k3 <"$tty_in" || k3=""
        case "$k2$k3" in
          '[A') sel=$(( (sel - 1 + n) % n )) ;;
          '[B') sel=$(( (sel + 1) % n )) ;;
        esac
        ;;
      '') break ;;   # Enter
      k|K) sel=$(( (sel - 1 + n) % n )) ;;
      j|J) sel=$(( (sel + 1) % n )) ;;
      q|Q) printf '\033[?25h' >"$tty_in"; printf '%s' "-1"; return 0 ;;
    esac
    printf '\033[%dA' "$((n + 1))" >"$tty_in"
    _menu_draw "$tty_in" "$title" "$sel" "${items[@]}"
  done
  printf '\033[?25h' >"$tty_in"
  printf '%s' "$sel"
}

# ------------------------------------------------------------
# Small validators / formatters
# ------------------------------------------------------------
is_ipv4() {
  local ip="$1" o
  case "$ip" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  local IFS='.'
  # shellcheck disable=SC2206
  local parts=($ip)
  [ "${#parts[@]}" -eq 4 ] || return 1
  for o in "${parts[@]}"; do
    [ -n "$o" ] || return 1
    case "$o" in *[!0-9]*) return 1 ;; esac
    [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

is_port() { is_uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

is_yesno() {
  case "${1:-}" in y|Y|yes|n|N|no) return 0 ;; *) return 1 ;; esac
}

mac_like() { printf '%s' "${1//[^A-Za-z0-9]/}"; }

human_bytes() {
  local b="${1:-0}"
  if [ "$b" -lt 1024 ]; then printf '%s B' "$b"; return; fi
  if [ "$b" -lt 1048576 ]; then printf '%d KB' "$((b / 1024))"; return; fi
  printf '%d MB' "$((b / 1048576))"
}

version_ge() { # version_ge A B  -> A >= B
  [ "$1" = "$2" ] && return 0
  local a b
  a="$(printf '%s' "$1" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')"
  b="$(printf '%s' "$2" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')"
  [ "$a" -ge "$b" ]
}
