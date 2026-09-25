#!/usr/bin/env bash
# ============================================================
# gft-TUNNEL — lib/prereq.sh
# Detects the distribution and installs everything the tunnel
# needs on *both* servers (Iran and foreign).
#
# Design notes
#   * Only the packages that are actually missing get installed.
#   * Package names are mapped per family (apt / dnf / yum / apk
#     / pacman / zypper) so the same script runs anywhere.
#   * Nothing here is destructive: no removals, no repo changes.
# ============================================================

[ -n "${GFT_PREREQ_LOADED:-}" ] && return 0
GFT_PREREQ_LOADED=1

# Required command -> package name per family
GFT_REQ_CMDS="ip curl tar iptables ping"
GFT_OPT_CMDS="modprobe ss jq awk"

pkg_family() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
      *debian*|*ubuntu*) echo apt; return ;;
      *alpine*)          echo apk; return ;;
      *arch*)            echo pacman; return ;;
      *fedora*|*rhel*|*centos*) echo dnf; return ;;
      *suse*)            echo zypper; return ;;
    esac
  fi
  if have apt-get; then echo apt; return; fi
  if have dnf;     then echo dnf; return; fi
  if have yum;     then echo yum; return; fi
  if have apk;     then echo apk; return; fi
  if have pacman;  then echo pacman; return; fi
  if have zypper;  then echo zypper; return; fi
  echo none
}

# pkg_name <cmd> <family> -> package providing <cmd>
pkg_name() {
  local cmd="$1" fam="$2"
  case "$cmd" in
    ip)        case "$fam" in apt) echo iproute2 ;; *) echo iproute ;; esac ;;
    curl)      echo curl ;;
    tar)       echo tar ;;
    gzip)      echo gzip ;;
    iptables)  echo iptables ;;
    ping)      case "$fam" in
                 apt) echo iputils-ping ;;
                 apk) echo iputils ;;
                 pacman) echo iputils ;;
                 *)   echo iputils ;;
               esac ;;
    modprobe)  echo kmod ;;
    ss)        case "$fam" in apt) echo iproute2 ;; *) echo iproute ;; esac ;;
    jq)        echo jq ;;
    ca-certs)  case "$fam" in
                 apt|apk) echo ca-certificates ;;
                 pacman)  echo ca-certificates ;;
                 *)       echo ca-certificates ;;
               esac ;;
    *)         echo "$cmd" ;;
  esac
}

pkg_install() {
  local fam; fam="$(pkg_family)"
  [ $# -gt 0 ] || return 0
  if [ "$GFT_DRY_RUN" = "1" ]; then
    printf '%s+ install: %s%s\n' "$C_DIM" "$*" "$C_0"
    return 0
  fi
  require_root "install prerequisites"
  case "$fam" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      try apt-get update -y -o Acquire::Retries=3
      try apt-get install -y --no-install-recommends "$@"
      ;;
    dnf)    try dnf install -y "$@" ;;
    yum)    try yum install -y "$@" ;;
    apk)    try apk add --no-cache "$@" ;;
    pacman) try pacman -Sy --noconfirm --needed "$@" ;;
    zypper) try zypper --non-interactive install "$@" ;;
    *)      warn "unknown package manager — please install manually: $*" ;;
  esac
}

prereq_missing_required() {
  local cmd pkg out="" fam
  fam="$(pkg_family)"
  for cmd in $GFT_REQ_CMDS; do
    have "$cmd" || out="$out $(pkg_name "$cmd" "$fam")"
  done
  printf '%s' "$out"
}

prereq_install() {
  step "Installing prerequisites"
  local fam missing
  fam="$(pkg_family)"
  info "package family: ${C_BOLD}${fam}${C_0}"

  if ! have curl && [ "$fam" = "none" ]; then
    die "curl is required and no supported package manager was found"
  fi

  missing="$(prereq_missing_required)"
  if [ -z "$missing" ]; then
    ok "all required tools are already present"
  else
    info "missing packages:${missing}"
    # shellcheck disable=SC2086
    pkg_install $missing
  fi

  # optional extras (never fatal) — jq just makes FRP JSON parsing nicer
  local opt_missing=""
  for cmd in $GFT_OPT_CMDS; do
    have "$cmd" || opt_missing="$opt_missing $(pkg_name "$cmd" "$fam")"
  done
  if [ -n "$opt_missing" ]; then
    dim "installing optional helpers:${opt_missing}"
    # shellcheck disable=SC2086
    pkg_install $opt_missing
  fi

  prereq_ensure_gre_module
  prereq_verify
}

prereq_ensure_gre_module() {
  # ip_gre is auto-loaded when a gre device is created, but loading it
  # eagerly gives a clear error early on kernels that ship it as a module.
  if have modprobe; then
    quiet modprobe gre || quiet modprobe ip_gre || true
    mkdir -p "$GFT_MODULES_LOAD_DIR" 2>/dev/null || true
    if [ -d "$GFT_MODULES_LOAD_DIR" ] && [ ! -f "$GFT_MODULES_LOAD_DIR/gft-tunnel.conf" ]; then
      echo gre | put_file "$GFT_MODULES_LOAD_DIR/gft-tunnel.conf"
    fi
  fi

  # best-effort probe: can this kernel actually create a gre device?
  local gft_gre_state="unsupported"
  if have ip; then
    if quiet ip link add gre-probe type gre 2>/dev/null; then
      quiet ip link del gre-probe
      gft_gre_state="ok"
    elif [ ! -w /proc/sys/net ] && [ "$(id -u)" != "0" ]; then
      gft_gre_state="unverified (need root)"
    fi
  fi
  dim "gre kernel support: $gft_gre_state"
}

prereq_verify() {
  local fam; fam="$(pkg_family)"
  local missing="" cmd
  for cmd in $GFT_REQ_CMDS; do
    have "$cmd" || missing="$missing $(pkg_name "$cmd" "$fam")"
  done
  if [ -n "$missing" ]; then
    warn "still missing:${missing}"
    return 1
  fi
  ok "prerequisites OK (ip, curl, tar, iptables, ping)"
  return 0
}

prereq_report() {
  local cmd state
  printf '%-12s %s\n' "TOOL" "STATUS"
  for cmd in $GFT_REQ_CMDS $GFT_OPT_CMDS; do
    if have "$cmd"; then
      state="${C_G}present${C_0}"
    elif grep -qw "$cmd" <<<"$GFT_REQ_CMDS"; then
      state="${C_R}missing${C_0}"
    else
      state="${C_Y}optional${C_0}"
    fi
    printf '%-12s %b\n' "$cmd" "$state"
  done
}
