#!/usr/bin/env bash
# RU entry node for a RU -> EU bridge on Remnawave.
#
# What it does on this box:
#   - REALITY selfsteal target: Caddy on 127.0.0.1:9443 with a self-issued certificate
#   - host firewall (own nft table): SSH and the client ports open, the node port only from the panel;
#     applied with an auto-rollback you must confirm
#   - one client inbound per EU exit (own port, own keys), built from the exit tokens
#     that eu-exit-setup.sh printed; keys live in /root/ru-bridge and are reused on every rerun
#   - prints the full RU config profile for the panel and the host settings for clients
#   - --check: tests every RU -> EU leg from this box with the service user
# The Remnawave node itself (/opt/remnanode) must already be installed; it is never touched.
#
# Usage:
#   ru-entry-setup.sh --domain ru.example.com --panel-ip 198.51.100.5 \
#                     --exit <token> [--exit <token>@8443 ...] [--allow 192.0.2.7:10050] \
#                     [--no-ru-direct] [--node-port 2222]
#   ru-entry-setup.sh ... --dry-run  only generate keys and print, change nothing on the box
#   ru-entry-setup.sh --confirm      keep the firewall (run after checking SSH from a NEW session)
#   ru-entry-setup.sh --rollback     remove the firewall now
#   ru-entry-setup.sh --print        print the profile again
#   ru-entry-setup.sh --check        test the RU -> EU legs (after the profile is applied in the panel)
#
# Always pass ALL exits: the profile is rebuilt from the list on every run.
# Client ports are taken in order 443, 8443, 2053, 2083, 2087, 2096 unless set as <token>@<port>.
set -euo pipefail

STATE=${RU_BRIDGE_STATE:-/root/ru-bridge}
FW_TABLE=bridge_fw
FW_FILE=/etc/bridge-firewall.nft
FW_UNIT=bridge-firewall
ROLLBACK_MIN=5
DEFAULT_PORTS=(443 8443 2053 2083 2087 2096)

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

check_legs() {
  local profile="$STATE/ru-profile.json"
  [ -f "$profile" ] || die "no $profile yet, run the setup first"
  docker inspect remnanode >/dev/null 2>&1 || die "container 'remnanode' not found"
  command -v python3 >/dev/null || die "python3 is required for --check"
  local legs
  legs=$(python3 - "$profile" "$STATE" <<'PY'
import json, sys
profile, state = sys.argv[1], sys.argv[2]
p = json.load(open(profile))
outs = [o for o in p["outbounds"] if o["tag"].startswith("TO_")]
for i, o in enumerate(outs):
    o = dict(o, tag="proxy")
    cfg = {"log": {"loglevel": "warning"},
           "inbounds": [{"listen": "127.0.0.1", "port": 10900 + i, "protocol": "socks", "settings": {"udp": False}}],
           "outbounds": [o]}
    json.dump(cfg, open(f"{state}/check-{i}.json", "w"))
    print(f"{i} {outs[i]['tag'][3:]} {o['settings']['vnext'][0]['address']}")
PY
)
  echo "RU -> EU legs (service user, from this box):"
  echo "$legs" | while read -r i tag addr; do
    docker exec -i remnanode sh -c "cat > /tmp/bridge-check-$i.json && (timeout 25 rw-core run -config /tmp/bridge-check-$i.json >/tmp/bridge-check-$i.log 2>&1 &)" \
      < "$STATE/check-$i.json"
    sleep 2
    ip=$(curl -s -m 10 --socks5-hostname 127.0.0.1:$((10900 + i)) https://api.ipify.org || true)
    t=$(curl -s -m 15 -o /dev/null -w '%{time_total}' --socks5-hostname 127.0.0.1:$((10900 + i)) \
      'https://speed.cloudflare.com/__down?bytes=1000000' || echo "-")
    if [ "$ip" = "$addr" ]; then
      echo "  OK    $tag: exit IP $ip, 1 MB in ${t}s"
    elif [ -n "$ip" ]; then
      echo "  WARN  $tag: exit IP $ip (expected $addr), 1 MB in ${t}s"
    else
      echo "  FAIL  $tag: no traffic through $addr"
      docker exec remnanode sh -c "tail -3 /tmp/bridge-check-$i.log" | sed 's/^/        /'
    fi
    docker exec remnanode rm -f "/tmp/bridge-check-$i.json" "/tmp/bridge-check-$i.log"
    rm -f "$STATE/check-$i.json"
  done 2>/dev/null
}

DOMAIN="" PANEL_IPS="" NODE_PORT="" RU_DIRECT=1 MODE=setup
EXITS=() ALLOWS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)       DOMAIN=$2; shift 2 ;;
    --panel-ip)     PANEL_IPS=$2; shift 2 ;;
    --exit)         EXITS+=("$2"); shift 2 ;;
    --allow)        ALLOWS+=("$2"); shift 2 ;;
    --no-ru-direct) RU_DIRECT=0; shift ;;
    --node-port)    NODE_PORT=$2; shift 2 ;;
    --dry-run)      MODE=dry; shift ;;
    --print)        MODE=print; shift ;;
    --check)        check_legs; exit 0 ;;
    --confirm)      fw_confirm; exit 0 ;;
    --rollback)     fw_rollback; exit 0 ;;
    -h|--help)      sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

if [ "$MODE" = print ]; then
  [ -f "$STATE/ru-profile.json" ] || die "nothing to print yet, run the setup first"
  cat "$STATE/ru-profile.json"; echo; cat "$STATE/hosts.txt"
  exit 0
fi

[ -n "$DOMAIN" ] && [ -n "$PANEL_IPS" ] && [ ${#EXITS[@]} -gt 0 ] \
  || die "required: --domain --panel-ip and at least one --exit (see --help)"
[[ $DOMAIN =~ ^[A-Za-z0-9.-]+$ ]] || die "--domain looks wrong: $DOMAIN"
command -v python3 >/dev/null || { apt-get update -qq; apt-get install -y -qq python3 >/dev/null; }
ipv4_set() {
  local out="" ip
  for ip in ${1//,/ }; do
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "not an IPv4 address: $ip"
    out="${out:+$out, }$ip"
  done
  echo "$out"
}
PANEL_SET=$(ipv4_set "$PANEL_IPS")
if [ -z "$NODE_PORT" ]; then
  NODE_PORT=$(sed -n 's/^NODE_PORT=\([0-9]*\).*/\1/p' /opt/remnanode/.env 2>/dev/null | head -1)
  NODE_PORT=${NODE_PORT:-2222}
fi
PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
[ -n "$PUBLIC_IP" ] || die "cannot detect the public IPv4 of this box"

# ------------------------------------------------------------------ exits + keys
install -d -m700 "$STATE"
gen_keys() { # $1 = TAG -> $STATE/keys-TAG.env
  local f="$STATE/keys-$1.env" tmp priv pub
  [ -f "$f" ] && return 0
  tmp=$(mktemp -d)
  openssl genpkey -algorithm X25519 -out "$tmp/k.pem" 2>/dev/null
  priv=$(openssl pkey -in "$tmp/k.pem" -outform DER | tail -c 32 | b64u)
  pub=$(openssl pkey -in "$tmp/k.pem" -pubout -outform DER | tail -c 32 | b64u)
  rm -rf "$tmp"
  ( umask 077; printf "PRIVATE_KEY='%s'\nPUBLIC_KEY='%s'\nSHORT_ID='%s'\n" "$priv" "$pub" "$(openssl rand -hex 8)" > "$f" )
}
: > "$STATE/exits.tsv"; chmod 600 "$STATE/exits.tsv"
idx=0
for e in "${EXITS[@]}"; do
  token=${e%@*}; port=""
  [ "$token" != "$e" ] && port=${e##*@}
  [[ $token == bridge1:* ]] || die "an exit token must start with bridge1: (got: ${token:0:12}...)"
  json=$(printf '%s' "${token#bridge1:}" | tr -- '-_' '+/' | { b=$(cat); while [ $(( ${#b} % 4 )) -ne 0 ]; do b="$b="; done; printf '%s' "$b"; } | base64 -d 2>/dev/null) \
    || die "exit token #$((idx + 1)) is damaged (copy it again, as one line)"
  tag=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])') \
    || die "exit token #$((idx + 1)) is damaged (copy it again, as one line)"
  if [ -z "$port" ]; then
    [ $idx -lt ${#DEFAULT_PORTS[@]} ] || die "too many exits, set ports explicitly: --exit <token>@<port>"
    port=${DEFAULT_PORTS[$idx]}
  fi
  [[ $port =~ ^[0-9]+$ ]] || die "bad port for exit $tag: $port"
  gen_keys "$tag"
  printf '%s\t%s\t%s\n' "$tag" "$port" "$json" >> "$STATE/exits.tsv"
  idx=$((idx + 1))
done

python3 - "$STATE" "$DOMAIN" "$RU_DIRECT" "$PUBLIC_IP" <<'PY'
import json, os, sys
state, domain, ru_direct, public_ip = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]

def keys(tag):
    env = {}
    for line in open(f"{state}/keys-{tag}.env"):
        k, v = line.strip().split("=", 1)
        env[k] = v.strip("'")
    return env

inbounds, outbounds, route, hosts, seen_tags, seen_ports = [], [], [], [], set(), set()
for line in open(f"{state}/exits.tsv"):
    tag, port, raw = line.rstrip("\n").split("\t", 2)
    ex = json.loads(raw)
    if tag in seen_tags or port in seen_ports:
        sys.exit(f"ERROR: duplicate exit tag or port: {tag} / {port}")
    seen_tags.add(tag); seen_ports.add(port)
    k = keys(tag)
    in_tag, out_tag = f"ENTRY_{tag}_IN", f"TO_{tag}"
    inbounds.append({
        "tag": in_tag, "listen": "0.0.0.0", "port": int(port), "protocol": "vless",
        "settings": {"clients": [], "decryption": "none"},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": False},
        "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {
            "show": False, "xver": 0, "minClientVer": "0.0.0", "target": "127.0.0.1:9443",
            "serverNames": [domain], "privateKey": k["PRIVATE_KEY"], "shortIds": [k["SHORT_ID"]]}}})
    outbounds.append({
        "tag": out_tag, "protocol": "vless",
        "settings": {"vnext": [{"address": ex["address"], "port": ex["port"],
                                "users": [{"id": ex["uuid"], "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
        "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {
            "show": False, "serverName": ex["sni"], "fingerprint": "firefox",
            "publicKey": ex["pbk"], "shortId": ex["sid"]}}})
    route.append({"type": "field", "inboundTag": [in_tag], "outboundTag": out_tag})
    hosts.append((tag, in_tag, port, ex["address"], ex["uuid"]))

rules = [
    {"type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK"},
    {"type": "field", "domain": ["geosite:private"], "outboundTag": "BLOCK"},
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK"},
]
if ru_direct:
    rules += [
        {"type": "field", "domain": ["geosite:category-ru"], "outboundTag": "DIRECT"},
        {"type": "field", "ip": ["geoip:ru"], "outboundTag": "DIRECT"},
    ]
profile = {
    "log": {"loglevel": "warning"},
    "dns": {"servers": ["https+local://1.1.1.1/dns-query", "https+local://dns.google/dns-query", "localhost"],
            "queryStrategy": "UseIPv4"},
    "inbounds": inbounds,
    "outbounds": outbounds + [{"tag": "DIRECT", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
                              {"tag": "BLOCK", "protocol": "blackhole"}],
    "routing": {"domainStrategy": "IPIfNonMatch", "rules": rules + route},
}
old = os.umask(0o077)
json.dump(profile, open(f"{state}/ru-profile.json", "w"), indent=2, ensure_ascii=False)
with open(f"{state}/hosts.txt", "w") as f:
    f.write("Hosts for clients (panel -> Hosts -> create one per line):\n")
    for tag, in_tag, port, addr, uuid in hosts:
        f.write(f"  {tag}: inbound {in_tag} | address {domain} (or {public_ip}) | port {port} | "
                f"SNI {domain} | fingerprint firefox   -> exits via {addr}\n")
    f.write("\nSquads:\n")
    f.write("  clients -> " + ", ".join(h[1] for h in hosts) + "\n")
    for uuid in sorted({h[4] for h in hosts}):
        f.write(f"  service user {uuid} -> the <TAG>_BRIDGE_IN_FROM_RU inbound on each EU node\n")
os.umask(old)
PY
CLIENT_PORTS=$(cut -f2 "$STATE/exits.tsv" | paste -sd, - | sed 's/,/, /g')

print_result() {
  cat <<EOF

=====================================================================
 1) RU config profile — paste it WHOLE into the panel
    (also saved to $STATE/ru-profile.json)
=====================================================================
EOF
  cat "$STATE/ru-profile.json"
  echo
  echo "====================================================================="
  cat "$STATE/hosts.txt"
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
EXTRA_RULES=""
for a in "${ALLOWS[@]+"${ALLOWS[@]}"}"; do
  ips=${a%:*}; p=${a##*:}
  [[ $p =~ ^[0-9]+$ ]] && [ "$ips" != "$a" ] || die "--allow must look like IP[,IP]:PORT (got: $a)"
  EXTRA_RULES="$EXTRA_RULES		ip saddr { $(ipv4_set "$ips") } tcp dport $p accept
"
done
log "firewall: SSH + client ports [$CLIENT_PORTS] open, $NODE_PORT only from [$PANEL_SET]"
nft list ruleset > "$STATE/ruleset.bak-$TS.nft" 2>/dev/null || true
cat > "$FW_FILE.new" <<EOF
# RU->EU bridge, entry side. Own table only: docker/remnanode tables are left alone.
# Loaded by $FW_UNIT.service; do NOT enable nftables.service (its config starts with flush ruleset).
table inet $FW_TABLE {}
delete table inet $FW_TABLE
table inet $FW_TABLE {
	set panel_v4 { type ipv4_addr; elements = { $PANEL_SET } }
	chain input {
		type filter hook input priority filter - 10; policy drop;
		iif "lo" accept
		ct state established,related accept
		meta l4proto { icmp, ipv6-icmp } accept
		udp dport { 68, 546 } accept
		tcp dport 22 accept
		tcp dport { $CLIENT_PORTS } accept
		ip saddr @panel_v4 tcp dport $NODE_PORT accept
$EXTRA_RULES	}
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
 After the profile is applied in the panel: bash $0 --check
=====================================================================
EOF
