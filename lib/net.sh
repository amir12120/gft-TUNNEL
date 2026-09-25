#!/usr/bin/env bash
# ============================================================
# gft-TUNNEL — lib/net.sh
#   * public IP detection + local-IP sanity checks
#   * GRE device create/destroy (survives reboot through systemd)
#   * best-MTU / best-TTL autotuning (loss aware)
#   * link watchdog used by the hourly timer
# ============================================================

[ -n "${GFT_NET_LOADED:-}" ] && return 0
GFT_NET_LOADED=1

# ------------------------------------------------------------
# Public IP
# ------------------------------------------------------------
GFT_IP_ENDPOINTS="${GFT_IP_ENDPOINTS:-https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip https://icanhazip.com https://api.ip.sb/ip}"

net_public_ip_detect() {
  local url ip
  for url in $GFT_IP_ENDPOINTS; do
    ip="$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '\r\n\t ' || true)"
    case "$ip" in *[!0-9.]*) ip="" ;; esac
    if is_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
    dim "  source $url did not answer, trying next…"
  done
  # last resort: source address of the default route
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9][0-9.]*\).*/\1/p' | head -1)"
  if is_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  return 1
}

net_local_ips() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
}

net_ip_is_local() {
  local ip="$1" x
  for x in $(net_local_ips); do
    [ "$x" = "$ip" ] && return 0
  done
  return 1
}

net_iface_for_ip() {
  ip -4 -o addr show scope global 2>/dev/null \
    | awk -v ip="$1" '$4 == ip "/32" || index($4, ip "/") == 1 {print $2; exit}'
}

net_default_iface() {
  local ifc
  ifc="$(ip -o -4 route show default 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
  if [ -z "$ifc" ]; then
    ifc="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR == 1 {print $2}')"
  fi
  printf '%s' "$ifc"
}

net_iface_mtu() {
  local iface="$1" mtu=""
  [ -n "$iface" ] || { echo 1500; return; }
  mtu="$(ip -o link show "$iface" 2>/dev/null | sed -n 's/.*mtu \([0-9][0-9]*\).*/\1/p' | head -1)"
  if [ -z "$mtu" ] && [ -r "/sys/class/net/$iface/mtu" ]; then
    mtu="$(cat "/sys/class/net/$iface/mtu" 2>/dev/null)"
  fi
  is_uint "$mtu" || mtu=1500
  printf '%s' "$mtu"
}

# ------------------------------------------------------------
# ping helpers (work with iputils *and* busybox)
# ------------------------------------------------------------
gft_ping_df_ok() {
  [ -n "${GFT_PING_DF:-}" ] && { [ "$GFT_PING_DF" = "1" ]; return; }
  local out
  out="$(ping -n -c 1 -W 1 -M do -s 56 127.0.0.1 2>&1 || true)"
  case "$out" in
    *"invalid option"*|*"unrecognized"*|*"Bad option"*|*bad*option*|*Usage*|*usage:*) GFT_PING_DF=0 ;;
    *) GFT_PING_DF=1 ;;
  esac
  [ "$GFT_PING_DF" = "1" ]
}

# net_ping_host <ip> <count> <timeout> [ttl] [extra...]
# prints "<replies> <loss_pct>"
net_ping_host() {
  local dst="$1" count="${2:-3}" to="${3:-2}" ttl="${4:-}" out replies loss
  local -a args=(-n -c "$count" -W "$to")
  [ -n "$ttl" ] && args+=(-t "$ttl")
  [ $# -gt 4 ] && args+=("${@:5}")
  out="$(ping "${args[@]}" "$dst" 2>&1 || true)"
  replies="$(printf '%s\n' "$out" | grep -c 'bytes from' || true)"
  is_uint "$replies" || replies=0
  if [ "$replies" -gt "$count" ]; then replies="$count"; fi
  loss=$(( (count - replies) * 100 / count ))
  printf '%s %s' "$replies" "$loss"
}

# net_probe_payload <ip> <payload_size> <timeout> [extra...]
net_probe_payload() {
  local dst="$1" payload="$2" to="${3:-2}" rc=0
  shift 3 || true
  local -a args=(-n -c 1 -W "$to" -s "$payload")
  gft_ping_df_ok && args+=(-M do)
  [ $# -gt 0 ] && args+=("$@")
  ping "${args[@]}" "$dst" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# ------------------------------------------------------------
# Path MTU discovery between the two public IPs
# prints the discovered MTU; exit code 2 means "no answer, guess"
# ------------------------------------------------------------
net_path_mtu() {
  local dst="$1" iface hi maxp minp best mid
  iface="$(net_default_iface)"
  hi="$(net_iface_mtu "$iface")"
  is_uint "$hi" || hi=1500
  [ "$hi" -lt 576 ] && hi=1500
  [ "$hi" -gt 9000 ] && hi=9000
  minp=548                       # 576 - 28
  maxp=$(( hi - 28 ))
  [ "$maxp" -lt "$minp" ] && maxp="$minp"

  if net_probe_payload "$dst" "$maxp" 2 && net_probe_payload "$dst" "$maxp" 2; then
    printf '%s' "$hi"
    return 0
  fi

  # binary search for the largest payload that survives without fragmentation
  best=""
  local lo="$minp" search_hi="$maxp"
  while [ "$lo" -le "$search_hi" ]; do
    mid=$(( (lo + search_hi) / 2 ))
    if net_probe_payload "$dst" "$mid" 2; then
      best="$mid"; lo=$(( mid + 1 ))
    else
      search_hi=$(( mid - 1 ))
    fi
  done

  if [ -z "$best" ]; then
    printf '%s' "$hi"
    return 2
  fi
  printf '%s' "$(( best + 28 ))"
  return 0
}

# ------------------------------------------------------------
# GRE device
# ------------------------------------------------------------
gft_gre_dev_exists() {
  ip link show dev "$GFT_TUN_DEV" >/dev/null 2>&1
}

is_valid_mtu() { is_uint "${1:-}" && [ "${1:-0}" -ge 68 ] && [ "${1:-0}" -le 65535 ]; }

gft_gre_set_mtu() {
  local mtu="$1"
  is_valid_mtu "$mtu" || return 1
  mutq ip link set dev "$GFT_TUN_DEV" mtu "$mtu"
}

gft_gre_set_ttl() {
  local ttl="$1"
  is_uint "$ttl" || return 1
  local rc=1
  if gft_gre_dev_exists; then
    mutq ip link set dev "$GFT_TUN_DEV" type gre ttl "$ttl" && rc=0
    if [ "$rc" != "0" ]; then
      mutq ip tunnel change "$GFT_TUN_DEV" ttl "$ttl" && rc=0
    fi
  fi
  return "$rc"
}

gft_gre_add_addr() {
  local ip="$1" prefix="${2:-30}"
  local existing
  existing="$(ip -4 -o addr show dev "$GFT_TUN_DEV" 2>/dev/null | awk '{print $4}')"
  case " $existing " in
    *" $ip/$prefix "*) return 0 ;;
  esac
  mutq ip addr add "$ip/$prefix" dev "$GFT_TUN_DEV"
}

gft_gre_create() {
  local local_pub peer_pub ttl mtu ip_local prefix
  local_pub="$(cfg_get LOCAL_PUBLIC_IP)"
  peer_pub="$(cfg_get PEER_PUBLIC_IP)"
  ip_local="$(cfg_get GRE_IP_LOCAL "$GFT_DEFAULT_GRE_IP_IRAN")"
  prefix="$(cfg_get GRE_PREFIX 30)"
  ttl="$(cfg_get TUNNEL_TTL "$GFT_DEFAULT_TTL")"
  mtu="$(cfg_get TUNNEL_MTU "$GFT_DEFAULT_MTU")"
  is_uint "$ttl" || ttl="$GFT_DEFAULT_TTL"
  is_uint "$mtu" || mtu="$GFT_DEFAULT_MTU"

  gft_gre_dev_exists && return 0

  if net_ip_is_local "$local_pub"; then
    mutq ip link add name "$GFT_TUN_DEV" type gre \
      local "$local_pub" remote "$peer_pub" ttl "$ttl" \
      || { err "could not create GRE device (is ip_gre available?)"; return 1; }
  else
    warn "public IP $local_pub is not on this machine — creating GRE without 'local' (NAT mode)"
    mutq ip link add name "$GFT_TUN_DEV" type gre \
      remote "$peer_pub" ttl "$ttl" \
      || { err "could not create GRE device"; return 1; }
  fi

  gft_gre_add_addr "$ip_local" "$prefix" || true
  mutq ip link set dev "$GFT_TUN_DEV" mtu "$mtu" || true
  mutq ip link set dev "$GFT_TUN_DEV" up || true
  return 0
}

gft_gre_destroy() {
  gft_gre_dev_exists || return 0
  mutq ip link del "$GFT_TUN_DEV"
}

gft_gre_peer_reachable() {
  local peer_gre out replies
  peer_gre="$(cfg_get GRE_IP_REMOTE "$GFT_DEFAULT_GRE_IP_FOREIGN")"
  out="$(net_ping_host "$peer_gre" 1 2)"
  replies="${out%% *}"
  [ "${replies:-0}" -ge 1 ]
}

gft_gre_ensure_up() {
  gft_gre_create || return 1
  gft_gre_add_addr "$(cfg_get GRE_IP_LOCAL "$GFT_DEFAULT_GRE_IP_IRAN")" "$(cfg_get GRE_PREFIX 30)" || true
  gft_gre_set_mtu "$(cfg_get TUNNEL_MTU "$GFT_DEFAULT_MTU")" || true
  gft_gre_set_ttl "$(cfg_get TUNNEL_TTL "$GFT_DEFAULT_TTL")" || true
  mutq ip link set dev "$GFT_TUN_DEV" up || true
  return 0
}

gft_gre_show() {
  ip -d link show dev "$GFT_TUN_DEV" 2>/dev/null | head -3
}

# ------------------------------------------------------------
# MTU / TTL autotuning
# ------------------------------------------------------------
# Tunnel overhead of GRE over IPv4:  20 (outer IP) + 4 (GRE header)
GFT_GRE_OVERHEAD=24
GFT_MIN_MTU=1280
GFT_MAX_MTU=9000

net_optimize_mtu() {
  local peer_pub peer_gre iface iface_mtu path_mtu cand floor best loss out
  peer_pub="$(cfg_get PEER_PUBLIC_IP)"
  peer_gre="$(cfg_get GRE_IP_REMOTE)"
  iface="$(net_default_iface)"
  iface_mtu="$(net_iface_mtu "$iface")"
  is_uint "$iface_mtu" || iface_mtu=1500

  step "MTU autotune"
  info "outer interface ${C_BOLD}${iface:-?}${C_0} mtu=$iface_mtu — probing path to ${peer_pub:-?}"

  local probe_rc=0
  path_mtu="$(net_path_mtu "$peer_pub")" || probe_rc=$?
  if [ "$probe_rc" = "2" ]; then
    warn "path MTU probe got no answer — assuming $path_mtu bytes (ICMP may be filtered)"
  else
    ok "discovered outer path MTU: ${path_mtu}"
  fi

  cand=$(( path_mtu - GFT_GRE_OVERHEAD ))
  floor=$(( iface_mtu - GFT_GRE_OVERHEAD ))
  [ "$cand" -gt "$floor" ] && cand="$floor"
  [ "$cand" -gt "$GFT_MAX_MTU" ] && cand="$GFT_MAX_MTU"
  [ "$cand" -lt "$GFT_MIN_MTU" ] && cand="$GFT_MIN_MTU"

  best="$cand"
  gft_gre_set_mtu "$best" || true

  # verify inside the tunnel; step down 8 bytes at a time while packets drop
  local tries=0
  while [ "$tries" -lt 6 ] && [ "$best" -ge "$GFT_MIN_MTU" ]; do
    out="$(net_ping_host "$peer_gre" 4 2)"
    loss="${out##* }"
    # a full-size datagram must fit without fragmenting, otherwise the
    # tunnel loses packets that are larger than the real path MTU
    if ! net_probe_payload "$peer_gre" $(( best - 28 )) 2; then
      warn "a $(( best - 28 )) byte payload could not pass at mtu $best"
      loss=100
    fi
    if [ "${loss:-100}" = "0" ]; then
      break
    fi
    warn "mtu $best shows ${loss}% loss over the tunnel — stepping down"
    best=$(( best - 8 ))
    [ "$best" -lt "$GFT_MIN_MTU" ] && { best="$GFT_MIN_MTU"; }
    gft_gre_set_mtu "$best" || true
    tries=$(( tries + 1 ))
  done

  out="$(net_ping_host "$peer_gre" 4 2)"
  loss="${out##* }"
  cfg_set TUNNEL_MTU "$best"
  cfg_set TUNNEL_MTU_LOSS "${loss:-0}"
  cfg_set TUNNEL_MTU_UPDATED "$(date '+%Y-%m-%d %H:%M:%S')"
  ok "best MTU: ${C_BOLD}${best}${C_0} (tunnel loss ${loss:-?}%)"
  _log OPT "mtu=$best loss=${loss:-?} path_mtu=$path_mtu iface=$iface iface_mtu=$iface_mtu"
  printf '%s mtu=%s loss=%s path_mtu=%s iface=%s iface_mtu=%s\n' \
    "$(date '+%F %T')" "$best" "${loss:-?}" "$path_mtu" "${iface:-?}" "$iface_mtu" >>"$GFT_OPT_LOG" 2>/dev/null || true
  GFT_BEST_MTU="$best"
  GFT_BEST_MTU_LOSS="${loss:-0}"

  # The MSS clamp on the relay depends on the MTU, so keep it in step.
  if declare -F fw_refresh_mss >/dev/null 2>&1; then
    local want; want="$(fw_mss_value)"
    if [ "$(cfg_get MSS_CLAMPED)" != "$want" ]; then
      if fw_refresh_mss >/dev/null 2>&1; then
        cfg_set MSS_CLAMPED "$want"
        dim "  MSS clamp refreshed to $want bytes"
      fi
    fi
  fi
}

net_hops_to() {
  local dst="$1" t out replies
  for t in $(seq 1 20); do
    out="$(net_ping_host "$dst" 1 1 "$t")"
    replies="${out%% *}"
    if [ "${replies:-0}" -ge 1 ]; then printf '%s' "$t"; return 0; fi
  done
  return 1
}

net_optimize_ttl() {
  local peer_pub peer_gre hops out loss ttl cur best_ttl best_loss
  peer_pub="$(cfg_get PEER_PUBLIC_IP)"
  peer_gre="$(cfg_get GRE_IP_REMOTE)"

  step "TTL autotune"
  hops="$(net_hops_to "$peer_pub" || true)"
  if is_uint "$hops"; then
    info "peer is ${C_BOLD}${hops}${C_0} hops away — outer TTL must be at least $(( hops + 1 ))"
  else
    warn "could not measure hop count (ICMP filtered) — testing standard TTL values"
  fi

  local -a cands=()
  local min_ttl=1
  if is_uint "$hops"; then min_ttl=$(( hops + 1 )); fi
  # Only standard, conservative TTL values are candidates: a TTL of
  # "hop count + 2" would work today and break the moment the route
  # changes, so the hop count is used as a floor instead of a target.
  for ttl in "$GFT_DEFAULT_TTL" 128 192 255; do
    [ "$ttl" -ge "$min_ttl" ] && cands+=("$ttl")
  done
  cur="$(cfg_get TUNNEL_TTL)"
  is_uint "$cur" && [ "$cur" -ge "$min_ttl" ] && cands+=("$cur")

  # unique + sorted
  local -a uniq=()
  local c d dup
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    dup=0
    for d in "${uniq[@]:-}"; do [ "$d" = "$c" ] && dup=1; done
    if [ "$dup" = "0" ] && [ "$c" -ge 1 ] && [ "$c" -le 255 ]; then
      uniq+=("$c")
    fi
  done < <(printf '%s\n' "${cands[@]:-}" | sort -n)

  best_ttl=""
  best_loss=101
  for ttl in "${uniq[@]}"; do
    gft_gre_set_ttl "$ttl" || true
    out="$(net_ping_host "$peer_gre" 4 2)"
    loss="${out##* }"
    is_uint "$loss" || loss=100
    dim "  ttl $ttl → loss ${loss}%"
    if [ "$loss" -lt "$best_loss" ]; then
      best_loss="$loss"
      best_ttl="$ttl"
    fi
  done

  if [ -z "$best_ttl" ]; then
    best_ttl="$GFT_DEFAULT_TTL"
    warn "no TTL candidate answered — keeping $best_ttl"
  fi
  gft_gre_set_ttl "$best_ttl" || true
  cfg_set TUNNEL_TTL "$best_ttl"
  cfg_set TUNNEL_TTL_LOSS "$best_loss"
  cfg_set TUNNEL_TTL_UPDATED "$(date '+%Y-%m-%d %H:%M:%S')"
  cfg_set TUNNEL_TTL_HOPS "${hops:-unknown}"
  ok "best TTL: ${C_BOLD}${best_ttl}${C_0} (tunnel loss ${best_loss}%)"
  _log OPT "ttl=$best_ttl loss=$best_loss hops=${hops:-unknown}"
  printf '%s ttl=%s loss=%s hops=%s\n' \
    "$(date '+%F %T')" "$best_ttl" "$best_loss" "${hops:-unknown}" >>"$GFT_OPT_LOG" 2>/dev/null || true
  GFT_BEST_TTL="$best_ttl"
  GFT_BEST_TTL_LOSS="$best_loss"
}

net_optimize_all() {
  gft_gre_ensure_up || return 1
  net_optimize_mtu
  net_optimize_ttl
}

# Hourly watchdog: makes sure the device is still there and the peer answers
net_watchdog() {
  local peer_gre out replies
  if ! gft_gre_dev_exists; then
    warn "GRE device $GFT_TUN_DEV disappeared — recreating"
    gft_gre_ensure_up || return 1
  fi
  peer_gre="$(cfg_get GRE_IP_REMOTE)"
  out="$(net_ping_host "$peer_gre" 3 2)"
  replies="${out%% *}"
  if [ "${replies:-0}" -eq 0 ]; then
    warn "peer $peer_gre is not answering over the tunnel — resetting the link"
    gft_gre_destroy
    gft_gre_ensure_up || return 1
    out="$(net_ping_host "$peer_gre" 3 2)"
    replies="${out%% *}"
    [ "${replies:-0}" -ge 1 ] && ok "tunnel recovered" || warn "tunnel is still down"
  fi
  return 0
}

# ------------------------------------------------------------
# sysctl — forwarding, tunnel friendly rp_filter and a small
# set of kernel tweaks that make the tunnel faster and lighter:
#   * tcp_mtu_probing detects PMTU black holes (very common when
#     ICMP is filtered on the Iranian side) instead of stalling,
#   * BBR + fq keep throughput high and bufferbloat low on the
#     relay, with no extra userspace process to feed.
# ------------------------------------------------------------
sysctl_supports_bbr() {
  case "${GFT_TCP_CC:-auto}" in
    none|off|0) return 1 ;;
    cubic)     return 1 ;;
    bbr)       return 0 ;;
  esac
  if have modprobe; then
    mutq modprobe tcp_bbr || true
  fi
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
}

sysctl_settings() {
  echo "net.ipv4.ip_forward = 1"
  echo "net.ipv4.conf.all.rp_filter = 2"
  echo "net.ipv4.conf.default.rp_filter = 2"
  if [ "${GFT_TUNE_NETWORK:-1}" = "1" ]; then
    echo "net.ipv4.tcp_mtu_probing = 1"
    if sysctl_supports_bbr; then
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    fi
  fi
}

sysctl_setup() {
  if [ "$GFT_DRY_RUN" != "1" ]; then
    mkdir -p "$GFT_SYSCTL_DIR" 2>/dev/null || true
  fi
  {
    echo "# Managed by ${GFT_APP_NAME} — do not edit by hand"
    sysctl_settings
  } | put_file "$GFT_SYSCTL_FILE"
  sysctl_apply_now || true
  ok "IPv4 forwarding enabled (persistent)"
}

# Applies every setting from the drop-in to the running kernel
sysctl_apply_now() {
  local line key val applied=0 bbr=0
  local settings
  if [ -f "$GFT_SYSCTL_FILE" ]; then
    settings="$(grep -v '^#' "$GFT_SYSCTL_FILE" | grep '=')"
  else
    settings="$(sysctl_settings)"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="$(printf '%s' "$line" | cut -d= -f1 | tr -d ' ')"
    val="$(printf '%s' "$line" | cut -d= -f2- | tr -d ' ')"
    if mutq sysctl -q -w "$key=$val"; then
      applied=$(( applied + 1 ))
      [ "$key" = "net.ipv4.tcp_congestion_control" ] && bbr=1
    elif [ "$GFT_DRY_RUN" != "1" ]; then
      warn "could not apply $key=$val on this kernel"
    fi
  done <<<"$settings"
  [ "$bbr" = "1" ] && dim "  kernel: BBR congestion control + fq qdisc enabled"
  return 0
}

sysctl_remove() {
  if [ -f "$GFT_SYSCTL_FILE" ]; then
    mutq rm -f "$GFT_SYSCTL_FILE"
    ok "removed $GFT_SYSCTL_FILE"
  fi
}

# ------------------------------------------------------------
# Probe helpers used by `gft test`
# ------------------------------------------------------------
net_tcp_check() {
  local host="$1" port="$2" to="${3:-3}"
  if have timeout; then
    timeout "$to" bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
  else
    bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
  fi
}

net_udp_check() {
  # UDP has no handshake: a successful send only proves the socket opened
  local host="$1" port="$2"
  if have nc; then
    nc -zu -w 2 "$host" "$port" >/dev/null 2>&1
  fi
  return 0
}
