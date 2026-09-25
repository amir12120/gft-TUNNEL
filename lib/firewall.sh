#!/usr/bin/env bash
# ============================================================
# GRE+FRP-TUNNEL — lib/firewall.sh
#
# Firewall rules for the tunnel. Three hard rules of this file:
#   1. It only ever ADDS ACCEPT rules. Nothing is ever dropped or
#      rejected, so SSH can not be locked out.
#   2. Every rule carries the comment "gre-frp-tunnel" and can be
#      removed again by `gre-frp-tunnel uninstall`.
#   3. The exact rules that were applied are recorded in
#      <state>/firewall.rules, so teardown never depends on the
#      current configuration.
#
# Works with plain iptables, with ufw (rules are inserted ahead of
# ufw's own chains) and with firewalld (direct rules).
#
# Rule record format, one per line:
#     <table>|<chain>|<spec>
# ============================================================

[ -n "${GRE_FRP_FW_LOADED:-}" ] && return 0
GRE_FRP_FW_LOADED=1

GRE_FRP_FW_TAG="gre-frp-tunnel"
GRE_FRP_FW_RULES_FILE="$GRE_FRP_STATE_DIR/firewall.rules"
GRE_FRP_FW_MAX_MPORTS=15

firewalld_active() {
  have firewall-cmd && firewall-cmd --state >/dev/null 2>&1
}

# ------------------------------------------------------------
# The MSS clamp
#
# The client-facing TCP connections are terminated by frps on the
# Iranian server and then relayed over the GRE link. Without a clamp
# the client is allowed to send 1460 byte segments, which no longer
# fit into a GRE MTU of ~1476 and get fragmented (or dropped when DF
# is set) — the classic source of "random" packet loss on a relay.
# Clamping the advertised MSS to GRE_MTU - 40 fixes that.
# ------------------------------------------------------------
fw_mss_value() {
  local mtu; mtu="$(cfg_get TUNNEL_MTU "$GRE_FRP_DEFAULT_MTU")"
  is_uint "$mtu" || mtu="$GRE_FRP_DEFAULT_MTU"
  local mss=$(( mtu - 40 ))
  [ "$mss" -lt 536 ] && mss=536
  [ "$mss" -gt 1460 ] && mss=1460
  printf '%s' "$mss"
}

# Emits the mangle rules that clamp the MSS for the tunnelled ports
fw_mss_specs() {
  local role; role="$(cfg_get ROLE)"
  [ "$role" = "iran" ] || return 0
  local ports; ports="$(cfg_get TUNNEL_PORTS)"
  [ -n "$ports" ] || return 0
  local mss; mss="$(fw_mss_value)"
  local chunk="" n=0 p

  for p in $(ports_parse "$ports" 2>/dev/null); do
    if [ -z "$chunk" ]; then chunk="$p"; else chunk="$chunk,$p"; fi
    n=$(( n + 1 ))
    if [ "$n" -ge "$GRE_FRP_FW_MAX_MPORTS" ]; then
      printf 'mangle|PREROUTING|-p tcp --tcp-flags SYN,RST SYN -m multiport --dports %s -j TCPMSS --set-mss %s\n' "$chunk" "$mss"
      chunk=""; n=0
    fi
  done
  if [ -n "$chunk" ]; then
    printf 'mangle|PREROUTING|-p tcp --tcp-flags SYN,RST SYN -m multiport --dports %s -j TCPMSS --set-mss %s\n' "$chunk" "$mss"
  fi
}

# ------------------------------------------------------------
# Rule list
# ------------------------------------------------------------
# Emits one rule per line:  <table>|<chain>|<spec>
fw_rule_specs() {
  local role dev peer_pub gre_remote ctrl ports p local_ip
  role="$(cfg_get ROLE)"
  dev="$(cfg_get TUN_DEV "$GRE_FRP_TUN_DEV")"
  peer_pub="$(cfg_get PEER_PUBLIC_IP)"
  gre_remote="$(cfg_get GRE_IP_REMOTE)"
  ctrl="$(cfg_get CTRL_PORT "$GRE_FRP_DEFAULT_CTRL_PORT")"
  ports="$(cfg_get TUNNEL_PORTS)"
  local_ip="$(cfg_get LOCAL_TARGET_IP "127.0.0.1")"

  # 1. GRE (IP protocol 47) from the peer only
  [ -n "$peer_pub" ] && printf 'filter|INPUT|-p gre -s %s -j ACCEPT\n' "$peer_pub"
  # 2. anything arriving on the tunnel interface
  printf 'filter|INPUT|-i %s -j ACCEPT\n' "$dev"

  if [ "$role" = "iran" ]; then
    # 3. frp control port — reachable over the tunnel only
    printf 'filter|INPUT|-i %s -p tcp --dport %s -j ACCEPT\n' "$dev" "$ctrl"
    # 4. the tunnelled ports, reachable by VPN clients on the public IP
    for p in $(ports_parse "$ports" 2>/dev/null); do
      printf 'filter|INPUT|-p tcp --dport %s -j ACCEPT\n' "$p"
      printf 'filter|INPUT|-p udp --dport %s -j ACCEPT\n' "$p"
    done
    # 5. and the MSS clamp that keeps relayed TCP inside the tunnel MTU
    fw_mss_specs
  else
    # the foreign side only needs the peer to reach it; the panel itself
    # is normally bound to localhost and needs no public rule at all
    case "$local_ip" in
      127.0.0.1|::1|localhost) : ;;
      *)
        for p in $(ports_parse "$ports" 2>/dev/null); do
          printf 'filter|INPUT|-p tcp --dport %s -j ACCEPT\n' "$p"
          printf 'filter|INPUT|-p udp --dport %s -j ACCEPT\n' "$p"
        done
        ;;
    esac
  fi
}

# Refuse to generate anything dangerous — a safety net that the test
# suite also asserts.
fw_assert_safe() {
  local spec
  while IFS= read -r spec; do
    case "$spec" in
      *"-j DROP"*|*"-j REJECT"*|*"-F "*|*"--flush"*)
        err "refusing to apply a destructive firewall rule: $spec"
        return 1
        ;;
    esac
  done < <(fw_rule_specs)
  return 0
}

# ------------------------------------------------------------
# Applying / removing single rules
# ------------------------------------------------------------
fw_apply_one() { # <table> <chain> <spec...>
  local table="$1" chain="$2"; shift 2
  local full="$* -m comment --comment $GRE_FRP_FW_TAG"

  if [ "$GRE_FRP_DRY_RUN" = "1" ]; then
    printf '%s  + iptables -t %s -I %s 1 %s%s\n' "$C_DIM" "$table" "$chain" "$full" "$C_0"
    return 0
  fi

  if ! have iptables; then
    warn "iptables is not installed — skipping: $full"
    return 1
  fi

  if firewalld_active; then
    # shellcheck disable=SC2086
    mutq firewall-cmd --direct --permanent --add-rule ipv4 "$table" "$chain" 0 $full || true
    # shellcheck disable=SC2086
    mutq firewall-cmd --direct --add-rule ipv4 "$table" "$chain" 0 $full || true
    return 0
  fi

  # shellcheck disable=SC2086
  iptables -t "$table" -C "$chain" $full >/dev/null 2>&1 && return 0   # already there
  # shellcheck disable=SC2086
  mutq iptables -t "$table" -I "$chain" 1 $full
}

fw_remove_one() { # <table> <chain> <spec...>
  local table="$1" chain="$2"; shift 2
  local full="$* -m comment --comment $GRE_FRP_FW_TAG"

  if [ "$GRE_FRP_DRY_RUN" = "1" ]; then
    printf '%s  + iptables -t %s -D %s %s%s\n' "$C_DIM" "$table" "$chain" "$full" "$C_0"
    return 0
  fi

  if firewalld_active; then
    # shellcheck disable=SC2086
    mutq firewall-cmd --direct --permanent --remove-rule ipv4 "$table" "$chain" 0 $full || true
    # shellcheck disable=SC2086
    mutq firewall-cmd --direct --remove-rule ipv4 "$table" "$chain" 0 $full || true
    return 0
  fi

  have iptables || return 1
  local guard=0
  # shellcheck disable=SC2086
  while iptables -t "$table" -C "$chain" $full >/dev/null 2>&1 && [ "$guard" -lt 20 ]; do
    # shellcheck disable=SC2086
    mutq iptables -t "$table" -D "$chain" $full || break
    guard=$(( guard + 1 ))
  done
  return 0
}

# Splits "table|chain|spec" lines from a string and applies them
_fw_for_each() { # <action> <rules-string>
  local action="$1" rules="$2" line table chain spec n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    table="${line%%|*}"
    line="${line#*|}"
    chain="${line%%|*}"
    spec="${line#*|}"
    # shellcheck disable=SC2086
    "$action" "$table" "$chain" $spec
    n=$(( n + 1 ))
  done <<<"$rules"
  printf '%s' "$n"
}

fw_record() { printf '%s\n' "$1" | grep -v '^$' | put_file "$GRE_FRP_FW_RULES_FILE"; }

fw_recorded_rules() {
  [ -f "$GRE_FRP_FW_RULES_FILE" ] && cat "$GRE_FRP_FW_RULES_FILE"
}

fw_recorded_table() { # <table>
  fw_recorded_rules | awk -F'|' -v t="$1" '$1 == t'
}

# ------------------------------------------------------------
# Public entry points
# ------------------------------------------------------------
fw_apply() {
  fw_assert_safe || return 1

  # stale MSS clamps from an earlier MTU are removed before the new ones
  # are added, otherwise every hourly run would stack another rule
  local stale
  stale="$(fw_recorded_table mangle)"
  if [ -n "$stale" ]; then
    _fw_for_each fw_remove_one "$stale" >/dev/null
  fi

  local rules n
  rules="$(fw_rule_specs)"
  n="$(_fw_for_each fw_apply_one "$rules")"
  fw_record "$rules"
  ok "$n firewall rule(s) in place (ACCEPT only — nothing is blocked)"
  if [ "$(cfg_get ROLE)" = "iran" ]; then
    cfg_set MSS_CLAMPED "$(fw_mss_value)"
    dim "  MSS clamped to $(fw_mss_value) bytes for the tunnelled TCP ports"
  fi
  return 0
}

fw_remove() {
  local rules n
  rules="$(fw_recorded_rules)"
  [ -n "$rules" ] || rules="$(fw_rule_specs)"
  n="$(_fw_for_each fw_remove_one "$rules")"
  [ "$GRE_FRP_DRY_RUN" = "1" ] || rm -f "$GRE_FRP_FW_RULES_FILE" 2>/dev/null || true
  ok "$n firewall rule(s) removed"
  return 0
}

# Re-applies only the MSS clamp after the MTU changed
fw_refresh_mss() {
  [ "$(cfg_get ROLE)" = "iran" ] || return 0
  local stale; stale="$(fw_recorded_table mangle)"
  [ -n "$stale" ] && _fw_for_each fw_remove_one "$stale" >/dev/null
  local mss_rules
  mss_rules="$(fw_mss_specs)"
  [ -n "$mss_rules" ] || return 0
  _fw_for_each fw_apply_one "$mss_rules" >/dev/null
  # keep the record in sync: filter rules as they are + the new clamp
  local keep; keep="$(fw_recorded_rules | awk -F'|' '$1 != "mangle"')"
  if [ -n "$keep" ]; then
    fw_record "$keep
$mss_rules"
  else
    fw_record "$mss_rules"
  fi
  return 0
}

fw_status() {
  local rules line table chain spec n=0 ok_count=0
  rules="$(fw_recorded_rules)"
  [ -n "$rules" ] || rules="$(fw_rule_specs)"
  if ! have iptables; then
    warn "iptables not installed"
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    table="${line%%|*}"; line="${line#*|}"
    chain="${line%%|*}"; spec="${line#*|}"
    # shellcheck disable=SC2086
    if iptables -t "$table" -C "$chain" $spec -m comment --comment "$GRE_FRP_FW_TAG" >/dev/null 2>&1; then
      printf '  %s✔%s %s %s %s\n' "$C_G" "$C_0" "$table" "$chain" "$spec"
      ok_count=$(( ok_count + 1 ))
    else
      printf '  %s✘%s %s %s %s\n' "$C_R" "$C_0" "$table" "$chain" "$spec"
    fi
    n=$(( n + 1 ))
  done <<<"$rules"
  dim "  ($ok_count of $n recorded rules are active)"
}

# Warn if ufw is active with a default-deny incoming policy — that is
# fine (we insert ACCEPT rules) but the user should know.
fw_report_backend() {
  if firewalld_active; then
    info "firewall backend: ${C_BOLD}firewalld${C_0} (using --direct rules)"
  elif have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    info "firewall backend: ${C_BOLD}ufw${C_0} (rules inserted into iptables INPUT)"
  elif have iptables; then
    info "firewall backend: ${C_BOLD}iptables${C_0}"
  else
    warn "no firewall tool detected"
  fi
}
