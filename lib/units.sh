#!/usr/bin/env bash
# ============================================================
# GRE+FRP-TUNNEL — lib/units.sh
# Installs the systemd units that make everything survive a
# reboot:
#   gre-frp-tunnel.service          recreate the GRE device
#   gre-frp-tunnel-optimize.timer   hourly MTU/TTL autotune
#   gre-frp-tunnel-frpupdate.timer  daily "always latest frp"
#   frps.service | frpc.service     the tunnel itself
# ============================================================

[ -n "${GRE_FRP_UNITS_LOADED:-}" ] && return 0
GRE_FRP_UNITS_LOADED=1

GRE_FRP_UNIT_NAMES="gre-frp-tunnel.service gre-frp-tunnel-optimize.service gre-frp-tunnel-optimize.timer gre-frp-tunnel-frpupdate.service gre-frp-tunnel-frpupdate.timer frps.service frpc.service"

units_templates_dir() {
  if [ -n "${GRE_FRP_TEMPLATES_DIR:-}" ]; then
    printf '%s' "$GRE_FRP_TEMPLATES_DIR"; return
  fi
  printf '%s/systemd' "$GRE_FRP_SELF_DIR"
}

units_substitute() { # <src> -> stdout
  local src="$1"
  sed \
    -e "s#__CLI__#${GRE_FRP_CLI_PATH}#g" \
    -e "s#__BIN__#${GRE_FRP_BIN_DIR}#g" \
    -e "s#__FRP_ETC__#${GRE_FRP_FRP_ETC_DIR}#g" \
    -e "s#__LOG__#${GRE_FRP_LOG_DIR}#g" \
    -e "s#__STATE__#${GRE_FRP_STATE_DIR}#g" \
    "$src"
}

units_install() {
  local tdir name src
  tdir="$(units_templates_dir)"
  if [ ! -d "$tdir" ]; then
    err "unit templates not found in $tdir"
    return 1
  fi
  [ "$GRE_FRP_DRY_RUN" != "1" ] && mkdir -p "$GRE_FRP_SYSTEMD_DIR" 2>/dev/null || true
  for name in $GRE_FRP_UNIT_NAMES; do
    src="$tdir/$name"
    [ -f "$src" ] || { warn "missing unit template: $name"; continue; }
    units_substitute "$src" | put_file "$GRE_FRP_SYSTEMD_DIR/$name"
  done
  ok "systemd units installed in $GRE_FRP_SYSTEMD_DIR"
}

units_reload() {
  if is_systemd; then
    mutq systemctl daemon-reload || true
  else
    warn "systemd is not running — units were written but not loaded"
    return 1
  fi
  return 0
}

units_enable() {
  is_systemd || return 0
  mutq systemctl enable gre-frp-tunnel.service \
        gre-frp-tunnel-optimize.timer \
        gre-frp-tunnel-frpupdate.timer || true
  local role; role="$(cfg_get ROLE)"
  if [ "$role" = "iran" ]; then
    mutq systemctl enable frps.service || true
    mutq systemctl disable --now frpc.service 2>/dev/null || true
  else
    mutq systemctl enable frpc.service || true
    mutq systemctl disable --now frps.service 2>/dev/null || true
  fi
  ok "enabled on boot: gre-frp-tunnel + hourly optimizer + daily frp updater"
}

units_disable() {
  is_systemd || return 0
  mutq systemctl disable --now gre-frp-tunnel-optimize.timer \
        gre-frp-tunnel-frpupdate.timer 2>/dev/null || true
  mutq systemctl disable gre-frp-tunnel.service frps.service frpc.service 2>/dev/null || true
}

services_restart_role() {
  is_systemd || {
    warn "systemd not available — start frps/frpc manually"
    return 0
  }
  mutq systemctl restart gre-frp-tunnel.service || true
  local role; role="$(cfg_get ROLE)"
  if [ "$role" = "iran" ]; then
    mutq systemctl restart frps.service
  else
    mutq systemctl restart frpc.service
  fi
}

services_stop_role() {
  is_systemd || return 0
  local role; role="$(cfg_get ROLE)"
  [ "$role" = "iran" ] && mutq systemctl stop frps.service || true
  [ "$role" = "foreign" ] && mutq systemctl stop frpc.service || true
}

service_active() { # <unit>
  is_systemd || return 1
  systemctl is-active --quiet "$1" 2>/dev/null
}

# Start the role service and make sure it stayed up; on config errors,
# fall back to the minimal config (drops optional keys) once.
services_start_verified() {
  local role unit
  role="$(cfg_get ROLE)"
  if [ "$role" = "iran" ]; then unit="frps.service"; else unit="frpc.service"; fi
  is_systemd || return 0

  services_restart_role || true
  sleep 2 2>/dev/null || true
  if service_active "$unit"; then
    ok "$unit is running"
    return 0
  fi

  warn "$unit failed to start — retrying with a minimal configuration"
  frp_config_write_minimal || true
  mutq systemctl restart "$unit" || true
  sleep 2 2>/dev/null || true
  if service_active "$unit"; then
    warn "$unit runs with the minimal config (some tuning keys unsupported by this frp build)"
    return 0
  fi
  err "$unit is still down — check: journalctl -u $unit -n 50"
  return 1
}

services_status() {
  is_systemd || { warn "systemd not available"; return 0; }
  local u state
  for u in gre-frp-tunnel.service gre-frp-tunnel-optimize.timer gre-frp-tunnel-frpupdate.timer frps.service frpc.service; do
    state="$(systemctl is-active "$u" 2>/dev/null || true)"
    case "$state" in
      active) printf '  %-38s %sactive%s\n' "$u" "$C_G" "$C_0" ;;
      inactive|failed|"") printf '  %-38s %sinactive%s\n' "$u" "$C_DIM" "$C_0" ;;
      *) printf '  %-38s %s%s%s\n' "$u" "$C_Y" "$state" "$C_0" ;;
    esac
  done
}

units_remove() {
  is_systemd && units_disable
  local name
  for name in $GRE_FRP_UNIT_NAMES; do
    if [ -f "$GRE_FRP_SYSTEMD_DIR/$name" ]; then
      mutq rm -f "$GRE_FRP_SYSTEMD_DIR/$name"
    fi
  done
  units_reload || true
  ok "systemd units removed"
}
