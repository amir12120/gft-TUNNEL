#!/usr/bin/env bash
# ============================================================
# gft-TUNNEL — lib/relay.sh
#
# The "kernel" relay: a plain port forward over the GRE link, with
# NO port knowledge on the foreign side.
#
#   client → IranIP:PORT  ─DNAT→  <peer tunnel IP>:PORT  (inside GRE)
#   panel  ─reply→ 10.99.99.1  ─MASQUERADE→  clientIP  → client
#
# This is the same shape as any "iptables DNAT + MASQUERADE" tunnel
# recipe — the only difference is that the destination is the address
# the GRE link generated instead of the server's main IP.
#
#   * Iran owns the ports. With a port list only those ports are
#     forwarded; with an empty list EVERY port is forwarded (the SSH
#     port is always kept local so the relay can never be locked out).
#   * The foreign server declares nothing: it accepts whatever arrives
#     on the tunnel device and delivers it to the panel. Its optional
#     DNAT rule does not mention a single port.
#   * No frp runs on either side in this mode.
#
# Mode lives in the state file as RELAY_MODE=frp|dnat and is switched
# with `gft relay frp|dnat` (both sides, then `gft restart`).
# ============================================================

[ -n "${GFT_RELAY_LOADED:-}" ] && return 0
GFT_RELAY_LOADED=1

relay_mode()     { cfg_get RELAY_MODE frp; }
relay_mode_dnat() { [ "$(relay_mode)" = "dnat" ]; }
relay_tun_dev()  { cfg_get TUN_DEV "$GFT_TUN_DEV"; }

# Ports that must stay on THIS machine even when everything else is
# forwarded: the SSH port(s) plus any extra port the user pinned with
# `gft set keep-local <ports>`. Without this a catch-all DNAT would
# swallow SSH and lock the operator out of the relay.
relay_keep_local_csv() {
  local p out="" extra
  extra="$(cfg_get KEEP_LOCAL_PORTS | tr ',' ' ')"
  for p in $(ssh_ports 2>/dev/null) $extra; do
    is_port "$p" || continue
    case ",$out," in *",$p,"*) continue ;; esac
    if [ -z "$out" ]; then out="$p"; else out="$out,$p"; fi
  done
  printf '%s' "$out"
}

# Splits a port csv into `multiport` sized chunks (one per line).
relay_mp_chunks() {
  local csv="$1" p chunk="" n=0
  for p in $(printf '%s' "$csv" | tr ',' ' '); do
    if [ -z "$chunk" ]; then chunk="$p"; else chunk="$chunk,$p"; fi
    n=$(( n + 1 ))
    if [ "$n" -ge "$GFT_FW_MAX_MPORTS" ]; then
      printf '%s\n' "$chunk"; chunk=""; n=0
    fi
  done
  [ -n "$chunk" ] && printf '%s\n' "$chunk"
  return 0
}

# --- Iran side (the relay) -------------------------------------------------
# Rewrites the user traffic to the peer's tunnel address and masquerades
# it, so the replies always come back through the tunnel — no route, no
# frp and no port list is needed on the foreign server.
relay_nat_specs() {
  relay_mode_dnat || return 0
  [ "$(cfg_get ROLE)" = "iran" ] || return 0

  local dev peer_gre ports csv keep proto chunk
  dev="$(relay_tun_dev)"
  peer_gre="$(cfg_get GRE_IP_REMOTE "$GFT_DEFAULT_GRE_IP_FOREIGN")"
  ports="$(cfg_get TUNNEL_PORTS)"

  if [ -n "$ports" ]; then
    # a port list was given: forward exactly those ports (the ports live
    # on Iran; the foreign side never sees this list)
    csv="$(ports_list_csv "$ports")"
    for proto in tcp udp; do
      while IFS= read -r chunk; do
        [ -n "$chunk" ] || continue
        printf 'nat|PREROUTING|-p %s -m multiport --dports %s -j DNAT --to-destination %s\n' \
          "$proto" "$chunk" "$peer_gre"
      done < <(relay_mp_chunks "$csv")
    done
  else
    # no port list at all: forward everything except the ports that must
    # stay on this machine (SSH by default)
    keep="$(relay_keep_local_csv)"
    for proto in tcp udp; do
      if [ -n "$keep" ]; then
        printf 'nat|PREROUTING|-p %s -m multiport ! --dports %s -j DNAT --to-destination %s\n' \
          "$proto" "$keep" "$peer_gre"
      else
        printf 'nat|PREROUTING|-p %s -j DNAT --to-destination %s\n' "$proto" "$peer_gre"
      fi
    done
  fi

  # the panel's replies leave through the tunnel, so the source has to be
  # the tunnel address for the return path to exist at all
  printf 'nat|POSTROUTING|-o %s -j MASQUERADE\n' "$dev"
  # DNAT'ed packets are FORWARDed — a default-deny FORWARD policy (ufw!)
  # would otherwise blackhole them silently
  printf 'filter|FORWARD|-o %s -j ACCEPT\n' "$dev"
  printf 'filter|FORWARD|-i %s -j ACCEPT\n' "$dev"
}

# --- Foreign side (the panel host) -----------------------------------------
# Nothing here needs to know a port. Packets arrive on the tunnel device
# addressed to this server's tunnel IP and are delivered locally, where
# the panel listens on 0.0.0.0 — that is the whole "foreign listens on
# every port" behaviour.
#
# The only optional extra: when the panel is pinned to a specific local
# address (LOCAL_TARGET_IP, e.g. 127.0.0.1) a single, port-less DNAT
# hands every forwarded port to it.
relay_forward_specs() {
  relay_mode_dnat || return 0
  [ "$(cfg_get ROLE)" = "foreign" ] || return 0

  local dev target own proto
  dev="$(relay_tun_dev)"
  target="$(cfg_get LOCAL_TARGET_IP)"
  own="$(cfg_get GRE_IP_LOCAL)"
  is_ipv4 "$target" || return 0
  [ "$target" != "$own" ] || return 0

  for proto in tcp udp; do
    printf 'nat|PREROUTING|-i %s -p %s -j DNAT --to-destination %s\n' "$dev" "$proto" "$target"
  done
  printf 'filter|FORWARD|-i %s -j ACCEPT\n' "$dev"
}

# The panel's SYN-ACKs come back through the tunnel and advertise MSS 1460,
# which no longer fits into the GRE MTU — clamp everything arriving from the
# tunnel (port-agnostic, so a port list is not required).
relay_mss_specs() {
  relay_mode_dnat || return 0
  [ "$(cfg_get ROLE)" = "iran" ] || return 0
  printf 'mangle|PREROUTING|-i %s -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss %s\n' \
    "$(relay_tun_dev)" "$(fw_mss_value)"
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
# Restart everything after a mode change (both roles, both modes)
relay_services_restart() {
  is_systemd || return 0
  if relay_mode_dnat; then
    mutq systemctl restart gft-tunnel.service || true
    mutq systemctl stop frps.service 2>/dev/null || true
    mutq systemctl stop frpc.service 2>/dev/null || true
  else
    services_restart_role || true
  fi
}

# Show the effective data path (used by status/doctor)
relay_describe() {
  if relay_mode_dnat; then
    if [ -n "$(cfg_get TUNNEL_PORTS)" ]; then
      printf 'kernel port forward over GRE — %s port(s) declared on THIS side only, nothing on the foreign side' \
        "$(ports_count "$(cfg_get TUNNEL_PORTS)")"
    else
      printf 'kernel port forward over GRE — ALL ports forwarded (except %s), nothing declared on the foreign side' \
        "$(relay_keep_local_csv)"
    fi
  else
    printf 'frp reverse tunnel — the foreign frpc registers the ports with the Iranian frps'
  fi
}
