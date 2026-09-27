#!/usr/bin/env bash
# ============================================================
# gft-TUNNEL — lib/relay.sh
#
# Optional relay mode: "dnat" — kernel-space forwarding over the GRE
# link, with NO port knowledge on the foreign side.
#
#   user → IranIP:PORT  ─DNAT→  10.99.99.2:PORT  (inside GRE)  → panel
#   panel reply ─→ 10.99.99.1  ─SNAT→  userIP:ephemeral  → user
#
# In this mode the foreign server runs NO frp at all and does not know
# the config ports: it only forwards (ip_forward) whatever arrives on
# the tunnel interface. The Iranian relay owns the port list and rewrites
# the destination; SNAT on the relay guarantees the replies come back
# through the tunnel even without foreign routes.
#
# Mode is stored as RELAY_MODE=frp (default) | dnat in the state file
# and switched with `gft relay dnat|frp` (which writes both sides'
# configs and restarts everything).
# ============================================================

[ -n "${GFT_RELAY_LOADED:-}" ] && return 0
GFT_RELAY_LOADED=1

relay_mode() { cfg_get RELAY_MODE frp; }

# The relay mode only makes sense with a configured port list
relay_require_ports() {
  [ -n "$(cfg_get TUNNEL_PORTS)" ] || die "no tunnelled ports configured — run: sudo $GFT_CLI_NAME ports set <ports>"
}

# --- Iran side -------------------------------------------------------------
# Rewrites user traffic arriving on the config ports to the peer's tunnel
# address and SNATs the replies so they return through the tunnel.
relay_nat_specs() {
  [ "$(relay_mode)" = "dnat" ] || return 0
  [ "$(cfg_get ROLE)" = "iran" ] || return 0
  local peer_gre ports p
  peer_gre="$(cfg_get GRE_IP_REMOTE "$GFT_DEFAULT_GRE_IP_FOREIGN")"
  ports="$(cfg_get TUNNEL_PORTS)"
  [ -n "$ports" ] || return 0
  for p in $(ports_parse "$ports" 2>/dev/null); do
    printf 'nat|PREROUTING|-p tcp --dport %s -j DNAT --to-destination %s:%s\n' "$p" "$peer_gre" "$p"
    printf 'nat|PREROUTING|-p udp --dport %s -j DNAT --to-destination %s:%s\n' "$p" "$peer_gre" "$p"
  done
  printf 'nat|POSTROUTING|-o %s -j SNAT --to-source %s\n' "$(cfg_get TUN_DEV "$GFT_TUN_DEV")" "$(cfg_get GRE_IP_LOCAL "$GFT_DEFAULT_GRE_IP_IRAN")"
  # after the DNAT the packets are FORWARDED (not INPUT) — make sure a
  # restrictive FORWARD policy (ufw!) cannot blackhole them
  printf 'filter|FORWARD|-o %s -j ACCEPT\n' "$(cfg_get TUN_DEV "$GFT_TUN_DEV")"
}

# --- Foreign side ----------------------------------------------------------
# No ports known to any frp: deliver to the local panel. If the panel
# listens on something other than this server's tunnel address, a local
# DNAT rewrites the destination (127.0.0.1 targets need route_localnet,
# which sysctl_settings enables for this exact case).
relay_forward_specs() {
  [ "$(relay_mode)" = "dnat" ] || return 0
  [ "$(cfg_get ROLE)" = "foreign" ] || return 0
  local ports target p
  ports="$(cfg_get TUNNEL_PORTS)"
  [ -n "$ports" ] || return 0
  target="$(cfg_get LOCAL_TARGET_IP "127.0.0.1")"
  for p in $(ports_parse "$ports" 2>/dev/null); do
    printf 'nat|PREROUTING|-i %s -p tcp --dport %s -j DNAT --to-destination %s:%s\n' \
      "$(cfg_get TUN_DEV "$GFT_TUN_DEV")" "$p" "$target" "$p"
    printf 'nat|PREROUTING|-i %s -p udp --dport %s -j DNAT --to-destination %s:%s\n' \
      "$(cfg_get TUN_DEV "$GFT_TUN_DEV")" "$p" "$target" "$p"
  done
}

# In dnat mode the relay must also clamp the SYN-ACKs that come back from
# the panel inside the tunnel (they carry the CONFIG port as their SOURCE
# port). Without this the panel advertises MSS 1460 and upstream packets
# blackhole on the GRE MTU.
relay_mss_specs() {
  [ "$(relay_mode)" = "dnat" ] || return 0
  [ "$(cfg_get ROLE)" = "iran" ] || return 0
  local ports; ports="$(cfg_get TUNNEL_PORTS)"
  [ -n "$ports" ] || return 0
  local mss; mss="$(fw_mss_value)"
  local chunk="" n=0 p
  for p in $(ports_parse "$ports" 2>/dev/null); do
    if [ -z "$chunk" ]; then chunk="$p"; else chunk="$chunk,$p"; fi
    n=$(( n + 1 ))
    if [ "$n" -ge "$GFT_FW_MAX_MPORTS" ]; then
      printf 'mangle|PREROUTING|-i %s -p tcp --tcp-flags SYN,RST SYN -m multiport --sports %s -j TCPMSS --set-mss %s\n' \
        "$(cfg_get TUN_DEV "$GFT_TUN_DEV")" "$chunk" "$mss"
      chunk=""; n=0
    fi
  done
  [ -n "$chunk" ] && printf 'mangle|PREROUTING|-i %s -p tcp --tcp-flags SYN,RST SYN -m multiport --sports %s -j TCPMSS --set-mss %s\n' \
    "$(cfg_get TUN_DEV "$GFT_TUN_DEV")" "$chunk" "$mss"
  return 0
}

# Hook called by fw_rule_specs — returns the extra rules of this module
relay_rule_specs() {
  relay_nat_specs
  relay_forward_specs
}

# Hook called by fw_mss_specs — extra clamps of this module
relay_extra_mss_specs() {
  relay_mss_specs
}

# --- Config / service writers ---------------------------------------------
# Iran side in dnat mode: no frps needed (the kernel is the relay).
# Foreign side in dnat mode: no frpc, no frp config at all.
relay_units_enable() {
  [ "$(relay_mode)" = "dnat" ] || return 1
  is_systemd || return 0
  local role; role="$(cfg_get ROLE)"
  # the frp service of THIS role is off in dnat mode
  if [ "$role" = "iran" ]; then
    mutq systemctl disable --now frps.service 2>/dev/null || true
  else
    mutq systemctl disable --now frpc.service 2>/dev/null || true
  fi
  return 0
}

# Restart everything after a mode change (both roles, both modes)
relay_services_restart() {
  local mode; mode="$(relay_mode)"
  if [ "$mode" = "dnat" ]; then
    is_systemd || return 0
    mutq systemctl restart gft-tunnel.service || true
    local role; role="$(cfg_get ROLE)"
    if [ "$role" = "iran" ]; then
      mutq systemctl stop frps.service 2>/dev/null || true
    else
      mutq systemctl stop frpc.service 2>/dev/null || true
    fi
  else
    services_restart_role || true
  fi
}

# Show the effective data path (used by status/doctor)
relay_describe() {
  case "$(relay_mode)" in
    dnat)
      printf 'kernel DNAT/SNAT over GRE — foreign side runs NO frp and knows no ports'
      ;;
    *)
      printf 'frp reverse tunnel — foreign side registers the config ports'
      ;;
  esac
}
