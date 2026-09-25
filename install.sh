#!/usr/bin/env bash
# ============================================================
# gft-TUNNEL — bootstrap installer
#
# From a checkout:      sudo ./install.sh
# From GitHub:          curl -fsSL https://raw.githubusercontent.com/amir12120/gft-TUNNEL/main/install.sh | sudo bash
#
# It installs the few tools needed to bootstrap (git, curl, tar),
# puts the CLI on PATH and then runs the guided setup.
# ============================================================

set -u

REPO_OWNER="amir12120"
REPO_NAME="gft-TUNNEL"
REPO_URL="${GFT_REPO_URL:-https://github.com/${REPO_OWNER}/${REPO_NAME}.git}"
INSTALL_DIR="${GFT_DIR:-/opt/gft-tunnel}"
BIN_DIR="${GFT_BIN_DIR:-/usr/local/bin}"

C_R=''; C_G=''; C_Y=''; C_C=''; C_0=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'
  C_C=$'\033[0;36m'; C_0=$'\033[0m'
fi
say()  { printf '%s %s\n' "${C_C}•${C_0}" "$*"; }
ok()   { printf '%s %s\n' "${C_G}✔${C_0}" "$*"; }
warn() { printf '%s %s\n' "${C_Y}!${C_0}" "$*" >&2; }
die()  { printf '%s %s\n' "${C_R}✘${C_0}" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------------------------------------
# Where are we?
# -----------------------------------------------------------
SELF_DIR=""
case "${BASH_SOURCE[0]:-}" in
  ''|bash|/dev/stdin|-|/dev/fd/*) SELF_DIR="" ;;
  *) [ -f "${BASH_SOURCE[0]}" ] && SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;
esac

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/gft" ]; then
  SRC_DIR="$SELF_DIR"
  say "running from a local checkout: $SRC_DIR"
else
  SRC_DIR=""
fi

[ "$(id -u)" = "0" ] || die "please run as root (sudo)"

# -----------------------------------------------------------
# Minimal bootstrap dependencies
# -----------------------------------------------------------
install_pkg() {
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y -o Acquire::Retries=3 >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1
  elif have dnf;    then dnf install -y "$@" >/dev/null 2>&1
  elif have yum;    then yum install -y "$@" >/dev/null 2>&1
  elif have apk;    then apk add --no-cache "$@" >/dev/null 2>&1
  elif have pacman; then pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1
  elif have zypper; then zypper --non-interactive install "$@" >/dev/null 2>&1
  else return 1
  fi
}

need=()
have curl || need+=(curl)
have tar  || need+=(tar)
have git  || need+=(git)
if [ -n "$SRC_DIR" ]; then
  # no clone needed when the checkout is already here
  need=()
  have curl || need+=(curl)
  have tar  || need+=(tar)
fi
if [ "${#need[@]}" -gt 0 ]; then
  say "installing bootstrap tools: ${need[*]}"
  install_pkg "${need[@]}" || warn "could not install ${need[*]} automatically"
fi

# -----------------------------------------------------------
# Get the code
# -----------------------------------------------------------
if [ -z "$SRC_DIR" ]; then
  mkdir -p "$(dirname "$INSTALL_DIR")" || die "cannot create $(dirname "$INSTALL_DIR")"
  if [ -d "$INSTALL_DIR/.git" ]; then
    say "updating $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch --depth 1 origin main >/dev/null 2>&1 || true
    git -C "$INSTALL_DIR" reset --hard origin/main >/dev/null 2>&1 || true
  elif [ -e "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR exists but is not a git checkout — remove it or set GFT_DIR"
  else
    say "cloning $REPO_URL → $INSTALL_DIR"
    have git || die "git is required to clone the repository"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" >/dev/null 2>&1 \
      || die "git clone failed — check the URL or set GFT_REPO_URL"
  fi
  SRC_DIR="$INSTALL_DIR"
fi

[ -f "$SRC_DIR/gft" ] || die "the gft CLI was not found in $SRC_DIR"

# -----------------------------------------------------------
# Put it on PATH
# -----------------------------------------------------------
chmod +x "$SRC_DIR/gft" "$SRC_DIR/install.sh" 2>/dev/null || true
chmod +x "$SRC_DIR"/lib/*.sh 2>/dev/null || true
mkdir -p "$BIN_DIR"
ln -sfn "$SRC_DIR/gft" "$BIN_DIR/gft"
ln -sfn "$SRC_DIR/gft" "$BIN_DIR/gre-frp-tunnel"   # name used by v1.0.0
ok "installed: $BIN_DIR/gft  (legacy alias: gre-frp-tunnel)"

# -----------------------------------------------------------
# Hand over to the CLI
# -----------------------------------------------------------
if [ "$#" -gt 0 ]; then
  exec "$SRC_DIR/gft" "$@"
fi
exec "$SRC_DIR/gft" install
