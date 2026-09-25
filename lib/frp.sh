#!/usr/bin/env bash
# ============================================================
# GRE+FRP-TUNNEL — lib/frp.sh
#   * always installs the LATEST frp release from fatedier/frp
#   * verifies the SHA-256 checksum published with the release
#   * generates frps.toml (Iran) / frpc.toml (foreign)
#   * TCP + UDP proxies for every port the user asked for
# ============================================================

[ -n "${GRE_FRP_FRP_LOADED:-}" ] && return 0
GRE_FRP_FRP_LOADED=1

GRE_FRP_FRP_API="${GRE_FRP_FRP_API:-https://api.github.com/repos/fatedier/frp/releases/latest}"
GRE_FRP_FRP_RELEASES="${GRE_FRP_FRP_RELEASES:-https://github.com/fatedier/frp/releases}"
GRE_FRP_DL_DIR="${GRE_FRP_DL_DIR:-${TMPDIR:-/tmp}/gre-frp-tunnel-dl}"

frp_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    armv7l|armv7)   echo arm ;;
    armv6l|armv6)   echo arm ;;
    i386|i486|i586|i686) echo 386 ;;
    mips)           echo mips ;;
    mips64)         echo mips64 ;;
    riscv64)        echo riscv64 ;;
    loongarch64)    echo loong64 ;;
    *)              echo "unsupported" ;;
  esac
}

# prints the newest release tag, e.g. v0.71.0
frp_latest_tag() {
  local json tag
  json="$(curl -fsSL --max-time 20 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: gre-frp-tunnel' "$GRE_FRP_FRP_API" 2>/dev/null || true)"

  if [ -n "$json" ]; then
    tag="$(printf '%s' "$json" \
      | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  fi

  # fallback: follow the /releases/latest redirect
  if ! frp_tag_valid "$tag"; then
    tag="$(curl -fsSI --max-time 20 "$GRE_FRP_FRP_RELEASES/latest" 2>/dev/null \
      | tr -d '\r' | sed -n 's#^[Ll]ocation:.*/tag/\(v[0-9][0-9.]*\)$#\1#p' | tail -1)"
  fi

  frp_tag_valid "$tag" || return 1
  printf '%s' "$tag"
}

frp_tag_valid() { case "${1:-}" in v[0-9]*.[0-9]*.[0-9]*) return 0 ;; *) return 1 ;; esac; }

frp_version_of() { printf '%s' "${1#v}"; }

frp_asset_name() { # <version-without-v> <arch>
  printf 'frp_%s_linux_%s.tar.gz' "$1" "$2"
}

frp_asset_url() { # <tag> <asset>
  printf '%s/download/%s/%s' "$GRE_FRP_FRP_RELEASES" "$1" "$2"
}

frp_installed_version() {
  local bin="${GRE_FRP_BIN_DIR}/frps" v
  [ -x "$bin" ] || return 1
  v="$("$bin" --version 2>/dev/null | head -1 | sed -n 's/[^0-9]*\([0-9][0-9.]*\).*/\1/p')"
  [ -n "$v" ] && printf '%s' "$v" || return 1
}

# frp_install_latest [tag] — download, verify, install frps+frpc
frp_install_latest() {
  local tag="${1:-}" arch ver asset url sha_ok bak_stamp
  arch="$(frp_arch)"
  if [ "$arch" = "unsupported" ]; then
    err "unsupported CPU architecture: $(uname -m)"
    return 1
  fi

  if [ "$GRE_FRP_DRY_RUN" = "1" ]; then
    info "dry-run: would install the latest frp release for linux/$arch"
    return 0
  fi

  if [ -z "$tag" ]; then
    info "looking up the latest frp release…"
    tag="$(frp_latest_tag)" || { err "could not reach the fatedier/frp release API"; return 1; }
  fi
  ver="$(frp_version_of "$tag")"
  asset="$(frp_asset_name "$ver" "$arch")"
  url="$(frp_asset_url "$tag" "$asset")"

  info "latest frp: ${C_BOLD}${tag}${C_0} (linux/${arch})"
  mkdir -p "$GRE_FRP_DL_DIR" 2>/dev/null || true
  local tarball="$GRE_FRP_DL_DIR/$asset"
  local chk_file="$GRE_FRP_DL_DIR/frp_sha256_checksums.txt"

  if ! mutq curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
        -o "$tarball" "$url"; then
    err "download failed: $url"
    return 1
  fi

  # ---- checksum -------------------------------------------------------
  if mutq curl -fsSL --max-time 60 -o "$chk_file" \
        "$(frp_asset_url "$tag" frp_sha256_checksums.txt)"; then
    local want got
    want="$(grep -E "[[:space:]]${asset}\$" "$chk_file" 2>/dev/null | awk '{print $1}' | head -1)"
    if [ -n "$want" ] && have sha256sum; then
      got="$(sha256sum "$tarball" | awk '{print $1}')"
      if [ "$want" = "$got" ]; then
        ok "sha256 verified"
      else
        err "checksum mismatch for $asset (expected $want, got $got)"
        rm -f "$tarball"
        return 1
      fi
    elif [ -n "$want" ]; then
      warn "sha256sum is not installed — skipping checksum verification"
    fi
    rm -f "$chk_file"
  else
    warn "could not download the checksum file — skipping verification"
  fi

  # ---- extract --------------------------------------------------------
  local extract="$GRE_FRP_DL_DIR/extract"
  rm -rf "$extract"; mkdir -p "$extract"
  if ! tar -xzf "$tarball" -C "$extract" 2>/dev/null; then
    err "the downloaded archive is not a valid tar.gz"
    rm -f "$tarball"
    return 1
  fi
  local src="$extract/frp_${ver}_linux_${arch}"
  if [ ! -f "$src/frps" ] || [ ! -f "$src/frpc" ]; then
    err "archive does not contain frps/frpc"
    return 1
  fi

  # ---- install (with rollback) ---------------------------------------
  mkdir -p "$GRE_FRP_BIN_DIR" 2>/dev/null || true
  bak_stamp="$(date '+%Y%m%d%H%M%S')"
  local b
  for b in frps frpc; do
    if [ -f "$GRE_FRP_BIN_DIR/$b" ]; then
      mutq cp -f "$GRE_FRP_BIN_DIR/$b" "$GRE_FRP_BIN_DIR/$b.bak-$bak_stamp" || true
    fi
    if ! mutq cp -f "$src/$b" "$GRE_FRP_BIN_DIR/$b"; then
      err "could not install $b into $GRE_FRP_BIN_DIR"
      return 1
    fi
    mutq chmod 0755 "$GRE_FRP_BIN_DIR/$b" || true
  done

  local newver
  newver="$(frp_installed_version || true)"
  if [ -z "$newver" ]; then
    warn "the newly installed frps did not report a version — rolling back"
    [ -f "$GRE_FRP_BIN_DIR/frps.bak-$bak_stamp" ] && mutq cp -f "$GRE_FRP_BIN_DIR/frps.bak-$bak_stamp" "$GRE_FRP_BIN_DIR/frps" || true
    [ -f "$GRE_FRP_BIN_DIR/frpc.bak-$bak_stamp" ] && mutq cp -f "$GRE_FRP_BIN_DIR/frpc.bak-$bak_stamp" "$GRE_FRP_BIN_DIR/frpc" || true
    return 1
  fi

  cfg_set FRP_VERSION "$newver"
  cfg_set FRP_TAG "$tag"
  cfg_set FRP_ARCH "$arch"
  cfg_set FRP_INSTALLED_AT "$(date '+%Y-%m-%d %H:%M:%S')"
  rm -rf "$extract" "$tarball" 2>/dev/null || true
  ok "frp ${newver} installed ($GRE_FRP_BIN_DIR/frps, $GRE_FRP_BIN_DIR/frpc)"
  return 0
}

# frp_update_if_needed — used by the daily timer
frp_update_if_needed() {
  local latest current
  current="$(frp_installed_version || echo none)"
  latest="$(frp_latest_tag)" || { warn "cannot check the latest frp release"; return 1; }
  latest="$(frp_version_of "$latest")"
  if [ "$current" = "$latest" ]; then
    dim "frp is already up to date ($current)"
    return 0
  fi
  info "updating frp ${current} → ${latest}"
  frp_install_latest "v${latest}"
}

# ------------------------------------------------------------
# Port helpers
# ------------------------------------------------------------
# ports_validate "443,8443" -> accepts only digits, commas, dashes
ports_validate() {
  local spec="${1:-}"
  [ -n "$spec" ] || return 1
  case "$spec" in *[!0-9,\-]*) return 1 ;; esac
  ports_parse "$spec" >/dev/null 2>&1 || return 1
  return 0
}

# ports_parse "443,8443,2000-2003" -> one port per line, sorted, unique
ports_parse() {
  local spec="$1" part a b i
  [ -n "$spec" ] || return 0
  spec="${spec// /}"
  case "$spec" in *[!0-9,\-]*) return 1 ;; esac
  local -a out=()
  local IFS=','
  for part in $spec; do
    # an empty element means the user typed "443,," or a trailing comma
    [ -n "$part" ] || return 1
    case "$part" in
      *-*)
        a="${part%%-*}"; b="${part##*-}"
        is_port "$a" && is_port "$b" || return 1
        [ "$a" -le "$b" ] || return 1
        [ $(( b - a )) -gt 1000 ] && return 1
        for (( i = a; i <= b; i++ )); do out+=("$i"); done
        ;;
      *)
        is_port "$part" || return 1
        out+=("$part")
        ;;
    esac
  done
  [ "${#out[@]}" -gt 0 ] || return 1
  printf '%s\n' "${out[@]}" | sort -n -u
}

ports_count() { ports_parse "$1" 2>/dev/null | wc -l | tr -d ' '; }

ports_list_csv() { ports_parse "$1" 2>/dev/null | paste -sd, -; }

ssh_ports() {
  local p
  if [ -r /etc/ssh/sshd_config ]; then
    p="$(awk 'tolower($1)=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null)"
  fi
  for x in $p 22; do printf '%s\n' "$x"; done | sort -n -u
}

# ports_ssh_conflict "443,22"  -> prints the conflicting ports
ports_ssh_conflict() {
  local spec="$1" a b
  for a in $(ports_parse "$spec" 2>/dev/null); do
    for b in $(ssh_ports); do
      [ "$a" = "$b" ] && printf '%s ' "$a"
    done
  done
  return 0
}

# ------------------------------------------------------------
# Config generation
# ------------------------------------------------------------
# udpPacketSize must be identical on both ends, so it is decided once at
# setup time from the then-current MTU and stored in the state file. The
# hourly optimizer is free to change the MTU without desynchronising the
# two sides.
frp_udp_packet_size() {
  local size; size="$(cfg_get UDP_PACKET_SIZE)"
  if is_uint "$size" && [ "$size" -ge 512 ]; then
    printf '%s' "$size"
    return
  fi
  local mtu; mtu="$(cfg_get TUNNEL_MTU "$GRE_FRP_DEFAULT_MTU")"
  is_uint "$mtu" || mtu="$GRE_FRP_DEFAULT_MTU"
  size=$(( mtu - 28 ))
  [ "$size" -gt 1444 ] && size=1444
  [ "$size" -lt 512 ] && size=512
  printf '%s' "$size"
}

frp_udp_packet_size_lock_in() {
  local size; size="$(frp_udp_packet_size)"
  cfg_set UDP_PACKET_SIZE "$size"
  printf '%s' "$size"
}

frp_log_path() { printf '%s/%s.log' "$GRE_FRP_LOG_DIR" "$1"; }

# ------------------------------------------------------------
# Shared auth token
#
# frps and frpc must use exactly the same token. Rather than asking
# the user to copy a secret from one server to the other, it is
# derived from the (order independent) pair of public IPs, so both
# servers compute the same value on their own. Override it with
# GRE_FRP_TOKEN if you prefer your own secret.
# ------------------------------------------------------------
frp_derive_token() {
  local a="${1:-}" b="${2:-}" t
  [ -n "$a" ] && [ -n "$b" ] || return 1
  if [ "$a" \> "$b" ]; then t="$a"; a="$b"; b="$t"; fi
  if have sha256sum; then
    printf '%s' "gre-frp-tunnel|${a}|${b}" | sha256sum | cut -c1-32
    return 0
  fi
  if have md5sum; then
    printf '%s' "gre-frp-tunnel|${a}|${b}" | md5sum | cut -c1-32
    return 0
  fi
  return 1
}

frp_token_resolve() {
  local token="${GRE_FRP_TOKEN:-}"
  if [ -z "$token" ]; then token="$(cfg_get AUTH_TOKEN)"; fi
  if [ -z "$token" ]; then
    token="$(frp_derive_token "$(cfg_get LOCAL_PUBLIC_IP)" "$(cfg_get PEER_PUBLIC_IP)" || true)"
    if [ -n "$token" ]; then
      dim "auth token derived from the server IP pair (both sides compute the same value)"
    else
      token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      warn "cannot derive an auth token — a random one was generated:"
      warn "copy it to the other server or set GRE_FRP_TOKEN there as well"
    fi
  fi
  cfg_set AUTH_TOKEN "$token"
  printf '%s' "$token"
}

frp_config_write() {
  local role; role="$(cfg_get ROLE)"
  local ctrl gre_local gre_remote token udpsize ports
  ctrl="$(cfg_get CTRL_PORT "$GRE_FRP_DEFAULT_CTRL_PORT")"
  gre_local="$(cfg_get GRE_IP_LOCAL "$GRE_FRP_DEFAULT_GRE_IP_IRAN")"
  gre_remote="$(cfg_get GRE_IP_REMOTE "$GRE_FRP_DEFAULT_GRE_IP_FOREIGN")"
  token="$(frp_token_resolve)"
  udpsize="$(frp_udp_packet_size)"
  ports="$(cfg_get TUNNEL_PORTS)"

  mkdir -p "$GRE_FRP_FRP_ETC_DIR" 2>/dev/null || true

  if [ "$role" = "iran" ]; then
    frp_config_write_server "$gre_local" "$ctrl" "$token" "$udpsize"
  else
    frp_config_write_client "$gre_remote" "$ctrl" "$token" "$udpsize" "$ports"
  fi
}

frp_config_write_server() {
  local gre_local="$1" ctrl="$2" token="$3" udpsize="$4"
  {
    echo "# ============================================================"
    echo "# frps — managed by ${GRE_FRP_APP_NAME}, do not edit by hand"
    echo "# Service side (Iran relay): listens on the GRE link only."
    echo "# ============================================================"
    echo "bindAddr = \"$gre_local\""
    echo "bindPort = $ctrl"
    echo "proxyBindAddr = \"0.0.0.0\""
    echo ""
    echo "auth.method = \"token\""
    echo "auth.token = \"$token\""
    echo ""
    echo "transport.tcpMux = true"
    echo "transport.maxPoolCount = 5"
    echo "transport.heartbeatTimeout = 90"
    echo ""
    echo "# Keeps UDP datagrams inside the GRE MTU so they never fragment."
    echo "udpPacketSize = $udpsize"
    echo ""
    echo "log.to = \"$(frp_log_path frps)\""
    echo "log.level = \"info\""
    echo "log.maxDays = 3"
  } | put_file "$GRE_FRP_FRP_ETC_DIR/frps.toml"
  ok "wrote $GRE_FRP_FRP_ETC_DIR/frps.toml"
}

frp_config_write_client() {
  local server_addr="$1" ctrl="$2" token="$3" udpsize="$4" ports="$5"
  local local_ip; local_ip="$(cfg_get LOCAL_TARGET_IP "127.0.0.1")"
  local mtu; mtu="$(cfg_get TUNNEL_MTU "$GRE_FRP_DEFAULT_MTU")"

  {
    echo "# ============================================================"
    echo "# frpc — managed by ${GRE_FRP_APP_NAME}, do not edit by hand"
    echo "# Client side (foreign server running the VPN panel)."
    echo "# Connects to the Iran relay over the GRE link, so every"
    echo "# tunnelled port is exposed on the Iranian public IP."
    echo "# ============================================================"
    echo "serverAddr = \"$server_addr\""
    echo "serverPort = $ctrl"
    echo ""
    echo "auth.method = \"token\""
    echo "auth.token = \"$token\""
    echo ""
    echo "transport.tcpMux = true"
    echo "transport.poolCount = 5"
    echo "transport.dialServerTimeout = 10"
    echo "transport.dialServerKeepalive = 7200"
    echo "transport.heartbeatInterval = 10"
    echo "transport.heartbeatTimeout = 30"
    echo ""
    echo "# Keeps UDP datagrams inside the GRE MTU so they never fragment."
    echo "udpPacketSize = $udpsize"
    echo ""
    echo "log.to = \"$(frp_log_path frpc)\""
    echo "log.level = \"info\""
    echo "log.maxDays = 3"
    echo ""
    echo "# --- ${mtu} byte tunnel: one TCP + one UDP proxy per port ---"
    local p
    for p in $(ports_parse "$ports" 2>/dev/null); do
      cat <<EOF

[[proxies]]
name = "tcp-$p"
type = "tcp"
localIP = "$local_ip"
localPort = $p
remotePort = $p
transport.useEncryption = false
transport.useCompression = false

[[proxies]]
name = "udp-$p"
type = "udp"
localIP = "$local_ip"
localPort = $p
remotePort = $p
transport.useEncryption = false
transport.useCompression = false
EOF
    done
  } | put_file "$GRE_FRP_FRP_ETC_DIR/frpc.toml"
  ok "wrote $GRE_FRP_FRP_ETC_DIR/frpc.toml ($(ports_count "$ports") ports × TCP+UDP)"
}

# A stripped down but always-valid variant, used when the installed frp
# build rejects one of the optional tuning keys.
frp_config_write_minimal() {
  local role; role="$(cfg_get ROLE)"
  local ctrl token gre_local gre_remote
  ctrl="$(cfg_get CTRL_PORT "$GRE_FRP_DEFAULT_CTRL_PORT")"
  gre_local="$(cfg_get GRE_IP_LOCAL)"
  gre_remote="$(cfg_get GRE_IP_REMOTE)"
  token="$(frp_token_resolve)"
  local udpsize; udpsize="$(frp_udp_packet_size)"

  if [ "$role" = "iran" ]; then
    {
      echo "bindAddr = \"$gre_local\""
      echo "bindPort = $ctrl"
      echo "proxyBindAddr = \"0.0.0.0\""
      echo "auth.method = \"token\""
      echo "auth.token = \"$token\""
      echo "log.to = \"$(frp_log_path frps)\""
    } | put_file "$GRE_FRP_FRP_ETC_DIR/frps.toml"
  else
    local local_ip p; local_ip="$(cfg_get LOCAL_TARGET_IP "127.0.0.1")"
    {
      echo "serverAddr = \"$gre_remote\""
      echo "serverPort = $ctrl"
      echo "auth.method = \"token\""
      echo "auth.token = \"$token\""
      echo "udpPacketSize = $udpsize"
      echo "log.to = \"$(frp_log_path frpc)\""
      for p in $(ports_parse "$(cfg_get TUNNEL_PORTS)" 2>/dev/null); do
        printf '\n[[proxies]]\nname = "tcp-%s"\ntype = "tcp"\nlocalIP = "%s"\nlocalPort = %s\nremotePort = %s\n' "$p" "$local_ip" "$p" "$p"
        printf '\n[[proxies]]\nname = "udp-%s"\ntype = "udp"\nlocalIP = "%s"\nlocalPort = %s\nremotePort = %s\n' "$p" "$local_ip" "$p" "$p"
      done
    } | put_file "$GRE_FRP_FRP_ETC_DIR/frpc.toml"
  fi
  warn "minimal frp configuration written"
}

# Write the *other* side's config so it can be copied to the peer host
frp_config_write_peer_copy() {
  local out="${1:-$GRE_FRP_STATE_DIR}"
  mkdir -p "$out" 2>/dev/null || true
  local role; role="$(cfg_get ROLE)"
  local ctrl gre_local gre_remote token udpsize ports
  ctrl="$(cfg_get CTRL_PORT "$GRE_FRP_DEFAULT_CTRL_PORT")"
  gre_local="$(cfg_get GRE_IP_LOCAL)"
  gre_remote="$(cfg_get GRE_IP_REMOTE)"
  token="$(frp_token_resolve)"
  udpsize="$(frp_udp_packet_size)"
  ports="$(cfg_get TUNNEL_PORTS)"

  if [ "$role" = "iran" ]; then
    # this is the relay: the peer (foreign) needs an frpc.toml
    if [ "$GRE_FRP_DRY_RUN" != "1" ]; then
      frp_config_write_client "$gre_local" "$ctrl" "$token" "$udpsize" "$ports" \
        >/dev/null 2>&1 || true
      [ -f "$GRE_FRP_FRP_ETC_DIR/frpc.toml" ] \
        && mv "$GRE_FRP_FRP_ETC_DIR/frpc.toml" "$out/frpc.toml.peer" 2>/dev/null || true
    fi
    printf '%s' "$out/frpc.toml.peer"
  else
    if [ "$GRE_FRP_DRY_RUN" != "1" ]; then
      frp_config_write_server "$gre_remote" "$ctrl" "$token" "$udpsize" >/dev/null 2>&1 || true
      [ -f "$GRE_FRP_FRP_ETC_DIR/frps.toml" ] \
        && mv "$GRE_FRP_FRP_ETC_DIR/frps.toml" "$out/frps.toml.peer" 2>/dev/null || true
    fi
    printf '%s' "$out/frps.toml.peer"
  fi
}
