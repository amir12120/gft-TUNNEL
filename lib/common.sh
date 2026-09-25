#!/usr/bin/env bash
# ============================================================
# GRE+FRP-TUNNEL — lib/common.sh
# Logging, path resolution, state (config.env) handling,
# interactive prompts and the menu helper.
#
# Everything that touches the filesystem goes through a
# GRE_FRP_* variable so the test suite can point the whole CLI
# at a temporary directory and stub out ip/iptables/systemctl.
# ============================================================

[ -n "${GRE_FRP_COMMON_LOADED:-}" ] && return 0
GRE_FRP_COMMON_LOADED=1

# ------------------------------------------------------------
# Paths — every one of them is overridable from the environment
# (used by test/smoke.sh and by `GRE_FRP_DRY_RUN=1` runs).
# ------------------------------------------------------------
GRE_FRP_APP_NAME="GRE+FRP-TUNNEL"
GRE_FRP_CLI_NAME="gre-frp-tunnel"

GRE_FRP_STATE_DIR="${GRE_FRP_STATE_DIR:-/etc/gre-frp-tunnel}"
GRE_FRP_LOG_DIR="${GRE_FRP_LOG_DIR:-/var/log/gre-frp-tunnel}"
GRE_FRP_RUN_DIR="${GRE_FRP_RUN_DIR:-/run/gre-frp-tunnel}"
GRE_FRP_FRP_ETC_DIR="${GRE_FRP_FRP_ETC_DIR:-/etc/frp}"
GRE_FRP_BIN_DIR="${GRE_FRP_BIN_DIR:-/usr/local/bin}"
GRE_FRP_SYSTEMD_DIR="${GRE_FRP_SYSTEMD_DIR:-/etc/systemd/system}"
GRE_FRP_SYSCTL_DIR="${GRE_FRP_SYSCTL_DIR:-/etc/sysctl.d}"
GRE_FRP_MODULES_LOAD_DIR="${GRE_FRP_MODULES_LOAD_DIR:-/etc/modules-load.d}"

GRE_FRP_STATE_FILE="$GRE_FRP_STATE_DIR/config.env"
GRE_FRP_LOG_FILE="$GRE_FRP_LOG_DIR/gre-frp-tunnel.log"
GRE_FRP_OPT_LOG="$GRE_FRP_LOG_DIR/optimize.log"
GRE_FRP_SYSCTL_FILE="$GRE_FRP_SYSCTL_DIR/99-gre-frp-tunnel.conf"

# Behaviour switches
GRE_FRP_DRY_RUN="${GRE_FRP_DRY_RUN:-0}"          # 1 = print, never touch the host
GRE_FRP_NONINTERACTIVE="${GRE_FRP_NONINTERACTIVE:-0}"
GRE_FRP_ALLOW_NON_ROOT="${GRE_FRP_ALLOW_NON_ROOT:-0}"
GRE_FRP_TUN_DEV="${GRE_FRP_TUN_DEV:-gre-frp}"
GRE_FRP_SSH_PORT_GUARD="${GRE_FRP_SSH_PORT_GUARD:-1}"

# Default tunnel parameters
GRE_FRP_DEFAULT_NET="10.99.99"
GRE_FRP_DEFAULT_GRE_IP_IRAN="10.99.99.1"
GRE_FRP_DEFAULT_GRE_IP_FOREIGN="10.99.99.2"
GRE_FRP_DEFAULT_CTRL_PORT="7000"
GRE_FRP_DEFAULT_MTU="1472"
GRE_FRP_DEFAULT_TTL="64"

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

gre_frp_logfile_init() {
  mkdir -p "$GRE_FRP_LOG_DIR" 2>/dev/null || true
  [ -w "$GRE_FRP_LOG_DIR" ] || GRE_FRP_LOG_FILE="/dev/null"
}

_log() {
  local lvl="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$lvl" "$*" \
    >>"$GRE_FRP_LOG_FILE" 2>/dev/null || true
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
   ____ ____  _____    _____ ____  ____     _____ _   _ _   _ _   _ _____ _
  / ___|  _ \| ____|  |  ___|  _ \|  _ \   |_   _| | | | \ | | \ | | ____| |
 | |  _| |_) |  _|    | |_  | |_) | |_) |    | | | | | |  \| |  \| |  _| | |
 | |_| |  _ <| |___   |  _| |  _ <|  __/     | | | |_| | |\  | |\  | |___| |___
  \____|_| \_\_____|  |_|   |_| \_\_|        |_|  \___/|_| \_|_| \_|_____|_____|
BANNER
  printf '%s' "$C_0"
  dim "  GRE tunnel + reverse FRP tunnel for Iran ⇄ foreign servers"
}

# ------------------------------------------------------------
# Running commands (honours GRE_FRP_DRY_RUN)
# ------------------------------------------------------------
run() {
  if [ "$GRE_FRP_DRY_RUN" = "1" ]; then
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
  if [ "$GRE_FRP_DRY_RUN" = "1" ]; then printf '%s  + %s%s\n' "$C_DIM" "$*" "$C_0"; _log DRY "$*"; return 0; fi
  "$@"
}

mutq() { # mutate, stay quiet
  if [ "$GRE_FRP_DRY_RUN" = "1" ]; then printf '%s  + %s%s\n' "$C_DIM" "$*" "$C_0"; _log DRY "$*"; return 0; fi
  "$@" >/dev/null 2>&1
}

# put_file PATH   — content arrives on stdin
put_file() {
  local f="$1"
  if [ "$GRE_FRP_DRY_RUN" = "1" ]; then
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
  if [ "$GRE_FRP_ALLOW_NON_ROOT" = "1" ]; then
    warn "not running as root — continuing because GRE_FRP_ALLOW_NON_ROOT=1"
    return 0
  fi
  if [ "$GRE_FRP_DRY_RUN" = "1" ]; then
    warn "not running as root — continuing because GRE_FRP_DRY_RUN=1"
    return 0
  fi
  die "This command must be run as root (use: sudo $GRE_FRP_CLI_NAME $*)"
}

is_systemd() {
  # the smoke tests force this on/off so they behave the same everywhere
  [ "${GRE_FRP_NO_SYSTEMD:-0}" = "1" ] && return 1
  [ "${GRE_FRP_FORCE_SYSTEMD:-0}" = "1" ] && return 0
  have systemctl && [ -d /run/systemd/system ]
}

gre_frp_lock_init() {
  mkdir -p "$GRE_FRP_RUN_DIR" 2>/dev/null || true
  GRE_FRP_LOCK="$GRE_FRP_RUN_DIR/lock"
}

# ------------------------------------------------------------
# State — a simple KEY=value file
# ------------------------------------------------------------
cfg_load() {
  [ -f "$GRE_FRP_STATE_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$GRE_FRP_STATE_FILE"
}

# Indirect lookups go through eval on purpose: bash's ${!name} raises
# "invalid indirect expansion" when the target variable is unset, and our
# config keys are frequently unset (fresh install, optional features).
cfg_has() {
  cfg_load
  eval "[ -n \"\${$1+x}\" ]"
}

cfg_loaded() { [ -f "$GRE_FRP_STATE_FILE" ]; }

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
  if [ "$GRE_FRP_DRY_RUN" = "1" ]; then
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

cfg_set() { cfg_set_file "$GRE_FRP_STATE_FILE" "$1" "$2"; }

# ------------------------------------------------------------
# Interaction
# ------------------------------------------------------------
gre_frp_interactive() {
  [ "$GRE_FRP_NONINTERACTIVE" = "1" ] && return 1
  [ -t 0 ] && return 0
  # no tty on stdin: try /dev/tty
  [ -r /dev/tty ] && return 0
  return 1
}

# prompt VAR "question" [default] [validate_fn]
prompt() {
  local __var="$1" q="$2" def="${3:-}" validator="${4:-}" ans=""
  local shown="$q"
  [ -n "$def" ] && shown="$q [${C_DIM}$def${C_0}]"
  while :; do
    if gre_frp_interactive; then
      if [ -t 0 ]; then
        printf '%s %s: ' "${C_C}?${C_0}" "$shown"
        IFS= read -r ans || ans=""
      else
        printf '%s %s: ' "${C_C}?${C_0}" "$shown" >/dev/tty
        IFS= read -r ans </dev/tty || ans=""
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
    [ -n "$def" ] || { printf -v "$__var" '%s' ""; return 1; }
  done
}

# confirm "question" [default: y|n]  -> 0 yes / 1 no
confirm() {
  local q="$1" def="${2:-y}" ans=""
  if ! gre_frp_interactive; then
    [ "$def" = "y" ] && return 0 || return 1
  fi
  if [ -t 0 ]; then
    printf '%s %s ' "${C_C}?${C_0}" "$q"
    IFS= read -r ans || ans=""
  else
    printf '%s %s ' "${C_C}?${C_0}" "$q" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
  fi
  ans="${ans:-$def}"
  case "$ans" in y|Y|yes|YES|بله|ب) return 0 ;; *) return 1 ;; esac
}

pause_enter() {
  gre_frp_interactive || return 0
  if [ -t 0 ]; then
    printf '%s' "${C_DIM}— press Enter to continue —${C_0}"
    IFS= read -r _ || true
  else
    printf '%s' "${C_DIM}— press Enter to continue —${C_0}" >/dev/tty
    IFS= read -r _ </dev/tty || true
  fi
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

  if ! gre_frp_interactive; then
    printf '%s\n' "$title" >&2
    for i in "${!items[@]}"; do
      printf '  %2d) %s\n' "$((i + 1))" "${items[$i]}" >&2
    done
    local ans=""
    printf 'choice: ' >&2
    IFS= read -r ans </dev/tty 2>/dev/null || ans="1"
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
