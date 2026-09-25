#!/usr/bin/env bash
# ============================================================
# gft-TUNNEL — test/smoke.sh
#
# A complete, hermetic test of the whole project. It never touches
# the host network, the host firewall or systemd: every privileged
# command (ip, iptables, systemctl, ping, curl, …) is replaced by a
# stub that records what it was asked to do, and every path the CLI
# writes to is redirected into a temporary directory.
#
# Usage:  bash test/smoke.sh            (verbose)
#         QUIET=1 bash test/smoke.sh    (only failures)
# ============================================================

set -u

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/gft"
STUB_DIR="$ROOT/test/stub"
WORK="${GFT_TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/gft0-smoke.XXXXXX")}"
QUIET="${QUIET:-0}"

C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_0=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'
  C_B=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
fi

PASS=0
FAIL=0
declare -a FAILURES=()

section() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }

ok_msg()   { PASS=$(( PASS + 1 )); [ "$QUIET" = "1" ] || printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad_msg()  {
  FAIL=$(( FAIL + 1 )); FAILURES+=("$1")
  printf '  %s✘%s %s\n' "$C_R" "$C_0" "$1"
  [ -n "${2:-}" ] && printf '      %s%s%s\n' "$C_D" "$2" "$C_0"
  return 0
}

assert_eq() { # <name> <actual> <expected>
  if [ "$2" = "$3" ]; then ok_msg "$1"; else bad_msg "$1" "expected [$3] | got [$2]"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then ok_msg "$1"; else bad_msg "$1" "value should not be [$3]"; fi
}
assert_contains() { # <name> <haystack> <needle>
  case "$2" in
    *"$3"*) ok_msg "$1" ;;
    *) bad_msg "$1" "missing text [$3] in: $(printf '%s' "$2" | head -c 300)" ;;
  esac
}
assert_not_contains() {
  case "$2" in
    *"$3"*) bad_msg "$1" "unexpected text [$3]" ;;
    *) ok_msg "$1" ;;
  esac
}
assert_file() { [ -f "$2" ] && ok_msg "$1" || bad_msg "$1" "missing file: $2"; }
assert_no_file() { [ ! -e "$2" ] && ok_msg "$1" || bad_msg "$1" "file should not exist: $2"; }
assert_rc() { # <name> <rc> <expected>
  if [ "$2" = "$3" ]; then ok_msg "$1"; else bad_msg "$1" "expected exit $3, got $2 (see $ENV/out.txt)"; fi
}
assert_gt() { # <name> <a> <b>  (a > b)
  if [ "${2:-0}" -gt "${3:-0}" ] 2>/dev/null; then ok_msg "$1"; else bad_msg "$1" "expected $2 > $3"; fi
}

# ------------------------------------------------------------
# Environment factory
# ------------------------------------------------------------
ENV=""
setup_env() { # <name>
  ENV="$WORK/$1"
  rm -rf "$ENV"
  mkdir -p "$ENV"/{bin,logs,etc,units,sysctl,run,state,stubtmp,modules,dl}
  export STUB_TMP="$ENV/stubtmp"

  export GFT_STATE_DIR="$ENV/state"
  export GFT_LOG_DIR="$ENV/logs"
  export GFT_RUN_DIR="$ENV/run"
  export GFT_FRP_ETC_DIR="$ENV/etc"
  export GFT_BIN_DIR="$ENV/bin"
  export GFT_SYSTEMD_DIR="$ENV/units"
  export GFT_SYSCTL_DIR="$ENV/sysctl"
  export GFT_MODULES_LOAD_DIR="$ENV/modules"
  export GFT_DL_DIR="$ENV/dl"
  export GFT_TEMPLATES_DIR="$ROOT/systemd"
  export GFT_CLI_PATH="$CLI"
  export GFT_SELF_DIR="$ROOT"

  export GFT_ALLOW_NON_ROOT=1
  export GFT_FORCE_SYSTEMD=1
  export GFT_NONINTERACTIVE=1
  export GFT_DRY_RUN=0
  export GFT_ASSUME_YES=1
  unset GFT_ROLE GFT_LOCAL_PUBLIC GFT_PEER_PUBLIC GFT_PORTS
  unset GFT_CTRL_PORT GFT_GRE_LOCAL GFT_GRE_REMOTE GFT_LOCAL_TARGET_IP
  unset GFT_ALLOW_SSH_PORT GFT_NO_SYSTEMD GFT_NO_TTY GFT_FORCE
  unset GFT_TCP_CC GFT_TUNE_NETWORK GFT_UPDATE_REF GFT_NO_MENU

  export STUB_PUBLIC_IP="203.0.113.10"
  export STUB_PEER_PUBLIC="198.51.100.9"
  export STUB_IFACE="eth0"
  export STUB_IFACE_MTU="1500"
  export STUB_PATH_MTU="1500"
  export STUB_HOPS="6"
  export STUB_GRE_REMOTE="10.99.99.2"
  export STUB_FRP_VERSION="0.99.0"
  export STUB_LISTEN="40001 443 2053"
  unset STUB_LOSS_AT_TTL STUB_LOSS_AT_MTU STUB_BAD_CHECKSUM STUB_FIREWALLD STUB_UFW STUB_TCP_OPEN

  PATH="$STUB_DIR:$PATH"
  export PATH
  : >"$ENV/out.txt"
}

run_cli() { # runs the CLI, captures combined output, sets RC
  local out="$ENV/out.txt"
  { bash "$CLI" "$@"; } >"$out" 2>&1
  RC=$?
  if [ "${VERBOSE:-0}" = "1" ]; then
    printf '%s' "$C_D"; sed 's/^/    | /' "$out"; printf '%s' "$C_0"
  fi
  return 0
}

state_get() { # <key>
  sed -n "s/^$1=//p" "$ENV/state/config.env" 2>/dev/null | tail -1
}

# state file without the keys that legitimately change on every run
# The token both servers must agree on, derived exactly like lib/frp.sh does
derived_token() { # [ip-a] [ip-b]
  local a="${1:-203.0.113.10}" b="${2:-198.51.100.9}" t
  if [ "$a" \> "$b" ]; then t="$a"; a="$b"; b="$t"; fi
  printf '%s' "gft-tunnel|${a}|${b}" | sha256sum | cut -c1-32
}

mask_state() {
  grep -v -E '^(TUNNEL_MTU_UPDATED|TUNNEL_TTL_UPDATED|FRP_INSTALLED_AT)=' \
    "$ENV/state/config.env" 2>/dev/null || true
}

# the stub keeps one state file per table (iptables.filter.state, …)
iptables_rules()   { cat "$ENV/stubtmp/iptables.filter.state" 2>/dev/null; }
iptables_mangle()  { cat "$ENV/stubtmp/iptables.mangle.state" 2>/dev/null; }
ip_log()          { cat "$ENV/stubtmp/ip.log" 2>/dev/null; }

install_iran() {
  run_cli install --role=iran --local-ip=203.0.113.10 --peer=198.51.100.9 --ports=443,2053
}

# A pre-seeded state file lets the fast tests exercise one subsystem
# (optimizer, firewall, ports, services) without paying for a full install.
seed_state() { # [role] [mtu] [ttl] [ports]
  local role="${1:-iran}" mtu="${2:-1476}" ttl="${3:-64}" ports="${4:-443,2053}"
  local lp="203.0.113.10" pp="198.51.100.9" gl="10.99.99.1" gr="10.99.99.2"
  if [ "$role" = "foreign" ]; then
    lp="198.51.100.9"; pp="203.0.113.10"; gl="10.99.99.2"; gr="10.99.99.1"; fi
  mkdir -p "$GFT_STATE_DIR" 2>/dev/null || true
  {
    echo "ROLE=$role"
    echo "LOCAL_PUBLIC_IP=$lp"
    echo "PEER_PUBLIC_IP=$pp"
    echo "GRE_IP_LOCAL=$gl"
    echo "GRE_IP_REMOTE=$gr"
    echo "GRE_PREFIX=30"
    echo "CTRL_PORT=40001"
    echo "TUNNEL_PORTS=$ports"
    echo "LOCAL_TARGET_IP=127.0.0.1"
    echo "TUN_DEV=gft0"
    echo "AUTH_TOKEN=0123456789abcdef0123456789abcdef"
    echo "TUNNEL_MTU=$mtu"
    echo "TUNNEL_TTL=$ttl"
    echo "UDP_PACKET_SIZE=1444"
  } >"$GFT_STATE_DIR/config.env"
  export STUB_GRE_REMOTE="$gr"
  [ "$role" = "foreign" ] && export STUB_PUBLIC_IP="$lp"
  return 0
}

# Runs a snippet with the project libraries loaded against the current env
lib_run() {
  ( cd "$ROOT" && bash -c "
    set -u
    . lib/common.sh; . lib/net.sh; . lib/frp.sh; . lib/firewall.sh; . lib/units.sh
    $1" ) 2>&1
}
install_foreign() {
  export STUB_PUBLIC_IP="198.51.100.9"     # the foreign box has the *other* public IP
  export STUB_GRE_REMOTE="10.99.99.1"       # its peer inside the tunnel is the relay
  run_cli install --role=foreign --local-ip=198.51.100.9 --peer=203.0.113.10 --ports=443,2053
}

# ============================================================
# 1. static checks
# ============================================================
t_static() {
  section "1. Static checks"
  local f rc=0
  for f in "$CLI" "$ROOT/install.sh" "$ROOT"/lib/*.sh "$ROOT"/test/*.sh "$ROOT"/test/stub/*; do
    [ -f "$f" ] || continue
    case "$f" in *.md|*.txt|*.yml) continue ;; esac
    bash -n "$f" || { rc=1; }
  done
  assert_rc "every script passes bash -n" "$rc" "0"

  if command -v shellcheck >/dev/null 2>&1; then
    # errors are fatal, warnings are reported but do not fail the suite
    local errs warns
    errs="$(shellcheck -S error -e SC1090,SC1091 "$CLI" "$ROOT"/lib/*.sh "$ROOT/install.sh" 2>&1 || true)"
    if [ -z "$errs" ]; then ok_msg "shellcheck reports no errors"
    else bad_msg "shellcheck found errors" "$(printf '%s' "$errs" | head -25)"; fi
    # shellcheck disable=SC2016
    warns="$(shellcheck -S warning -f gcc -e SC1090,SC1091 "$CLI" "$ROOT"/lib/*.sh "$ROOT/install.sh" 2>&1 | wc -l | tr -d ' ')"
    printf '  %s-%s shellcheck warning lines: %s\n' "$C_Y" "$C_0" "$warns"
  else
    printf '  %s-%s shellcheck not installed locally (CI installs it)\n' "$C_Y" "$C_0"
  fi

  # no destructive commands anywhere in the shipped code
  local pat bad=""
  for pat in 'iptables -F' 'iptables --flush' 'ufw disable' 'rm -rf /' 'shutdown ' 'reboot' ':(){'; do
    if grep -rn -- "$pat" "$CLI" "$ROOT/lib" "$ROOT/install.sh" 2>/dev/null | grep -v '^.*#' >/dev/null 2>&1; then
      bad="$bad [$pat]"
    fi
  done
  assert_eq "no destructive command in the code" "$bad" ""

  # the CLI must never emit a DROP/REJECT rule
  if grep -rn -- '-j DROP\|-j REJECT' "$ROOT/lib" "$CLI" 2>/dev/null | grep -v '"' >/dev/null 2>&1; then
    bad_msg "no DROP/REJECT in the firewall code" "found explicit drop rules"
  else
    ok_msg "no DROP/REJECT in the firewall code"
  fi
}

t_unit_templates() {
  section "2. systemd unit templates"
  local u
  for u in gft-tunnel.service gft-tunnel-optimize.service \
           gft-tunnel-optimize.timer gft-tunnel-frpupdate.service \
           gft-tunnel-frpupdate.timer frps.service frpc.service; do
    assert_file "template $u exists" "$ROOT/systemd/$u"
  done
  assert_contains "hourly timer is hourly" "$(cat "$ROOT/systemd/gft-tunnel-optimize.timer")" "OnUnitActiveSec=1h"
  assert_contains "optimizer runs at boot" "$(cat "$ROOT/systemd/gft-tunnel-optimize.timer")" "OnBootSec="
  assert_contains "tunnel unit recreates the link on boot" \
    "$(cat "$ROOT/systemd/gft-tunnel.service")" "ExecStart=__CLI__ service-up"
}

# ============================================================
# 3. pure helpers
# ============================================================
t_helpers() {
  section "3. Helper functions"
  setup_env helpers
  local out

  lib_eval() {
    ( cd "$ROOT" && bash -c '
      set -u
      . lib/common.sh; . lib/net.sh; . lib/frp.sh; . lib/firewall.sh
      '"$1" )
  }

  out="$(lib_eval 'is_ipv4 1.2.3.4 && echo yes || echo no')"
  assert_eq "is_ipv4 accepts 1.2.3.4" "$out" "yes"
  for bad in "1.2.3" "1.2.3.256" "abc" "" "1.2.3.4.5" "01.2.3.-4"; do
    out="$(lib_eval "is_ipv4 '$bad' && echo yes || echo no")"
    assert_eq "is_ipv4 rejects [$bad]" "$out" "no"
  done

  out="$(lib_eval 'ports_parse "443,8443,2000-2002" | paste -sd, -')"
  assert_eq "ports_parse expands ranges and sorts" "$out" "443,2000,2001,2002,8443"

  out="$(lib_eval 'ports_validate "443,2000-2010" && echo ok || echo bad')"
  assert_eq "ports_validate accepts a valid list" "$out" "ok"
  for bad in "0" "65536" "abc" "22-10" "443,," "443;rm -rf /"; do
    out="$(lib_eval "ports_validate '$bad' && echo ok || echo bad")"
    assert_eq "ports_validate rejects [$bad]" "$out" "bad"
  done

  out="$(lib_eval 'ports_ssh_conflict "22,443"')"
  assert_contains "SSH port conflict detected" "$out" "22"

  out="$(lib_eval 'frp_asset_name 0.71.0 amd64')"
  assert_eq "frp asset name" "$out" "frp_0.71.0_linux_amd64.tar.gz"

  out="$(lib_eval 'frp_tag_valid v0.71.0 && echo ok || echo bad')"
  assert_eq "frp tag validation" "$out" "ok"
  out="$(lib_eval 'frp_tag_valid latest && echo ok || echo bad')"
  assert_eq "frp tag validation rejects 'latest'" "$out" "bad"

  out="$(lib_eval 'frp_udp_packet_size' )"
  assert_eq "udp packet size fits the default MTU" "$out" "1444"
}

# ============================================================
# 4. Iran server install
# ============================================================
t_install_iran() {
  section "4. Iran server: full install"
  setup_env iran
  install_iran
  assert_rc "install exits 0" "$RC" "0"

  assert_eq "role stored"                 "$(state_get ROLE)" "iran"
  assert_eq "local public IP stored"      "$(state_get LOCAL_PUBLIC_IP)" "203.0.113.10"
  assert_eq "peer public IP stored"       "$(state_get PEER_PUBLIC_IP)" "198.51.100.9"
  assert_eq "tunnel IP local"             "$(state_get GRE_IP_LOCAL)" "10.99.99.1"
  assert_eq "tunnel IP remote"            "$(state_get GRE_IP_REMOTE)" "10.99.99.2"
  assert_eq "ports stored (csv, sorted)"  "$(state_get TUNNEL_PORTS)" "443,2053"
  assert_eq "tunnel port stored (the 40001 default)" "$(state_get CTRL_PORT)" "40001"
  assert_ne "auth token generated"        "$(state_get AUTH_TOKEN)" ""
  # the token is derived from the IP pair, so the peer computes the same one
  assert_eq "auth token derived from the IP pair" "$(state_get AUTH_TOKEN)" "$(derived_token)"

  # --- GRE device -----------------------------------------------------
  local log; log="$(ip_log)"
  assert_contains "GRE device created with both public IPs" "$log" \
    "link add name gft0 type gre local 203.0.113.10 remote 198.51.100.9"
  assert_contains "GRE address added" "$log" "addr add 10.99.99.1/30 dev gft0"
  assert_contains "GRE device brought up" "$log" "link set dev gft0 up"

  # --- MTU / TTL autotune --------------------------------------------
  assert_eq "best MTU from a 1500 byte path" "$(state_get TUNNEL_MTU)" "1476"
  assert_eq "best TTL chosen"                "$(state_get TUNNEL_TTL)" "64"
  assert_contains "MTU applied to the device" "$log" "link set dev gft0 mtu 1476"
  assert_file "optimize log written" "$ENV/logs/optimize.log"
  assert_contains "optimize log records the mtu" "$(cat "$ENV/logs/optimize.log")" "mtu=1476"
  assert_contains "optimize log records the ttl" "$(cat "$ENV/logs/optimize.log")" "ttl=64"

  # --- frp ------------------------------------------------------------
  assert_file "frps.toml generated" "$ENV/etc/frps.toml"
  assert_no_file "no frpc.toml on the relay" "$ENV/etc/frpc.toml"
  local frps; frps="$(cat "$ENV/etc/frps.toml")"
  assert_contains "frps binds to the tunnel IP only" "$frps" 'bindAddr = "10.99.99.1"'
  assert_contains "frps control port" "$frps" "bindPort = 40001"
  assert_contains "frps listens for proxies publicly" "$frps" 'proxyBindAddr = "0.0.0.0"'
  assert_contains "frps has the shared token" "$frps" "auth.token = \"$(state_get AUTH_TOKEN)\""
  assert_contains "udpPacketSize fits the MTU" "$frps" "udpPacketSize = 1444"
  assert_file "frps binary installed" "$ENV/bin/frps"
  assert_file "frpc binary installed" "$ENV/bin/frpc"
  assert_eq "frp version detected" "$("$ENV/bin/frps" --version 2>/dev/null | awk '{print $3}')" "0.99.0"
  assert_eq "frp version recorded" "$(state_get FRP_VERSION)" "0.99.0"

  # --- systemd --------------------------------------------------------
  local unit
  for unit in gft-tunnel.service gft-tunnel-optimize.service \
              gft-tunnel-optimize.timer gft-tunnel-frpupdate.timer frps.service; do
    assert_file "unit installed: $unit" "$ENV/units/$unit"
  done
  assert_contains "unit points at the CLI" "$(cat "$ENV/units/gft-tunnel.service")" "service-up"
  assert_not_contains "unit placeholders replaced" "$(cat "$ENV/units/gft-tunnel.service")" "__CLI__"
  assert_contains "frps unit enabled" "$(cat "$ENV/stubtmp/systemctl.enabled")" "frps.service"
  assert_contains "optimize timer enabled" "$(cat "$ENV/stubtmp/systemctl.enabled")" "gft-tunnel-optimize.timer"
  assert_contains "frp update timer enabled" "$(cat "$ENV/stubtmp/systemctl.enabled")" "gft-tunnel-frpupdate.timer"
  assert_contains "frps started" "$(cat "$ENV/stubtmp/systemctl.active")" "frps.service"

  # --- sysctl ---------------------------------------------------------
  assert_file "sysctl drop-in written" "$ENV/sysctl/99-gft-tunnel.conf"
  assert_contains "ip_forward enabled" "$(cat "$ENV/sysctl/99-gft-tunnel.conf")" "net.ipv4.ip_forward = 1"
  assert_contains "gre module loaded at boot" "$(cat "$ENV/modules/gft-tunnel.conf" 2>/dev/null)" "gre"

  # --- firewall -------------------------------------------------------
  local rules; rules="$(iptables_rules)"
  assert_contains "GRE (proto 47) allowed from the peer" "$rules" "-p gre -s 198.51.100.9 -j ACCEPT"
  assert_contains "traffic on the tunnel interface allowed" "$rules" "-i gft0 -j ACCEPT"
  assert_contains "tcp 443 opened" "$rules" "-p tcp --dport 443 -j ACCEPT"
  assert_contains "udp 443 opened" "$rules" "-p udp --dport 443 -j ACCEPT"
  assert_contains "tcp 2053 opened" "$rules" "-p tcp --dport 2053 -j ACCEPT"
  assert_contains "udp 2053 opened" "$rules" "-p udp --dport 2053 -j ACCEPT"
  assert_contains "control port restricted to the tunnel" "$rules" "-i gft0 -p tcp --dport 40001 -j ACCEPT"
  assert_contains "every rule is tagged" "$rules" "gft-tunnel"
  assert_not_contains "no DROP rule installed" "$rules" "-j DROP"
  assert_not_contains "no REJECT rule installed" "$rules" "-j REJECT"
  assert_contains "rules recorded for teardown" "$(cat "$ENV/state/firewall.rules")" "filter|INPUT|-p gre"

  # --- MSS clamp (keeps relayed TCP inside the tunnel MTU) ------------
  assert_contains "MSS is clamped for the tunnelled TCP ports" "$(iptables_mangle)" "--set-mss 1436"
  assert_contains "the clamp targets exactly the tunnelled ports" "$(iptables_mangle)" "--dports 443,2053"
  assert_contains "the clamp is recorded as a mangle rule" "$(cat "$ENV/state/firewall.rules")" "mangle|PREROUTING|"
  assert_eq "clamped MSS value recorded (1476 - 40)" "$(state_get MSS_CLAMPED)" "1436"
  assert_not_contains "the clamp never drops anything" "$(iptables_mangle)" "-j DROP"

  # --- config summary ------------------------------------------------
  assert_contains "status shows the relay role" "$(cat "$ENV/out.txt")" "role"
  assert_contains "instructions mention the peer" "$(cat "$ENV/out.txt")" "198.51.100.9"
}

# ============================================================
# 5. Foreign server install
# ============================================================
t_install_foreign() {
  section "5. Foreign server: full install"
  setup_env foreign
  install_foreign
  assert_rc "install exits 0" "$RC" "0"

  assert_eq "role stored"       "$(state_get ROLE)" "foreign"
  assert_eq "tunnel IP local"   "$(state_get GRE_IP_LOCAL)" "10.99.99.2"
  assert_eq "tunnel IP remote"  "$(state_get GRE_IP_REMOTE)" "10.99.99.1"

  assert_no_file "no frps.toml on the client" "$ENV/etc/frps.toml"
  assert_file "frpc.toml generated" "$ENV/etc/frpc.toml"
  local frpc; frpc="$(cat "$ENV/etc/frpc.toml")"
  assert_contains "frpc dials the Iranian tunnel IP" "$frpc" 'serverAddr = "10.99.99.1"'
  assert_contains "frpc control port" "$frpc" "serverPort = 40001"
  assert_contains "frpc uses the same token" "$frpc" "auth.token = \"$(state_get AUTH_TOKEN)\""
  # both servers derive it independently — this is the cross-host check
  assert_eq "the foreign side derived the relay's token on its own" \
    "$(state_get AUTH_TOKEN)" "$(derived_token 198.51.100.9 203.0.113.10)"
  assert_contains "udpPacketSize set" "$frpc" "udpPacketSize ="

  local proxy_count
  proxy_count="$(grep -c '^\[\[proxies\]\]' "$ENV/etc/frpc.toml")"
  assert_eq "one TCP + one UDP proxy per port" "$proxy_count" "4"
  assert_contains "tcp proxy for 443" "$frpc" 'name = "tcp-443"'
  assert_contains "udp proxy for 443" "$frpc" 'name = "udp-443"'
  assert_contains "tcp proxy for 2053" "$frpc" 'name = "tcp-2053"'
  assert_contains "udp proxy for 2053" "$frpc" 'name = "udp-2053"'
  assert_contains "proxies point at the local panel" "$frpc" 'localIP = "127.0.0.1"'
  assert_contains "remote port matches the local port" "$frpc" "remotePort = 443"
  assert_contains "proxies are created on the Iranian side of the tunnel" "$frpc" "type = \"udp\""
  assert_contains "exported peer config for the relay" "$(cat "$ENV/out.txt")" "foreign"
  assert_contains "frpc enabled" "$(cat "$ENV/stubtmp/systemctl.enabled")" "frpc.service"

  local fe; fe="$(cat "$ENV/stubtmp/systemctl.enabled")"
  case "$fe" in
    *frps.service*) bad_msg "frps must not be enabled on the foreign server" ;;
    *) ok_msg "frps must not be enabled on the foreign server" ;;
  esac

  # firewall: only the tunnel, nothing public
  local rules; rules="$(iptables_rules)"
  assert_contains "GRE allowed from the peer" "$rules" "-p gre -s 203.0.113.10 -j ACCEPT"
  assert_contains "tunnel interface allowed" "$rules" "-i gft0 -j ACCEPT"
  assert_not_contains "no public 443 rule on the foreign side" "$rules" "--dport 443 -j ACCEPT"
  assert_eq "no MSS clamp on the foreign side" "$(iptables_mangle)" ""
}

# ============================================================
# 6. Idempotency
# ============================================================
t_idempotent() {
  section "6. Idempotency (running the installer twice)"
  setup_env idempotent
  install_iran
  assert_rc "first install exits 0" "$RC" "0"

  local before_token before_cfg
  before_token="$(state_get AUTH_TOKEN)"
  before_cfg="$(mask_state)"

  install_iran
  assert_rc "second install exits 0" "$RC" "0"

  assert_eq "auth token kept" "$(state_get AUTH_TOKEN)" "$before_token"
  assert_eq "state unchanged (timestamps aside)" "$(mask_state)" "$before_cfg"
  local dupes
  dupes="$(cut -d= -f1 "$ENV/state/config.env" | sort | uniq -d | tr '\n' ' ')"
  assert_eq "no duplicated keys in the state file" "$dupes" ""
  assert_gt "state file is not empty" "$(wc -l <"$ENV/state/config.env")" "10"

  local gft_gre_rules
  gft_gre_rules="$(grep -c -- '-p gre -s 198.51.100.9' "$ENV/stubtmp/iptables.filter.state")"
  assert_eq "GRE rule not duplicated" "$gft_gre_rules" "1"
  local port_rules
  port_rules="$(grep -c -- '--dport 443 -j ACCEPT' "$ENV/stubtmp/iptables.filter.state")"
  assert_eq "port rule not duplicated" "$port_rules" "2"

  local backups
  backups="$(ls "$ENV/bin" 2>/dev/null | grep -c '\.bak-' || true)"
  assert_gt "existing frp binaries were backed up" "$backups" "0"

  # the device is not recreated when it already exists
  local adds
  adds="$(grep -c 'link add name gft0' "$ENV/stubtmp/ip.log")"
  assert_eq "GRE device created only once" "$adds" "1"
}

# ============================================================
# 7. MTU / TTL behaviour
# ============================================================
t_mtu_ttl() {
  section "7. MTU / TTL autotuning behaviour"
  local out

  # 7a. a smaller path MTU leads to a smaller tunnel MTU, and the MSS
  #     clamp follows it without stacking a second rule
  setup_env mtu_small
  seed_state iran 1476 64
  run_cli firewall apply
  assert_contains "clamp starts at the seeded MTU" "$(iptables_mangle)" "--set-mss 1436"
  STUB_PATH_MTU="1420"
  export STUB_PATH_MTU
  run_cli optimize
  assert_rc "optimize exits 0 on a 1420 byte path" "$RC" "0"
  assert_eq "MTU follows the path MTU (1420 - 24)" "$(state_get TUNNEL_MTU)" "1396"
  assert_contains "optimize reports the MTU" "$(cat "$ENV/out.txt")" "best MTU: 1396"
  assert_contains "the MSS clamp followed the new MTU" "$(iptables_mangle)" "--set-mss 1356"
  assert_eq "only one clamp rule exists" "$(grep -c -- '--set-mss' "$ENV/stubtmp/iptables.mangle.state")" "1"
  assert_eq "the recorded MSS was updated" "$(state_get MSS_CLAMPED)" "1356"
  assert_not_contains "the stale clamp is gone" "$(iptables_mangle)" "1436"
  unset STUB_PATH_MTU

  # 7b. an MTU that loses packets is stepped down
  setup_env mtu_lossy
  seed_state iran 1476 64
  STUB_LOSS_AT_MTU="1476:50"
  export STUB_LOSS_AT_MTU
  out="$(lib_run 'gft_gre_ensure_up >/dev/null 2>&1; net_optimize_mtu >/dev/null 2>&1; echo "MTU=$(cfg_get TUNNEL_MTU)"')"
  assert_contains "MTU stepped down away from the lossy value" "$out" "MTU=1468"
  unset STUB_LOSS_AT_MTU

  # 7c. the TTL with packet loss is avoided
  setup_env ttl_lossy
  seed_state iran 1476 64
  STUB_LOSS_AT_TTL="64:50;128:0"
  export STUB_LOSS_AT_TTL
  out="$(lib_run 'gft_gre_ensure_up >/dev/null 2>&1; net_optimize_ttl >/dev/null 2>&1; echo "TTL=$(cfg_get TUNNEL_TTL)"')"
  assert_contains "picked the loss-free TTL" "$out" "TTL=128"
  assert_contains "the TTL was applied to the GRE device" "$(cat "$ENV/stubtmp/ip.state")" "devttl gft0 128"
  unset STUB_LOSS_AT_TTL

  # 7d. a filtered ICMP path still yields a usable MTU
  setup_env mtu_unreachable
  seed_state iran 1476 64
  STUB_PATH_MTU="1"
  export STUB_PATH_MTU
  run_cli optimize
  assert_rc "optimize still succeeds when ICMP is filtered" "$RC" "0"
  assert_eq "falls back to the interface MTU minus overhead" "$(state_get TUNNEL_MTU)" "1476"
  assert_contains "and says so" "$(cat "$ENV/out.txt")" "no answer"
  unset STUB_PATH_MTU

  # 7e. the hop count is used as a floor for the TTL
  setup_env ttl_hops
  seed_state iran 1476 64
  STUB_HOPS="12"
  export STUB_HOPS
  run_cli optimize
  local ttl_used
  ttl_used="$(state_get TUNNEL_TTL)"
  assert_gt "TTL is above the hop count" "$ttl_used" "13"
  assert_eq "hop count recorded" "$(state_get TUNNEL_TTL_HOPS)" "12"
  unset STUB_HOPS
}

# ============================================================
# 8. port management
# ============================================================
t_ports() {
  section "8. Port management"
  setup_env ports
  seed_state iran 1476 64

  run_cli ports add 8443
  assert_rc "ports add exits 0" "$RC" "0"
  assert_eq "port added" "$(state_get TUNNEL_PORTS)" "443,2053,8443"

  run_cli ports remove 443
  assert_rc "ports remove exits 0" "$RC" "0"
  assert_eq "port removed" "$(state_get TUNNEL_PORTS)" "2053,8443"

  run_cli ports list
  assert_contains "ports list shows TCP and UDP" "$(cat "$ENV/out.txt")" "2053/tcp + 2053/udp"

  run_cli ports add 99999
  assert_ne "invalid port rejected" "$RC" "0"
  run_cli ports set "443,2053"
  assert_eq "ports set replaces the list" "$(state_get TUNNEL_PORTS)" "443,2053"

  run_cli ports add 22
  assert_ne "SSH port refused" "$RC" "0"
}

# ============================================================
# 9. safety rails
# ============================================================
t_safety() {
  section "9. Safety rails"
  setup_env safety

  run_cli install --role=iran --local-ip=203.0.113.10 --peer=198.51.100.9 --ports=22,443
  assert_ne "installing over the SSH port is refused" "$RC" "0"
  assert_no_file "nothing was written when refusing" "$ENV/state/config.env"

  # the override is checked with a dry run: the guard must let it through
  GFT_ALLOW_SSH_PORT=1
  GFT_DRY_RUN=1
  export GFT_ALLOW_SSH_PORT GFT_DRY_RUN
  run_cli install --role=iran --local-ip=203.0.113.10 --peer=198.51.100.9 --ports=22
  assert_rc "explicit override allows the SSH port" "$RC" "0"
  assert_contains "and warns about the risk" "$(cat "$ENV/out.txt")" "SSH may be shadowed"
  unset GFT_ALLOW_SSH_PORT GFT_DRY_RUN

  setup_env safety2
  run_cli install --role=iran --local-ip=203.0.113.10 --peer=203.0.113.10 --ports=443
  assert_ne "peer IP equal to ours is refused" "$RC" "0"

  run_cli install --role=iran --local-ip=203.0.113.10 --peer=198.51.100.9 --ports="abc"
  assert_ne "garbage port list refused" "$RC" "0"

  setup_env noninteractive
  run_cli install
  assert_ne "non-interactive without a role fails clearly" "$RC" "0"
  assert_contains "and explains what is missing" "$(cat "$ENV/out.txt")" "ROLE"

  setup_env help_env
  run_cli help
  assert_rc "help exits 0" "$RC" "0"
  assert_contains "help lists install" "$(cat "$ENV/out.txt")" "install"
  run_cli version
  assert_rc "version exits 0" "$RC" "0"
  assert_contains "version prints the project version" "$(cat "$ENV/out.txt")" "gft-TUNNEL"
  run_cli totally-unknown-command
  assert_rc "unknown command exits 2" "$RC" "2"
}

# ============================================================
# 10. frp version handling
# ============================================================
t_frp() {
  section "10. frp installation and updates"
  setup_env frp
  seed_state iran 1476 64
  local out

  out="$(lib_run 'frp_install_latest')"
  assert_contains "latest release installed" "$out" "frp 0.99.0 installed"
  assert_file "frps binary installed" "$ENV/bin/frps"
  assert_file "frpc binary installed" "$ENV/bin/frpc"
  assert_eq "installed version reported" "$(lib_run 'frp_installed_version')" "0.99.0"

  run_cli frp version
  assert_contains "cli reports the installed version" "$(cat "$ENV/out.txt")" "0.99.0"
  assert_contains "cli reports the latest version" "$(cat "$ENV/out.txt")" "0.99.0"

  local downloads_before downloads_after
  downloads_before="$(grep -c 'linux_amd64.tar.gz' "$ENV/stubtmp/curl.log" || true)"
  run_cli update-frp
  downloads_after="$(grep -c 'linux_amd64.tar.gz' "$ENV/stubtmp/curl.log" || true)"
  assert_eq "an up-to-date frp is not downloaded again" "$downloads_after" "$downloads_before"

  # a newer release is picked up
  STUB_FRP_VERSION="0.99.1"
  export STUB_FRP_VERSION
  run_cli update-frp
  assert_rc "update to a newer release exits 0" "$RC" "0"
  assert_contains "new version recorded" "$(cat "$ENV/out.txt")" "0.99.1"
  assert_eq "binary replaced" "$("$ENV/bin/frps" --version 2>/dev/null | awk '{print $3}')" "0.99.1"
  assert_contains "old binary kept as a backup" "$(ls "$ENV/bin")" ".bak-"
  unset STUB_FRP_VERSION

  # checksum mismatch must abort the installation
  setup_env frp_bad_sum
  seed_state iran 1476 64
  STUB_BAD_CHECKSUM=1
  export STUB_BAD_CHECKSUM
  out="$(lib_run 'frp_install_latest')"
  assert_contains "checksum mismatch detected" "$out" "checksum mismatch"
  assert_no_file "no binary installed on a bad checksum" "$ENV/bin/frps"
  unset STUB_BAD_CHECKSUM

  # a download that is not a tarball must not be installed either
  setup_env frp_junk
  seed_state iran 1476 64
  STUB_JUNK_ARCHIVE=1
  export STUB_JUNK_ARCHIVE
  out="$(lib_run 'frp_install_latest')"
  assert_contains "a corrupt archive is rejected" "$out" "not a valid tar.gz"
  unset STUB_JUNK_ARCHIVE

  # the GitHub API being down must not break the lookup (redirect fallback)
  setup_env frp_api_down
  STUB_API_DOWN=1
  export STUB_API_DOWN
  local tag
  tag="$( cd "$ROOT" && bash -c '. lib/common.sh; . lib/frp.sh; frp_latest_tag' 2>/dev/null )"
  assert_eq "falls back to the release redirect when the API is down" "$tag" "v0.99.0"
  unset STUB_API_DOWN
}

# ============================================================
# 11. firewall backends
# ============================================================
t_firewall() {
  section "11. Firewall backends"
  setup_env fw_firewalld
  seed_state iran 1476 64
  STUB_FIREWALLD=1
  export STUB_FIREWALLD
  run_cli firewall apply
  assert_rc "firewall apply with firewalld exits 0" "$RC" "0"
  assert_contains "uses firewalld direct rules" "$(cat "$ENV/stubtmp/firewalld.rules" 2>/dev/null)" "--direct"
  assert_contains "detects the firewalld backend" "$(cat "$ENV/out.txt")" "firewalld"
  run_cli firewall remove
  assert_rc "firewalld rules removed" "$RC" "0"
  assert_contains "removal is recorded" "$(cat "$ENV/out.txt")" "removed"
  unset STUB_FIREWALLD

  setup_env fw_ufw
  seed_state iran 1476 64
  STUB_UFW=1
  export STUB_UFW
  run_cli firewall apply
  assert_rc "firewall apply with ufw active exits 0" "$RC" "0"
  assert_contains "still inserts iptables ACCEPT rules" "$(iptables_rules)" "-j ACCEPT"
  assert_not_contains "and never disables ufw" "$(cat "$ENV/out.txt")" "ufw disable"
  unset STUB_UFW

  setup_env fw_show
  seed_state iran 1476 64
  run_cli firewall apply
  local rules_file rules_file2
  rules_file="$(cat "$ENV/state/firewall.rules")"
  assert_contains "rules are recorded for teardown" "$rules_file" "INPUT|"
  assert_contains "the mangle clamp is recorded too" "$rules_file" "mangle|PREROUTING|"
  run_cli firewall show
  assert_rc "firewall show exits 0" "$RC" "0"
  assert_contains "shows the GRE rule as present" "$(cat "$ENV/out.txt")" "-p gre"

  # applying twice must not duplicate anything
  run_cli firewall apply
  rules_file2="$(cat "$ENV/state/firewall.rules")"
  assert_eq "a second apply is a no-op" "$rules_file2" "$rules_file"
  assert_eq "no duplicates in iptables" "$(grep -c -- '-p gre -s' "$ENV/stubtmp/iptables.filter.state")" "1"

  run_cli firewall remove
  assert_rc "firewall remove exits 0" "$RC" "0"
  assert_eq "all rules removed" "$(iptables_rules)" ""
  assert_eq "the MSS clamp removed too" "$(iptables_mangle)" ""
  assert_no_file "the rule record is gone too" "$ENV/state/firewall.rules"
}

# ============================================================
# 12. connectivity test command
# ============================================================
t_test_command() {
  section "12. The test command"
  setup_env testcmd
  seed_state iran 1476 64
  run_cli restart   # creates the device and the frps config
  assert_rc "restart exits 0" "$RC" "0"

  run_cli test
  assert_rc "test exits 0 on a healthy tunnel" "$RC" "0"
  assert_contains "checks the GRE device" "$(cat "$ENV/out.txt")" "GRE device"
  assert_contains "checks the peer over the tunnel" "$(cat "$ENV/out.txt")" "answers over the tunnel"
  assert_contains "checks the control port" "$(cat "$ENV/out.txt")" "frps is listening"
  assert_contains "checks for fragmentation" "$(cat "$ENV/out.txt")" "no fragmentation"

  setup_env testcmd_foreign
  seed_state foreign 1476 64
  run_cli restart
  run_cli test
  assert_rc "foreign side test exits 0" "$RC" "0"
  assert_contains "checks the control port path" "$(cat "$ENV/out.txt")" "control port"
  assert_contains "checks the local panel" "$(cat "$ENV/out.txt")" "127.0.0.1"
}

# ============================================================
# 13. dry run
# ============================================================
t_dry_run() {
  section "13. Dry run changes nothing"
  setup_env dry
  GFT_DRY_RUN=1
  export GFT_DRY_RUN
  run_cli install --role=iran --local-ip=203.0.113.10 --peer=198.51.100.9 --ports=443
  assert_rc "dry-run install exits 0" "$RC" "0"
  assert_no_file "no state written" "$ENV/state/config.env"
  assert_no_file "no unit written" "$ENV/units/gft-tunnel.service"
  assert_no_file "no frps config written" "$ENV/etc/frps.toml"
  assert_eq "no firewall change" "$(iptables_rules)" ""
  assert_eq "no device created" "$(cat "$ENV/stubtmp/ip.state" 2>/dev/null)" ""
  assert_contains "the plan is printed" "$(cat "$ENV/out.txt")" "link add name gft0"
  unset GFT_DRY_RUN
}

# ============================================================
# 14. services, export, status, logs
# ============================================================
t_services() {
  section "14. Service helpers"
  setup_env services
  seed_state iran 1476 64
  lib_run 'frp_install_latest' >/dev/null 2>&1
  run_cli restart
  assert_rc "restart exits 0" "$RC" "0"
  assert_file "restart wrote the frps config" "$ENV/etc/frps.toml"

  run_cli service-down
  assert_rc "service-down exits 0" "$RC" "0"
  assert_not_contains "device removed" "$(cat "$ENV/stubtmp/ip.state")" "dev gft0"

  run_cli service-up
  assert_rc "service-up exits 0" "$RC" "0"
  assert_contains "device recreated" "$(cat "$ENV/stubtmp/ip.state")" "dev gft0"
  assert_contains "mtu reapplied" "$(cat "$ENV/stubtmp/ip.state")" "devmtu gft0"

  run_cli status
  assert_rc "status exits 0" "$RC" "0"
  assert_contains "status shows the ports" "$(cat "$ENV/out.txt")" "443,2053"
  assert_contains "status shows the frp version" "$(cat "$ENV/out.txt")" "0.99.0"

  run_cli config
  assert_contains "config prints the state file" "$(cat "$ENV/out.txt")" "ROLE=iran"
  assert_contains "config prints frps.toml" "$(cat "$ENV/out.txt")" "bindPort"

  run_cli logs
  assert_rc "logs exits 0" "$RC" "0"

  run_cli export-peer
  assert_rc "export-peer exits 0" "$RC" "0"
  assert_file "peer config written" "$ENV/state/frpc.toml.peer"
  assert_contains "peer config dials the relay" \
    "$(cat "$ENV/state/frpc.toml.peer")" 'serverAddr = "10.99.99.1"'
}

# ============================================================
# 15. uninstall
# ============================================================
t_uninstall() {
  section "15. Uninstall"
  setup_env uninstall
  install_iran
  assert_rc "install" "$RC" "0"
  run_cli uninstall --yes
  assert_rc "uninstall exits 0" "$RC" "0"
  assert_eq "firewall rules removed" "$(iptables_rules)" ""
  assert_no_file "state directory removed" "$ENV/state/config.env"
  assert_no_file "units removed" "$ENV/units/gft-tunnel.service"
  assert_no_file "sysctl drop-in removed" "$ENV/sysctl/99-gft-tunnel.conf"
  assert_not_contains "device removed" "$(cat "$ENV/stubtmp/ip.state" 2>/dev/null)" "dev gft0"
  assert_contains "timers disabled" "$(cat "$ENV/out.txt")" "removed"
}

# ============================================================
# 16. `set` — changing settings after the install
# ============================================================
t_set() {
  section "16. Changing settings with set"
  setup_env setcmd
  seed_state foreign 1476 64

  # --- the tunnel port -------------------------------------------------
  run_cli set tunnel-port 40001
  assert_rc "setting the same tunnel port is a no-op" "$RC" "0"
  run_cli set tunnel-port 41000
  assert_rc "tunnel port change exits 0" "$RC" "0"
  assert_eq "tunnel port stored" "$(state_get CTRL_PORT)" "41000"
  run_cli restart
  assert_contains "frpc dials the new port" "$(cat "$ENV/etc/frpc.toml")" "serverPort = 41000"
  run_cli set tunnel-port 70000
  assert_ne "an invalid port is refused" "$RC" "0"

  # --- tunnelled ports -------------------------------------------------
  run_cli set ports "443,8443,2053"
  assert_rc "port list change exits 0" "$RC" "0"
  assert_eq "ports stored sorted and unique" "$(state_get TUNNEL_PORTS)" "443,2053,8443"
  run_cli restart
  local proxies
  proxies="$(grep -c '^\[\[proxies\]\]' "$ENV/etc/frpc.toml")"
  assert_eq "proxies regenerated for the new list" "$proxies" "6"
  run_cli set ports "443"
  local only
  only="$(grep -c '^\[\[proxies\]\]' "$ENV/etc/frpc.toml")"
  assert_eq "the old proxies are gone (no duplicates)" "$only" "2"
  run_cli set ports 22
  assert_ne "tunnelling SSH is still refused" "$RC" "0"

  # --- the peer IP (how you repoint a foreign server at a new Iran IP) --
  run_cli set peer-ip 198.51.100.77
  assert_rc "peer IP change exits 0" "$RC" "0"
  assert_eq "peer IP stored" "$(state_get PEER_PUBLIC_IP)" "198.51.100.77"
  assert_contains "the GRE link was rebuilt for the new peer" "$(ip_log)" "remote 198.51.100.77"
  assert_contains "the firewall now allows the new peer" "$(iptables_rules)" "-p gre -s 198.51.100.77 -j ACCEPT"
  run_cli set peer-ip 203.0.113.10   # put it back (the original peer) for the checks below
  assert_eq "peer IP can be changed back" "$(state_get PEER_PUBLIC_IP)" "203.0.113.10"
  run_cli set peer-ip not-an-ip
  assert_ne "a bogus peer IP is refused" "$RC" "0"
  run_cli set local-ip "$(state_get PEER_PUBLIC_IP)"
  assert_ne "a peer IP equal to ours is refused" "$RC" "0"

  # --- tunnel IPs ------------------------------------------------------
  run_cli set gre-remote 10.99.99.9
  assert_eq "tunnel peer IP stored" "$(state_get GRE_IP_REMOTE)" "10.99.99.9"
  assert_contains "address added on the rebuilt device" "$(ip_log)" "addr add 10.99.99.2/30 dev gft0"
  run_cli set gre-remote "$(state_get GRE_IP_LOCAL)"
  assert_ne "the two tunnel IPs may not be identical" "$RC" "0"

  # --- MTU / TTL -------------------------------------------------------
  run_cli set mtu 1400
  assert_eq "MTU stored" "$(state_get TUNNEL_MTU)" "1400"
  assert_contains "MTU applied to the device" "$(ip_log)" "link set dev gft0 mtu 1400"
  run_cli set mtu 400
  assert_ne "a too small MTU is refused" "$RC" "0"
  run_cli set ttl 128
  assert_eq "TTL stored" "$(state_get TUNNEL_TTL)" "128"
  assert_contains "TTL applied to the device" "$(cat "$ENV/stubtmp/ip.state")" "devttl gft0 128"
  run_cli set ttl 999
  assert_ne "an out of range TTL is refused" "$RC" "0"

  # --- the local panel address (foreign side) --------------------------
  run_cli set target 10.77.0.5
  assert_eq "panel address stored" "$(state_get LOCAL_TARGET_IP)" "10.77.0.5"
  run_cli restart
  assert_contains "frpc points at the new panel address" "$(cat "$ENV/etc/frpc.toml")" 'localIP = "10.77.0.5"'

  # --- unknown key -----------------------------------------------------
  run_cli set nonsense 1
  assert_rc "an unknown setting exits 2" "$RC" "2"
  assert_contains "and lists the known ones" "$(cat "$ENV/out.txt")" "known settings"

  # --- nothing configured yet ------------------------------------------
  setup_env setcmd_empty
  run_cli set tunnel-port 40001
  assert_ne "set refuses to run before install" "$RC" "0"

  # --- the MSS clamp is an Iran-side concern ---------------------------
  # It must follow a manual MTU change, and never leave a stale rule behind.
  setup_env setcmd_iran
  seed_state iran 1476 64
  run_cli firewall apply
  assert_contains "clamp starts at the seeded MTU" "$(iptables_mangle)" "--set-mss 1436"
  run_cli set mtu 1400
  assert_contains "the MSS clamp followed the manual MTU" "$(iptables_mangle)" "--set-mss 1360"
  assert_eq "only one clamp rule exists" "$(grep -c -- '--set-mss' "$ENV/stubtmp/iptables.mangle.state")" "1"
  assert_eq "the recorded MSS was updated" "$(state_get MSS_CLAMPED)" "1360"
}

# ============================================================
# 17. The full-screen menu
# ============================================================
t_tui() {
  section "17. Full-screen menu (scripted)"
  setup_env tui
  seed_state iran 1476 64
  lib_run 'frp_install_latest' >/dev/null 2>&1
  run_cli restart
  GFT_NO_TTY=1
  export GFT_NO_TTY

  # the menu alone must open and quit cleanly
  { printf '16\n' | bash "$CLI" menu; } >"$ENV/out.txt" 2>&1
  RC=$?
  assert_rc "menu opens and quits" "$RC" "0"
  assert_contains "the header summarises the tunnel" "$(cat "$ENV/out.txt")" "tunnel port"
  assert_contains "all entries are listed" "$(cat "$ENV/out.txt")" "Uninstall"
  assert_contains "the summary shows the role" "$(cat "$ENV/out.txt")" "iran"

  # EOF must quit instead of looping forever
  { bash "$CLI" menu </dev/null; } >"$ENV/out.txt" 2>&1
  assert_rc "menu quits on end of input" "$?" "0"

  # a couple of items, then quit
  { printf '7\n16\n' | bash "$CLI" menu; } >"$ENV/out.txt" 2>&1
  assert_rc "menu item 7 (status) exits 0" "$?" "0"
  assert_contains "item 7 printed the status" "$(cat "$ENV/out.txt")" "this server"
  assert_contains "item 7 shows the tunnel port" "$(cat "$ENV/out.txt")" "tunnel port"

  { printf '6\n16\n' | bash "$CLI" menu; } >"$ENV/out.txt" 2>&1
  assert_contains "item 6 ran the connectivity test" "$(cat "$ENV/out.txt")" "Connectivity test"
  assert_contains "and reported the peer" "$(cat "$ENV/out.txt")" "answers over the tunnel"

  { printf '5\n16\n' | bash "$CLI" menu; } >"$ENV/out.txt" 2>&1
  assert_contains "item 5 ran the optimizer" "$(cat "$ENV/out.txt")" "best MTU"

  { printf '12\n16\n' | bash "$CLI" menu; } >"$ENV/out.txt" 2>&1
  assert_contains "item 12 printed the configuration" "$(cat "$ENV/out.txt")" "ROLE=iran"

  { printf '14\n16\n' | bash "$CLI" menu; } >"$ENV/out.txt" 2>&1
  assert_contains "item 14 exported the peer config" "$(cat "$ENV/out.txt")" "frpc.toml.peer"

  # submenu: ports → list → back
  { printf '4\n1\n5\n16\n' | bash "$CLI" menu; } >"$ENV/out.txt" 2>&1
  assert_rc "the ports submenu exits 0" "$?" "0"
  assert_contains "the ports submenu lists ports" "$(cat "$ENV/out.txt")" "tunnelled ports"
  assert_contains "and each port as TCP + UDP" "$(cat "$ENV/out.txt")" "443/tcp + 443/udp"

  # submenu: firewall → show → back
  { printf '13\n1\n4\n16\n' | bash "$CLI" menu; } >"$ENV/out.txt" 2>&1
  assert_contains "the firewall submenu shows the rules" "$(cat "$ENV/out.txt")" "-p gre"

  # editing through the menu: item 2 → peer IP → new value
  { printf '2\n1\n198.51.100.77\n16\n' | bash "$CLI" menu; } >"$ENV/out.txt" 2>&1
  assert_rc "editing through the menu exits 0" "$?" "0"
  assert_eq "the menu edit changed the peer IP" "$(state_get PEER_PUBLIC_IP)" "198.51.100.77"
  assert_contains "and reported the change" "$(cat "$ENV/out.txt")" "public IP (the peer)"

  # item 3 is the dedicated tunnel-port editor
  { printf '3\n41000\n16\n' | bash "$CLI" menu; } >"$ENV/out.txt" 2>&1
  assert_eq "the tunnel port editor works" "$(state_get CTRL_PORT)" "41000"

  unset GFT_NO_TTY
}

# ============================================================
# 18. Self update
# ============================================================
t_update() {
  section "18. Self update from GitHub"
  setup_env selfupdate

  if ! command -v git >/dev/null 2>&1; then
    printf '  %s-%s git not available — skipping%s\n' "$C_Y" "$C_0" ""
    return 0
  fi

  local origin="$ENV/origin.git" repo="$ENV/repo" dev="$ENV/dev"
  case "$repo" in
    "$WORK"/*) ;;
    *) bad_msg "self-update safety check" "refusing to run outside the work dir"; return 1 ;;
  esac

  git init -q --bare "$origin" 2>/dev/null || { bad_msg "could not create a bare origin"; return 1; }
  # the bare repo's default branch must be main, otherwise later clones check
  # out an unborn master and the whole update flow cannot push/pull
  git -C "$origin" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  git clone -q --no-hardlinks "$ROOT" "$ENV/seed" 2>/dev/null
  # a CI checkout can be shallow or detached — normalise to a local main
  git -C "$ENV/seed" checkout -q -B main 2>/dev/null || true
  git -C "$ENV/seed" -c user.name=t -c user.email=t@t push -q "$origin" main 2>/dev/null \
    || { bad_msg "could not seed the bare origin"; return 1; }
  git clone -q "$origin" "$repo" 2>/dev/null || { bad_msg "could not clone the origin"; return 1; }
  git clone -q "$origin" "$dev" 2>/dev/null

  # a newer commit upstream
  printf '9.9.9\n' >"$dev/VERSION"
  git -C "$dev" add VERSION
  git -C "$dev" -c user.name=t -c user.email=t@t commit -q -m "bump version"
  git -C "$dev" -c user.name=t -c user.email=t@t push -q origin main

  # Point the CLI at the throw-away checkout and update it. The libraries are
  # taken from the working tree so the test also works while the project has
  # uncommitted edits (the bare origin only ever carries committed history).
  export GFT_SELF_DIR="$repo"
  export GFT_VERSION_FILE="$repo/VERSION"
  export GFT_LIB_DIR="$ROOT/lib"
  run_cli update
  assert_rc "self update exits 0" "$RC" "0"
  assert_contains "it reports the new revision" "$(cat "$ENV/out.txt")" "updated"
  assert_eq "the checkout really moved" "$(cat "$repo/VERSION")" "9.9.9"

  # a second run must be a no-op
  run_cli update
  assert_rc "a second update exits 0" "$RC" "0"
  assert_contains "and reports being up to date" "$(cat "$ENV/out.txt")" "already on the newest version"

  # local changes are protected
  printf 'dirty\n' >>"$repo/VERSION"
  run_cli update
  assert_ne "local changes block the update" "$RC" "0"
  assert_contains "and explain the way out" "$(cat "$ENV/out.txt")" "--force"
  run_cli update --force
  assert_rc "--force overwrites them" "$RC" "0"
  assert_eq "VERSION restored from upstream" "$(cat "$repo/VERSION")" "9.9.9"

  # not a git checkout
  mkdir -p "$ENV/plain" && cp "$CLI" "$ENV/plain/gft"
  export GFT_SELF_DIR="$ENV/plain"
  export GFT_LIB_DIR="$ROOT/lib"          # keep the libs reachable so the CLI runs
  export GFT_VERSION_FILE="$ROOT/VERSION"
  run_cli update
  assert_ne "a non-git copy cannot self update" "$RC" "0"
  assert_contains "and says how to update instead" "$(cat "$ENV/out.txt")" "not a git checkout"

  unset GFT_SELF_DIR GFT_LIB_DIR GFT_VERSION_FILE
}

# ============================================================
# 19. Performance / lightness guards
# ============================================================
t_perf() {
  section "19. Speed and lightness"
  setup_env perf
  seed_state iran 1476 64

  # BBR + fq + mtu probing are written to the drop-in when the kernel offers
  # them, and skipped cleanly when it does not
  STUB_TCP_CC=bbr
  export STUB_TCP_CC
  run_cli firewall apply >/dev/null 2>&1
  lib_run 'sysctl_setup' >/dev/null 2>&1
  local conf; conf="$(cat "$ENV/sysctl/99-gft-tunnel.conf" 2>/dev/null)"
  assert_contains "ip_forward is set" "$conf" "net.ipv4.ip_forward = 1"
  assert_contains "loose rp_filter for tunnels" "$conf" "net.ipv4.conf.all.rp_filter = 2"
  assert_contains "PMTU black hole detection" "$conf" "net.ipv4.tcp_mtu_probing = 1"
  assert_contains "BBR is enabled when available" "$conf" "net.ipv4.tcp_congestion_control = bbr"
  assert_contains "fq keeps bufferbloat down" "$conf" "net.core.default_qdisc = fq"
  unset STUB_TCP_CC

  # without BBR the drop-in stays minimal instead of failing
  setup_env perf_nobbr
  seed_state iran 1476 64
  GFT_TCP_CC=none
  export GFT_TCP_CC
  lib_run 'sysctl_setup' >/dev/null 2>&1
  conf="$(cat "$ENV/sysctl/99-gft-tunnel.conf" 2>/dev/null)"
  assert_not_contains "no BBR line without kernel support" "$conf" "bbr"
  assert_contains "forwarding still on" "$conf" "net.ipv4.ip_forward = 1"
  unset GFT_TCP_CC

  # the menu header must not run the heavy status probes
  setup_env perf_header
  seed_state iran 1476 64
  local pings_before pings_after
  pings_before="$(wc -l <"$ENV/stubtmp/ping.log" 2>/dev/null || echo 0)"
  lib_run 'gft_summary' >/dev/null 2>&1
  pings_after="$(wc -l <"$ENV/stubtmp/ping.log" 2>/dev/null || echo 0)"
  assert_eq "the menu header does not ping the peer" "$pings_after" "$pings_before"
}

# ============================================================
# Runner
# ============================================================
# All sections, in order. SECTIONS="idempotent mtu_ttl" runs a subset.
ALL_SECTIONS="static unit_templates helpers install_iran install_foreign idempotent \
mtu_ttl ports safety frp firewall test_command dry_run services uninstall \
set tui update perf"

main() {
  printf '%s\n' "${C_B}gft-TUNNEL — smoke test suite${C_0}"
  printf '%s\n' "${C_D}work dir: $WORK${C_0}"

  local s
  for s in ${SECTIONS:-$ALL_SECTIONS}; do
    "t_$s"
  done

  printf '\n%s\n' "────────────────────────────────────────────────────────"
  printf '  %spassed: %d%s   %sfailed: %d%s\n' "$C_G" "$PASS" "$C_0" \
    "$([ "$FAIL" -gt 0 ] && printf '%s' "$C_R" || printf '%s' "$C_G")" "$FAIL" "$C_0"
  if [ "$FAIL" -gt 0 ]; then
    printf '\n  failures:\n'
    local f
    for f in "${FAILURES[@]}"; do printf '    - %s\n' "$f"; done
    printf '\n  work dir kept for inspection: %s\n' "$WORK"
    return 1
  fi
  printf '\n  everything passed 🎉\n'
  [ "${KEEP_WORK:-0}" = "1" ] || rm -rf "$WORK" 2>/dev/null || true
  return 0
}

main "$@"
