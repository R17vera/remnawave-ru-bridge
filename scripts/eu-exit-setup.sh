#!/usr/bin/env bash
# EU exit node for a RU -> EU bridge on Remnawave.
#
# What it does on this box:
#   - REALITY selfsteal target: Caddy on 127.0.0.1:9443 with a self-issued certificate
#   - host firewall (own nft table): SSH open, the bridge port only from the RU entry,
#     the node port only from the panel; applied with an auto-rollback you must confirm
#   - x25519 keys + shortId (stored in /root/eu-bridge, reused on every rerun)
#   - prints the EU config profile for the panel and an "exit token" for ru-entry-setup.sh
# The Remnawave node itself (/opt/remnanode) must already be installed; it is never touched.
#
# Usage:
#   eu-exit-setup.sh --tag DE --domain de.example.com --ru-ip 203.0.113.10 \
#                    --panel-ip 198.51.100.5 --uuid <service user uuid> [--port 443] [--node-port 2222]
#   eu-exit-setup.sh ... --dry-run   only generate keys and print, change nothing on the box
#   eu-exit-setup.sh --confirm       keep the firewall (run after checking SSH from a NEW session)
#   eu-exit-setup.sh --rollback      remove the firewall now
#   eu-exit-setup.sh --print         print the profile and the token again
set -euo pipefail

STATE=${EU_BRIDGE_STATE:-/root/eu-bridge}
FW_TABLE=bridge_fw
FW_FILE=/etc/bridge-firewall.nft
FW_UNIT=bridge-firewall
ROLLBACK_MIN=5

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }
b64u() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

[ "$(id -u)" = 0 ] || die "run as root (sudo -i)"

fw_confirm() {
  systemctl stop $FW_UNIT-rollback.timer 2>/dev/null || true
  log "auto-rollback cancelled, firewall stays ($FW_UNIT: $(systemctl is-active $FW_UNIT))"
}
fw_rollback() {
  systemctl stop $FW_UNIT-rollback.timer 2>/dev/null || true
  systemctl disable --now $FW_UNIT >/dev/null 2>&1 || true
  nft delete table inet $FW_TABLE 2>/dev/null || true
  log "firewall removed"
}

TAG="" DOMAIN="" RU_IPS="" PANEL_IPS="" UUID="" NODE_PORT="" PORT=443 MODE=setup
while [ $# -gt 0 ]; do
  case "$1" in
    --tag)       TAG=$2; shift 2 ;;
    --domain)    DOMAIN=$2; shift 2 ;;
    --ru-ip)     RU_IPS=$2; shift 2 ;;
    --panel-ip)  PANEL_IPS=$2; shift 2 ;;
    --uuid)      UUID=$2; shift 2 ;;
    --port)      PORT=$2; shift 2 ;;
    --node-port) NODE_PORT=$2; shift 2 ;;
    --dry-run)   MODE=dry; shift ;;
    --print)     MODE=print; shift ;;
    --confirm)   fw_confirm; exit 0 ;;
    --rollback)  fw_rollback; exit 0 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

if [ "$MODE" = print ]; then
  [ -f "$STATE/eu-profile.json" ] || die "nothing to print yet, run the setup first"
  echo "----- EU config profile -----"; cat "$STATE/eu-profile.json"
  echo; echo "----- exit token (for ru-entry-setup.sh --exit) -----"; cat "$STATE/exit-token.txt"
  exit 0
fi

[ -n "$TAG" ] && [ -n "$DOMAIN" ] && [ -n "$RU_IPS" ] && [ -n "$PANEL_IPS" ] && [ -n "$UUID" ] \
  || die "required: --tag --domain --ru-ip --panel-ip --uuid (see --help)"
TAG=$(echo "$TAG" | tr '[:lower:]' '[:upper:]')
[[ $TAG =~ ^[A-Z0-9_]{1,16}$ ]] || die "--tag: latin letters, digits, _ (up to 16)"
[[ $DOMAIN =~ ^[A-Za-z0-9.-]+$ ]] || die "--domain looks wrong: $DOMAIN"
[[ $UUID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "--uuid is not a UUID"
[[ $PORT =~ ^[0-9]+$ ]] || die "--port must be a number"
ipv4_set() { # "1.2.3.4,5.6.7.8" -> "1.2.3.4, 5.6.7.8"
  local out="" ip
  for ip in ${1//,/ }; do
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "not an IPv4 address: $ip"
    out="${out:+$out, }$ip"
  done
  echo "$out"
}
RU_SET=$(ipv4_set "$RU_IPS")
PANEL_SET=$(ipv4_set "$PANEL_IPS")
if [ -z "$NODE_PORT" ]; then
  NODE_PORT=$(sed -n 's/^NODE_PORT=\([0-9]*\).*/\1/p' /opt/remnanode/.env 2>/dev/null | head -1)
  NODE_PORT=${NODE_PORT:-2222}
fi
PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
[ -n "$PUBLIC_IP" ] || die "cannot detect the public IPv4 of this box"

# ------------------------------------------------------------------ keys
install -d -m700 "$STATE"
if [ ! -f "$STATE/keys.env" ]; then
  log "generating x25519 keys and shortId"
  tmp=$(mktemp -d)
  openssl genpkey -algorithm X25519 -out "$tmp/k.pem" 2>/dev/null
  priv=$(openssl pkey -in "$tmp/k.pem" -outform DER | tail -c 32 | b64u)
  pub=$(openssl pkey -in "$tmp/k.pem" -pubout -outform DER | tail -c 32 | b64u)
  rm -rf "$tmp"
  ( umask 077; printf "PRIVATE_KEY='%s'\nPUBLIC_KEY='%s'\nSHORT_ID='%s'\n" "$priv" "$pub" "$(openssl rand -hex 8)" > "$STATE/keys.env" )
else
  log "reusing keys from $STATE/keys.env"
fi
# shellcheck disable=SC1091
. "$STATE/keys.env"

IN_TAG="${TAG}_BRIDGE_IN_FROM_RU"
( umask 077; cat > "$STATE/eu-profile.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": ["https+local://1.1.1.1/dns-query", "https+local://dns.google/dns-query", "localhost"],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "$IN_TAG",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "xver": 0,
          "minClientVer": "0.0.0",
          "target": "127.0.0.1:9443",
          "serverNames": ["$DOMAIN"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "type": "field", "domain": ["geosite:private"], "outboundTag": "BLOCK" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ]
  }
}
EOF
printf '{"tag":"%s","address":"%s","port":%s,"sni":"%s","pbk":"%s","sid":"%s","uuid":"%s"}' \
  "$TAG" "$PUBLIC_IP" "$PORT" "$DOMAIN" "$PUBLIC_KEY" "$SHORT_ID" "$UUID" | b64u | sed 's/^/bridge1:/' > "$STATE/exit-token.txt"
)

print_result() {
  cat <<EOF

=====================================================================
 1) EU config profile — paste it WHOLE into the panel
    (also saved to $STATE/eu-profile.json)
=====================================================================
EOF
  cat "$STATE/eu-profile.json"
  cat <<EOF

=====================================================================
 2) Exit token for the RU box (ru-entry-setup.sh --exit <token>)
    (also saved to $STATE/exit-token.txt)
=====================================================================
$(cat "$STATE/exit-token.txt")

 In the panel: service user $UUID -> squad with inbound $IN_TAG
EOF
}

if [ "$MODE" = dry ]; then print_result; exit 0; fi

# ------------------------------------------------------------------ packages
command -v apt-get >/dev/null || die "Debian/Ubuntu only"
export DEBIAN_FRONTEND=noninteractive
install_caddy() {
  command -v caddy >/dev/null && return 0
  apt-get update -qq
  if apt-cache policy caddy 2>/dev/null | grep -q 'Candidate: [0-9]'; then
    apt-get install -y -qq caddy >/dev/null
    return 0
  fi
  log "caddy is not in the distro repos, installing the official static build"
  local arch ver
  arch=$(dpkg --print-architecture)
  ver=$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
  [ -n "$ver" ] || die "cannot get the latest caddy version from GitHub"
  curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v$ver/caddy_${ver}_linux_${arch}.tar.gz" | tar -xz -C /usr/bin caddy
  getent group caddy >/dev/null || groupadd --system caddy
  id caddy >/dev/null 2>&1 || useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
  install -d -m755 /etc/caddy
  cat > /etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}
need=""
command -v nft >/dev/null || need="$need nftables"
command -v curl >/dev/null || need="$need curl"
if [ -n "$need" ]; then apt-get update -qq; apt-get install -y -qq $need >/dev/null; fi
install_caddy
if systemctl is-enabled nftables >/dev/null 2>&1; then
  log "WARNING: nftables.service is enabled. Its /etc/nftables.conf starts with 'flush ruleset' and wipes"
  log "         docker/remnanode rules on reboot. Recommended: systemctl disable nftables"
fi
if ss -tlnpH 'sport = :9443' | grep -v '"caddy"' | grep -q .; then
  die "port 9443 is taken by something other than caddy"
fi

# ------------------------------------------------------------------ selfsteal
TS=$(date +%Y%m%d-%H%M%S)
log "selfsteal for $DOMAIN on 127.0.0.1:9443"
[ -f /etc/caddy/Caddyfile ] && cp -a /etc/caddy/Caddyfile "$STATE/Caddyfile.bak-$TS"
install -d -m755 /var/www/selfsteal
cat > /var/www/selfsteal/index.html <<'EOF'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Технические работы</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:system-ui,-apple-system,sans-serif;background:#f5f6f8;color:#22262e}
main{max-width:420px;padding:32px;text-align:center}
h1{font-size:22px;font-weight:600;margin:0 0 12px}
p{margin:0;color:#5b6270;line-height:1.5}
</style>
</head>
<body>
<main>
<h1>Ведутся технические работы</h1>
<p>Сервис временно недоступен. Попробуйте зайти позже.</p>
</main>
</body>
</html>
EOF
cat > /etc/caddy/Caddyfile <<EOF
# REALITY selfsteal target: loopback only, self-issued certificate (no ACME, no DNS needed)
{
	auto_https disable_redirects
	skip_install_trust
}

https://$DOMAIN:9443 {
	bind 127.0.0.1
	tls internal
	root * /var/www/selfsteal
	file_server
	header -Server
}
EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
  || die "caddy validate failed (previous config: $STATE/Caddyfile.bak-$TS)"
systemctl enable caddy >/dev/null 2>&1
systemctl restart caddy
sleep 2
proto=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:9443 -servername "$DOMAIN" -tls1_3 2>/dev/null \
  | sed -n 's/^ *Protocol *: *//p' | head -1)
[ "$proto" = "TLSv1.3" ] || die "selfsteal does not answer TLS 1.3 on 127.0.0.1:9443 (see: journalctl -u caddy)"
log "selfsteal OK (TLS 1.3)"

# ------------------------------------------------------------------ firewall
if [ -f /etc/systemd/system/gd-firewall.service ]; then
  log "removing the older gd-firewall (replaced by $FW_UNIT)"
  systemctl disable --now gd-firewall >/dev/null 2>&1 || true
  nft delete table inet gd_fw 2>/dev/null || true
  rm -f /etc/systemd/system/gd-firewall.service /etc/gd-firewall.nft
fi
log "firewall: SSH open, $PORT only from [$RU_SET], $NODE_PORT only from [$PANEL_SET]"
nft list ruleset > "$STATE/ruleset.bak-$TS.nft" 2>/dev/null || true
cat > "$FW_FILE.new" <<EOF
# RU->EU bridge, exit side. Own table only: docker/remnanode tables are left alone.
# Loaded by $FW_UNIT.service; do NOT enable nftables.service (its config starts with flush ruleset).
table inet $FW_TABLE {}
delete table inet $FW_TABLE
table inet $FW_TABLE {
	set panel_v4 { type ipv4_addr; elements = { $PANEL_SET } }
	set ru_entry_v4 { type ipv4_addr; elements = { $RU_SET } }
	chain input {
		type filter hook input priority filter - 10; policy drop;
		iif "lo" accept
		ct state established,related accept
		meta l4proto { icmp, ipv6-icmp } accept
		udp dport { 68, 546 } accept
		tcp dport 22 accept
		ip saddr @ru_entry_v4 tcp dport $PORT accept
		ip saddr @panel_v4 tcp dport $NODE_PORT accept
	}
}
EOF
nft -c -f "$FW_FILE.new" || die "nft syntax check failed"
install -m600 "$FW_FILE.new" "$FW_FILE"; rm -f "$FW_FILE.new"
cat > /etc/systemd/system/$FW_UNIT.service <<EOF
[Unit]
Description=RU->EU bridge host firewall (nft table inet $FW_TABLE)
Wants=network-pre.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $FW_FILE
ExecStop=/usr/sbin/nft delete table inet $FW_TABLE

[Install]
WantedBy=multi-user.target
EOF
systemctl stop $FW_UNIT-rollback.timer 2>/dev/null || true
systemctl reset-failed $FW_UNIT-rollback.service $FW_UNIT-rollback.timer 2>/dev/null || true
systemd-run --quiet --unit=$FW_UNIT-rollback --on-active=${ROLLBACK_MIN}min \
  /bin/sh -c "systemctl disable $FW_UNIT; nft delete table inet $FW_TABLE"
systemctl daemon-reload
systemctl enable $FW_UNIT >/dev/null 2>&1
systemctl restart $FW_UNIT
log "firewall applied; it REMOVES ITSELF in $ROLLBACK_MIN min unless you confirm"

print_result
cat <<EOF

=====================================================================
 NOW: open a NEW SSH session to this server. If you can log in, run:
     bash $0 --confirm
 If you cannot — just wait $ROLLBACK_MIN minutes, the firewall removes itself.
=====================================================================
EOF
