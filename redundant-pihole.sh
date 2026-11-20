#!/usr/bin/env bash
# ============================================================================
# redundant-pihole.sh
#
# Builds one node of a redundant Pi-hole v6 + Unbound pair on a bare
# Debian-family OS: Debian 12/13, Ubuntu 22.04+, or Raspberry Pi OS. Works on
# a Raspberry Pi, a VM, a mini PC, or anything else running one of those.
#
# Run it once on each box:
#   secondary:  sudo bash redundant-pihole.sh --role secondary --peer <PRIMARY_IP>
#   primary:    sudo bash redundant-pihole.sh --role primary   --peer <SECONDARY_IP>
#
# Build the secondary first so the primary's first sync succeeds right away.
# Either order works; the sync service just retries until the secondary exists.
#
# What each node gets:
#   - Unbound as a local recursive, DNSSEC-validating resolver on 127.0.0.1#5335
#   - Pi-hole v6, using only Unbound upstream, listening on all interfaces,
#     with Pi-hole's own DNSSEC off (Unbound already validates)
#   - The shared admin password, verified against the Pi-hole API
# Primary only:
#   - nebula-sync, which pushes the primary's full config to the secondary on a
#     schedule (one direction: make all changes on the primary)
# Optional (--vip):
#   - keepalived, which floats one virtual IP between the two boxes so clients
#     only ever need a single DNS address
#
# Re-running the script is safe. It skips the Pi-hole install if Pi-hole is
# already present and re-applies everything else.
# ============================================================================
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin

SCRIPT_VERSION="1.1.1"
LOG=/var/log/redundant-pihole.log

# ---- defaults (every one can be set by flag or environment variable) -------
ROLE="${ROLE:-}"
PEER_IP="${PEER_IP:-}"
PIHOLE_PASSWORD="${PIHOLE_PASSWORD:-}"
IFACE="${IFACE:-}"
VIP="${VIP:-}"
VRID="${VRID:-53}"
STATIC_CIDR="${STATIC_CIDR:-}"
GATEWAY="${GATEWAY:-}"
LOCAL_DOMAIN="${LOCAL_DOMAIN:-}"
ROUTER_IP="${ROUTER_IP:-}"
SYNC_CRON="${SYNC_CRON:-30 3 * * *}"
SYNC_TZ="${SYNC_TZ:-}"
NEBULA_VERSION="${NEBULA_VERSION:-latest}"
SKIP_SYNC="${SKIP_SYNC:-0}"
FIREBOG="${FIREBOG:-3}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

usage() {
  cat <<'EOF'
Usage: sudo bash redundant-pihole.sh --role primary|secondary --peer IP [options]

Required:
  --role primary|secondary   Which box this is. Make all changes on the primary.
  --peer IP                  IP address of the OTHER Pi-hole.

Password (both boxes must use the same one):
  --password PW              Admin password. Safer: set PIHOLE_PASSWORD in the
                             environment, or leave it out and you will be asked.

Optional:
  --vip IP                   Float a virtual IP between the pair with keepalived.
                             Use the same VIP on both boxes. Clients then only
                             need this one DNS address.
  --vrid N                   VRRP router ID for the VIP (default 53). Change it
                             only if something else on your LAN already uses 53.
  --interface NAME           Network interface (default: the one with the
                             default route).
  --static CIDR --gateway IP Set a static IP with NetworkManager, for example
                             --static 192.168.1.2/24 --gateway 192.168.1.1.
                             A DHCP reservation on your router is the simpler
                             option and is what I recommend.
  --local-domain NAME --router IP
                             Forward lookups for your LAN's domain (for example
                             "lan" or "home") and reverse lookups to your router,
                             so local hostnames resolve.
  --sync-schedule "CRON"     When the primary pushes to the secondary
                             (default "30 3 * * *", nightly at 3:30 AM).
  --timezone TZ              Timezone for the sync schedule (default: system).
  --nebula-version vX.Y.Z    Pin a nebula-sync release (default: latest).
  --no-sync                  On the primary, skip installing nebula-sync.
  --firebog N|allgreen       On the primary, add the top N green (least likely
                             to break sites) blocklists from each firebog.net
                             category, or every green list with "allgreen".
                             Default 3. The secondary gets them through sync.
  --no-firebog               Keep only Pi-hole's default blocklist.
  -y, --yes                 Never prompt. Fail if a required value is missing.
  -h, --help                 Show this help.
EOF
}

# ---- output helpers ---------------------------------------------------------
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; N=""; fi
step() { printf '\n%s==> %s%s\n' "$B$C" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '\n%sERROR:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
WARNINGS=()
trap 'die "Line $LINENO failed: $BASH_COMMAND (full log: $LOG)"' ERR

has_tty() { ( : </dev/tty ) 2>/dev/null; }

# ask VAR "Prompt" [default]
ask() {
  local __var=$1 __prompt=$2 __def=${3:-} __ans
  [[ -n ${!__var:-} ]] && return 0
  if [[ $NONINTERACTIVE == 1 ]] || ! has_tty; then
    if [[ -n $__def ]]; then printf -v "$__var" '%s' "$__def"; return 0; fi
    die "Missing required value: $__prompt. Pass it as a flag (see --help)."
  fi
  read -r -p "  $__prompt${__def:+ [$__def]}: " __ans </dev/tty
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

is_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( o <= 255 )) || return 1; done
}
# First A record from a lookup, or nothing. dig +short prints errors such as
# ";; communications error ... timed out" on stdout, so keep only IPv4 lines.
lookup_a() { # name server [port]
  dig +short +time=3 +tries=1 "$1" A @"$2" -p "${3:-53}" 2>/dev/null \
    | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$' || true
}
ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24) | (b<<16) | (c<<8) | d )); }
int2ip() { local n=$1; echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"; }
network_of() { # 192.168.1.50/24 -> 192.168.1.0/24
  local ip=${1%/*} p=${1#*/} mask
  mask=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  echo "$(int2ip $(( $(ip2int "$ip") & mask )))/$p"
}
same_subnet() { # cidr ip
  [[ $(network_of "$1") == "$(network_of "$2/${1#*/}")" ]]
}

# ---- argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --role)           ROLE=${2:-}; shift 2 ;;
    --peer)           PEER_IP=${2:-}; shift 2 ;;
    --password)       PIHOLE_PASSWORD=${2:-}; shift 2 ;;
    --vip)            VIP=${2:-}; shift 2 ;;
    --vrid)           VRID=${2:-}; shift 2 ;;
    --interface)      IFACE=${2:-}; shift 2 ;;
    --static)         STATIC_CIDR=${2:-}; shift 2 ;;
    --gateway)        GATEWAY=${2:-}; shift 2 ;;
    --local-domain)   LOCAL_DOMAIN=${2:-}; shift 2 ;;
    --router)         ROUTER_IP=${2:-}; shift 2 ;;
    --sync-schedule)  SYNC_CRON=${2:-}; shift 2 ;;
    --timezone)       SYNC_TZ=${2:-}; shift 2 ;;
    --nebula-version) NEBULA_VERSION=${2:-}; shift 2 ;;
    --no-sync)        SKIP_SYNC=1; shift ;;
    --firebog)        FIREBOG=${2:-}; shift 2 ;;
    --no-firebog)     FIREBOG=0; shift ;;
    -y|--yes)         NONINTERACTIVE=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this as root: sudo bash $0 ..."

# Log everything from here on, while still showing it on screen.
exec > >(tee -a "$LOG") 2>&1
printf '%s redundant-pihole.sh %s starting\n' "$(date -Is)" "$SCRIPT_VERSION" >>"$LOG"

# ============================================================================
step "Checking this system"
# ============================================================================
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release. Unsupported OS."
# shellcheck disable=SC1091
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *" debian "*|*" ubuntu "*|*" raspbian "*) ok "OS: ${PRETTY_NAME:-$ID}" ;;
  *) die "This script supports Debian, Ubuntu and Raspberry Pi OS. Found: ${PRETTY_NAME:-unknown}." ;;
esac
[[ -d /run/systemd/system ]] || die "systemd is not running. This script needs a systemd-based OS."
ARCH=$(dpkg --print-architecture)
case $ARCH in amd64|arm64|armhf|i386) ok "Architecture: $ARCH" ;;
  *) die "Unsupported CPU architecture: $ARCH" ;; esac
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null; }
curl -fsS -m 15 -o /dev/null https://install.pi-hole.net || die "No internet access (cannot reach install.pi-hole.net)."
ok "Internet access"

if [[ -z $IFACE ]]; then
  IFACE=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
fi
[[ -n $IFACE ]] && ip link show "$IFACE" >/dev/null 2>&1 || die "Could not find the network interface. Pass --interface NAME."
SELF_CIDR=$(ip -4 -o addr show dev "$IFACE" scope global | awk '{print $4}' | head -1)
[[ -n $SELF_CIDR ]] || die "Interface $IFACE has no IPv4 address."
SELF_IP=${SELF_CIDR%/*}
ok "Interface: $IFACE ($SELF_CIDR)"

# Something other than Pi-hole already serving DNS on port 53 would block FTL.
# Unbound is allowed: a run that stopped early leaves it on its default port 53,
# and the config below moves it to 5335.
if command -v ss >/dev/null; then
  port53=$(ss -Hlnup 'sport = :53' 2>/dev/null; ss -Hlntp 'sport = :53' 2>/dev/null) || true
  if [[ -n $port53 ]] && ! grep -qE 'pihole-FTL|systemd-resolve|unbound' <<<"$port53"; then
    die "Another DNS server is already using port 53: $(grep -oE 'users:\(\("[^"]+' <<<"$port53" | head -1 | cut -d'"' -f2). Remove it first."
  fi
fi

# ============================================================================
step "Settings"
# ============================================================================
ask ROLE "Is this box the primary or the secondary? (primary/secondary)"
ROLE=${ROLE,,}
[[ $ROLE == primary || $ROLE == secondary ]] || die "--role must be primary or secondary."
ask PEER_IP "IP address of the other Pi-hole ($( [[ $ROLE == primary ]] && echo secondary || echo primary ))"
is_ipv4 "$PEER_IP" || die "Peer IP is not a valid IPv4 address: $PEER_IP"
[[ $PEER_IP != "$SELF_IP" ]] || die "--peer is this box's own IP. It needs the OTHER Pi-hole's IP."

if [[ -z $PIHOLE_PASSWORD ]]; then
  if [[ $NONINTERACTIVE == 1 ]] || ! has_tty; then
    die "No admin password. Set PIHOLE_PASSWORD or pass --password."
  fi
  while :; do
    read -r -s -p "  Admin password (use the same one on both boxes): " p1 </dev/tty; echo
    read -r -s -p "  Confirm password: " p2 </dev/tty; echo
    [[ -n $p1 && $p1 == "$p2" ]] && break
    echo "  Passwords were empty or did not match. Try again."
  done
  PIHOLE_PASSWORD=$p1; unset p1 p2
fi
# nebula-sync stores "url|password" pairs separated by commas in a systemd
# environment file, so a few characters would break that format.
if [[ $PIHOLE_PASSWORD =~ [[:space:]\|,\"\'\\\$\`] ]]; then
  die "The password can't contain spaces or any of these characters: | , \" ' \\ \$ \`"
fi
(( ${#PIHOLE_PASSWORD} >= 8 )) || die "Use an admin password of at least 8 characters."

if [[ -n $VIP ]]; then
  is_ipv4 "$VIP" || die "--vip is not a valid IPv4 address: $VIP"
  same_subnet "$SELF_CIDR" "$VIP" || die "VIP $VIP is not in this box's subnet ($(network_of "$SELF_CIDR"))."
  [[ $VIP != "$SELF_IP" && $VIP != "$PEER_IP" ]] || die "The VIP must be a third, unused IP address."
  [[ $VRID =~ ^[0-9]+$ ]] && (( VRID >= 1 && VRID <= 255 )) || die "--vrid must be 1-255."
fi
if [[ -n $STATIC_CIDR ]]; then
  [[ $STATIC_CIDR == */* ]] && is_ipv4 "${STATIC_CIDR%/*}" || die "--static must look like 192.168.1.2/24"
  is_ipv4 "$GATEWAY" || die "--static also needs --gateway IP"
fi
if [[ -n $LOCAL_DOMAIN || -n $ROUTER_IP ]]; then
  [[ -n $LOCAL_DOMAIN ]] && is_ipv4 "$ROUTER_IP" || die "--local-domain and --router go together."
fi
FIREBOG=${FIREBOG,,}
[[ $FIREBOG == allgreen || $FIREBOG =~ ^[0-9]+$ ]] || die "--firebog must be a number or allgreen."
[[ -n $SYNC_TZ ]] || SYNC_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)

ok "Role: $ROLE   This box: $SELF_IP   Peer: $PEER_IP${VIP:+   VIP: $VIP}"

# ============================================================================
step "Updating the OS and installing packages"
# ============================================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
n_upd=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true)
if (( n_upd > 0 )); then
  echo "  Installing $n_upd OS update(s). On a fresh install this can take several minutes,"
  echo "  longer on a Raspberry Pi, and nothing prints while it runs. Let it finish."
  apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade >/dev/null
  ok "OS updates installed ($n_upd)"
else
  ok "OS is already up to date"
fi
PKGS=(unbound dns-root-data bind9-dnsutils curl ca-certificates iproute2)
[[ -n $VIP ]] && PKGS+=(keepalived)
apt-get -y -qq install "${PKGS[@]}" >/dev/null
ok "Installed: ${PKGS[*]}"

# Unbound asks the root servers directly, so this box needs outbound DNS
# (port 53). Firewall rules and DNS lockdowns that force all DNS through the
# router block that, and Unbound then just times out. Check before going on.
root_ok=0 root_aa=0
for root in 198.41.0.4 193.0.14.129 199.7.83.42; do # a, k and l.root-servers.net
  out=$(dig +norec +time=3 +tries=1 . NS @"$root" 2>/dev/null || true)
  if grep -q 'root-servers\.net' <<<"$out"; then
    root_ok=1
    grep -qE '^;; flags:[a-z ]* aa' <<<"$out" && root_aa=1
    break
  fi
done
if (( ! root_ok )); then
  die "This box can't reach the internet's root DNS servers on port 53, so Unbound won't work.
       Something on your network blocks outbound DNS: usually a firewall rule on the
       router, or a DNS lockdown or content-filtering feature. Exempt this box's IP
       ($SELF_IP) so it can reach any address on port 53 (TCP and UDP), then run
       this script again. Test with: dig +norec . NS @198.41.0.4"
elif (( ! root_aa )); then
  warn "Root DNS queries are answered, but not by a root server. Something on your network is intercepting DNS (UniFi Content Filtering does this). Exempt this box ($SELF_IP) from it."
else
  ok "Outbound DNS to the root servers works"
fi

# ============================================================================
step "Configuring Unbound (recursive DNS on 127.0.0.1#5335)"
# ============================================================================
# Based on the official guide: https://docs.pi-hole.net/guides/dns/unbound/
cat >/etc/unbound/unbound.conf.d/pi-hole.conf <<'CONF'
# Managed by redundant-pihole.sh
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    # Set do-ip6 to yes only if this box has working IPv6 to the internet.
    do-ip6: no
    prefer-ip6: no
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    edns-buffer-size: 1232
    prefetch: yes
    aggressive-nsec: yes
    num-threads: 1
    so-rcvbuf: 1m
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: fd00::/8
    private-address: fe80::/10
    private-address: 192.0.2.0/24
    private-address: 198.51.100.0/24
    private-address: 203.0.113.0/24
    private-address: 255.255.255.255/32
    private-address: 2001:db8::/32
CONF
# Stop Unbound from rewriting the system resolver (Debian 11 and later).
if systemctl list-unit-files unbound-resolvconf.service >/dev/null 2>&1; then
  systemctl disable --now unbound-resolvconf.service >/dev/null 2>&1 || true
fi
[[ -f /etc/resolvconf.conf ]] && sed -i 's/^unbound_conf=/#unbound_conf=/' /etc/resolvconf.conf
rm -f /etc/unbound/unbound.conf.d/resolvconf_resolvers.conf
# Let Unbound actually get the 1 MB receive buffer it asks for.
echo 'net.core.rmem_max=1048576' >/etc/sysctl.d/99-unbound.conf
sysctl -q -p /etc/sysctl.d/99-unbound.conf 2>/dev/null || warn "Could not apply net.core.rmem_max (normal inside containers)."
# The DNSSEC root trust anchor normally appears the first time Unbound starts.
# Create it now if it is missing, so the config check below can pass.
if [[ ! -s /var/lib/unbound/root.key ]]; then
  if [[ -x /usr/libexec/unbound-helper ]]; then
    /usr/libexec/unbound-helper root_trust_anchor_update >/dev/null 2>&1 || true
  elif command -v unbound-anchor >/dev/null; then
    unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1 || true
    chown unbound:unbound /var/lib/unbound/root.key 2>/dev/null || true
  fi
fi
unbound-checkconf >/dev/null || die "Unbound config check failed. Run: sudo unbound-checkconf"
systemctl enable unbound >/dev/null 2>&1
systemctl restart unbound
for i in {1..10}; do
  ans=$(lookup_a pi-hole.net 127.0.0.1 5335)
  [[ -n $ans ]] && break
  sleep 2
done
[[ -n ${ans:-} ]] || die "Unbound is not answering on 127.0.0.1#5335. Check: journalctl -u unbound"
ok "Unbound resolves pi-hole.net -> $ans"
# dnssec-failed.org has deliberately broken signatures. (fail01.dnssec.works,
# used in the Pi-hole docs, often gets no answer at all on a cold cache.)
dnssec=$(dig +time=10 +tries=1 dnssec-failed.org @127.0.0.1 -p 5335 2>/dev/null | grep -o 'status: [A-Z]*' || true)
if [[ $dnssec == "status: SERVFAIL" ]]; then ok "DNSSEC validation works (bad signature refused)"
else warn "DNSSEC test returned '${dnssec:-nothing}' instead of SERVFAIL."; fi

# ============================================================================
step "Installing Pi-hole v6"
# ============================================================================
if command -v pihole-FTL >/dev/null && command -v pihole >/dev/null; then
  ok "Pi-hole is already installed ($(pihole-FTL --version 2>/dev/null | head -1)). Re-applying settings."
else
  # A pre-seeded config file makes the official installer run with no dialogs.
  install -d -m 755 /etc/pihole
  cat >/etc/pihole/setupVars.conf <<CFG
PIHOLE_INTERFACE=$IFACE
PIHOLE_DNS_1=127.0.0.1#5335
QUERY_LOGGING=true
CFG
  inst=$(mktemp)
  curl -fsSL https://install.pi-hole.net -o "$inst"
  bash "$inst" --unattended || die "The Pi-hole installer failed. See /var/log/pihole/ and $LOG."
  rm -f "$inst"
  ok "Pi-hole installed"
fi

# ============================================================================
step "Applying Pi-hole settings"
# ============================================================================
ftl_set() { pihole-FTL --config "$1" "$2" >/dev/null && ok "$1 = $2"; }
ftl_set dns.upstreams '["127.0.0.1#5335"]'   # Unbound only, no public resolvers
ftl_set dns.listeningMode ALL                # answer every subnet/VLAN, and the VIP
ftl_set dns.dnssec false                     # Unbound validates; don't do it twice
if [[ -n $LOCAL_DOMAIN ]]; then
  SUBNET=$(network_of "$SELF_CIDR")
  ftl_set dns.domain.name "$LOCAL_DOMAIN"
  ftl_set dns.revServers "[\"true,$SUBNET,$ROUTER_IP,$LOCAL_DOMAIN\"]"
fi

# ============================================================================
step "Setting the admin password"
# ============================================================================
json_pw() { local p=${1//\\/\\\\}; p=${p//\"/\\\"}; printf '{"password":"%s"}' "$p"; }
# api_login URL PASSWORD: succeeds if the password is accepted, then logs out
api_login() {
  local body sid
  body=$(curl -sS -m 10 -X POST "$1/api/auth" -H 'Content-Type: application/json' \
         --data "$(json_pw "$2")" 2>/dev/null) || return 1
  [[ $body == *'"valid":true'* ]] || return 1
  sid=$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' <<<"$body")
  [[ -n $sid ]] && curl -sS -m 5 -X DELETE "$1/api/auth" -H "X-FTL-SID: $sid" >/dev/null 2>&1
  return 0
}
# api_sid URL PASSWORD: prints a session ID for later API calls
api_sid() {
  local body sid
  body=$(curl -sS -m 10 -X POST "$1/api/auth" -H 'Content-Type: application/json' \
         --data "$(json_pw "$2")" 2>/dev/null) || return 1
  sid=$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' <<<"$body")
  [[ -n $sid ]] && printf '%s' "$sid"
}
api_logout() { curl -sS -m 5 -X DELETE "$1/api/auth" -H "X-FTL-SID: $2" >/dev/null 2>&1 || true; }
wait_for_api() { # URL seconds
  local i
  for (( i=0; i<$2; i+=2 )); do
    curl -s -m 3 -o /dev/null "$1/api/auth" && return 0
    sleep 2
  done
  return 1
}
pw_ok=0
for _ in 1 2; do
  pihole setpassword "$PIHOLE_PASSWORD" >/dev/null
  systemctl restart pihole-FTL
  wait_for_api http://127.0.0.1 60 || die "The Pi-hole web server did not come up. Check: journalctl -u pihole-FTL"
  if api_login http://127.0.0.1 "$PIHOLE_PASSWORD"; then pw_ok=1; break; fi
  sleep 3
done
if (( pw_ok )); then ok "Password set and verified against the Pi-hole API"
else warn "The password did not verify. Run 'sudo pihole setpassword' and log in to check."; fi

# Quick end-to-end check: Pi-hole -> Unbound -> internet.
for i in {1..10}; do
  ans=$(lookup_a pi-hole.net 127.0.0.1)
  [[ -n $ans ]] && break; sleep 2
done
[[ -n ${ans:-} ]] && ok "Pi-hole resolves pi-hole.net -> $ans" || warn "Pi-hole is not resolving yet. Check: pihole status"

# ============================================================================
if [[ $ROLE == primary && $FIREBOG != 0 ]]; then
step "Adding firebog.net blocklists"
# ============================================================================
  # firebog.net publishes its lists as CSV for scripts, generated from its front
  # page: category,ticktype,source repo,description,list URL. "tick" marks the
  # green lists, the ones least likely to block sites people actually use.
  # The copy below is used only if firebog.net can't be reached (green lists as
  # of 2026-11-19). Lists only go on the primary; nebula-sync copies them over.
  FIREBOG_FALLBACK=$(cat <<'CSV'
"suspicious","tick","https://github.com/PolishFiltersTeam/KADhosts","PolishFiltersTeam KADhosts","https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt"
"suspicious","tick","https://github.com/FadeMind/hosts.extras/","Fademind's Spammers","https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Spam/hosts"
"suspicious","tick","https://v.firebog.net/hosts/static/w3kbl.txt","WaLLy3K's Blacklist","https://v.firebog.net/hosts/static/w3kbl.txt"
"advertising","tick","https://adaway.org/","AdAway","https://adaway.org/hosts.txt"
"advertising","tick","https://filters.adtidy.org/extension/chromium/filters/15.txt","Adguard DNS","https://v.firebog.net/hosts/AdguardDNS.txt"
"advertising","tick","https://github.com/LanikSJ/ubo-filters","LanikSJ's Admiral Anti-Adblock","https://v.firebog.net/hosts/Admiral.txt"
"advertising","tick","https://github.com/anudeepND/blacklist","Anudeep ND's Blacklist","https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt"
"advertising","tick","https://github.com/easylist/easylist","Easylist","https://v.firebog.net/hosts/Easylist.txt"
"advertising","tick","https://pgl.yoyo.org/adservers/","Peter Lowe's Adservers","https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext"
"advertising","tick","https://github.com/FadeMind/hosts.extras","Fademind's Unchecky Ads","https://raw.githubusercontent.com/FadeMind/hosts.extras/master/UncheckyAds/hosts"
"advertising","tick","https://github.com/bigdargon/hostsVN","hostsVN","https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts"
"tracking","tick","https://github.com/easylist/easylist","Easyprivacy","https://v.firebog.net/hosts/Easyprivacy.txt"
"tracking","tick","https://dsi.ut-capitole.fr/blacklists/index_en.php","Fabrice Prigent's Ads","https://v.firebog.net/hosts/Prigent-Ads.txt"
"tracking","tick","https://github.com/Fademind/hosts.extras","Fademind's 2o7 Network Trackers","https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.2o7Net/hosts"
"tracking","tick","https://github.com/crazy-max/WindowsSpyBlocker","Crazy Max's Microsoft Telemetry","https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt"
"tracking","tick","https://hostfiles.frogeye.fr/","Geoffrey Frogeye's First-Party Trackers","https://hostfiles.frogeye.fr/firstparty-trackers-hosts.txt"
"malicious","tick","https://github.com/DandelionSprout/adfilt","DandelionSprout's Anti Malware Filter","https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt"
"malicious","tick","https://dsi.ut-capitole.fr/blacklists/index_en.php","Fabrice Prigent's Cryptojacking","https://v.firebog.net/hosts/Prigent-Crypto.txt"
"malicious","tick","https://github.com/FadeMind/hosts.extras","Fademind's Risky Hosts","https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Risk/hosts"
"malicious","tick","https://www.phishing.army/","Phishing Army's Extended Blocklist","https://phishing.army/download/phishing_army_blocklist_extended.txt"
"malicious","tick","https://gitlab.com/quidsup/notrack-blocklists","Quidsup Malicious","https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-malware.txt"
"malicious","tick","https://github.com/Spam404/lists","Spam404","https://raw.githubusercontent.com/Spam404/lists/master/main-blacklist.txt"
"malicious","tick","https://github.com/AssoEchap/stalkerware-indicators","Echap's Stalkerware Indicators","https://raw.githubusercontent.com/AssoEchap/stalkerware-indicators/master/generated/hosts"
"malicious","tick","https://urlhaus.abuse.ch/api/","URLhaus Malicious URL blocklist","https://urlhaus.abuse.ch/downloads/hostfile/"
"malicious","tick","https://cyberhost.uk/malware-blocklist/","CyberHost.uk Malware Domains","https://lists.cyberhost.uk/malware.txt"
CSV
)
  # CSV on stdin -> "category<TAB>URL" for the green lists we want, in page order
  firebog_pick() {
    awk -F'","' -v n="$FIREBOG" '
      { gsub(/\r/, ""); gsub(/^"|"$/, "") }
      $2 == "tick" && $5 ~ /^https?:\/\/[^ "]+$/ && (n == "allgreen" || seen[$1]++ < n + 0) {
        print $1 "\t" $5 }'
  }
  picked=$(curl -fsSL -m 20 https://v.firebog.net/hosts/csv.txt 2>/dev/null | firebog_pick || true)
  if [[ -n $picked ]]; then
    src="firebog.net"
  else
    picked=$(firebog_pick <<<"$FIREBOG_FALLBACK")
    src="the copy built into this script"
    warn "Could not read the current lists from firebog.net, so I used the copy built into this script (2026-11-19)."
  fi

  sid=$(api_sid http://127.0.0.1 "$PIHOLE_PASSWORD") || die "Could not log in to this box's Pi-hole API to add blocklists."
  # Skip lists Pi-hole already has. The API rejects a whole request if every
  # address in it is a duplicate, so only new addresses get sent.
  existing=$(curl -sS -m 10 "http://127.0.0.1/api/lists?type=block" -H "X-FTL-SID: $sid" 2>/dev/null || true)
  new=""
  while IFS=$'\t' read -r category url; do
    [[ $existing == *"\"address\":\"$url\""* ]] || new+="$category"$'\t'"$url"$'\n'
  done <<<"$picked"
  total=$(grep -c . <<<"$picked" || true)
  sent=$(grep -c . <<<"$new" || true)
  present=$((total - sent)) added=0
  for category in $(cut -f1 <<<"$new" | awk 'NF && !seen[$0]++'); do
    urls=$(awk -F'\t' -v c="$category" '$1 == c { printf "%s\"%s\"", sep, $2; sep = "," }' <<<"$new")
    resp=$(curl -sS -m 30 -X POST "http://127.0.0.1/api/lists?type=block" -H "X-FTL-SID: $sid" \
           -H 'Content-Type: application/json' \
           --data "{\"address\":[$urls],\"comment\":\"firebog.net green list ($category)\",\"groups\":[0],\"enabled\":true}" 2>/dev/null || true)
    s=$(sed -n 's/.*"success":\[\(.*\)\].*/\1/p' <<<"$resp" | grep -o '"item"' | wc -l || true)
    added=$((added + s))
    [[ $resp == *'"errors":[]'* ]] || printf 'firebog %s: %s\n' "$category" "$resp" >>"$LOG"
  done
  failed=$((sent - added))
  api_logout http://127.0.0.1 "$sid"
  msg="$added added"; (( present == 0 )) || msg+=", $present already there"
  ok "Blocklists from $src: $msg"
  (( failed == 0 )) || warn "$failed blocklist(s) could not be added. See $LOG."

  echo "  Downloading the blocklists (pihole -g). This takes a minute or two..."
  if pihole -g >>"$LOG" 2>&1; then
    lists=$(pihole-FTL sqlite3 /etc/pihole/gravity.db "SELECT COUNT(*) FROM adlist WHERE enabled = 1 AND type = 0;")
    domains=$(pihole-FTL sqlite3 /etc/pihole/gravity.db "SELECT COUNT(DISTINCT domain) FROM gravity;")
    bad=$(pihole-FTL sqlite3 /etc/pihole/gravity.db "SELECT COUNT(*) FROM adlist WHERE enabled = 1 AND type = 0 AND status = 4;")
    ok "Gravity updated: $lists blocklists, $domains unique domains blocked"
    (( bad == 0 )) || warn "$bad blocklist(s) could not be downloaded. Check Lists in the admin UI."
  else
    warn "pihole -g (gravity update) failed. Run 'sudo pihole -g' to see why."
  fi
fi

# ============================================================================
if [[ $ROLE == primary && $SKIP_SYNC != 1 ]]; then
step "Installing nebula-sync (primary -> secondary)"
# ============================================================================
  case $ARCH in
    amd64) NARCH=linux_amd64 ;; arm64) NARCH=linux_arm64 ;; i386) NARCH=linux_386 ;;
    armhf) [[ $(uname -m) == armv6* ]] && NARCH=linux_armv6 || NARCH=linux_armv7 ;;
  esac
  if [[ $NEBULA_VERSION == latest ]]; then
    NEBULA_VERSION=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      https://github.com/lovelaze/nebula-sync/releases/latest | sed 's#.*/tag/##')
  fi
  [[ $NEBULA_VERSION == v* ]] || die "Could not work out the latest nebula-sync version."
  tmp=$(mktemp -d)
  base="https://github.com/lovelaze/nebula-sync/releases/download/$NEBULA_VERSION"
  tarball="nebula-sync_${NEBULA_VERSION#v}_${NARCH}.tar.gz"
  curl -fsSL -o "$tmp/$tarball" "$base/$tarball"
  curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"
  (cd "$tmp" && grep " $tarball\$" checksums.txt | sha256sum -c --quiet -) \
    || die "nebula-sync download failed its checksum. Not installing it."
  tar -xzf "$tmp/$tarball" -C "$tmp" nebula-sync
  install -m 755 "$tmp/nebula-sync" /usr/local/bin/nebula-sync
  rm -rf "$tmp"
  ok "nebula-sync $NEBULA_VERSION installed (checksum verified)"

  install -d -m 700 /etc/nebula-sync
  umask 077
  cat >/etc/nebula-sync/.env <<EOF
# Managed by redundant-pihole.sh. Holds the admin password, so root-only.
PRIMARY=http://$SELF_IP|$PIHOLE_PASSWORD
REPLICAS=http://$PEER_IP|$PIHOLE_PASSWORD
FULL_SYNC=true
RUN_GRAVITY=true
CRON=$SYNC_CRON
TZ=$SYNC_TZ
EOF
  umask 022
  cat >/etc/systemd/system/nebula-sync.service <<'UNIT'
[Unit]
Description=nebula-sync: push Pi-hole config from primary to secondary
After=network-online.target pihole-FTL.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/nebula-sync/.env
ExecStart=/usr/local/bin/nebula-sync run
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable nebula-sync >/dev/null 2>&1
  if api_login "http://$PEER_IP" "$PIHOLE_PASSWORD"; then
    ok "Logged in to the secondary at $PEER_IP"
    systemctl restart nebula-sync
    ok "Sync service started. First sync runs now, then on schedule: $SYNC_CRON ($SYNC_TZ)"
  else
    systemctl restart nebula-sync || true
    warn "Could not log in to the secondary at $PEER_IP yet. The sync service will keep retrying. Once the secondary is built, run: sudo systemctl restart nebula-sync"
  fi
fi

# ============================================================================
if [[ -n $VIP ]]; then
step "Configuring keepalived (virtual IP $VIP)"
# ============================================================================
  cat >/usr/local/bin/pihole-vip-check <<'CHK'
#!/bin/sh
# keepalived health check: this box keeps the VIP only while Pi-hole answers.
# pi.hole is answered by Pi-hole itself, so an internet outage does not cause a
# pointless failover. dig +short prints errors on stdout, so require a real
# IPv4 address in the answer rather than just any output.
dig +short +time=1 +tries=1 pi.hole A @127.0.0.1 2>/dev/null | grep -qE '^[0-9]+(\.[0-9]+){3}$'
CHK
  chmod 755 /usr/local/bin/pihole-vip-check
  if [[ $ROLE == primary ]]; then PRIO=150; else PRIO=100; fi
  AUTH=$(printf '%s' "$PIHOLE_PASSWORD" | sha256sum | cut -c1-8)
  cat >/etc/keepalived/keepalived.conf <<EOF
# Managed by redundant-pihole.sh
global_defs {
    enable_script_security
    script_user root
}
vrrp_script chk_pihole {
    script "/usr/local/bin/pihole-vip-check"
    interval 5
    timeout 3
    fall 2
    rise 2
}
vrrp_instance PIHOLE_VIP {
    state BACKUP
    interface $IFACE
    virtual_router_id $VRID
    priority $PRIO
    advert_int 1
    unicast_src_ip $SELF_IP
    unicast_peer {
        $PEER_IP
    }
    authentication {
        auth_type PASS
        auth_pass $AUTH
    }
    virtual_ipaddress {
        $VIP/${SELF_CIDR#*/} dev $IFACE
    }
    track_script {
        chk_pihole
    }
}
EOF
  chmod 600 /etc/keepalived/keepalived.conf
  /usr/local/bin/pihole-vip-check || warn "The health check fails right now, so this box will not take the VIP until Pi-hole answers."
  systemctl enable keepalived >/dev/null 2>&1
  systemctl restart keepalived
  sleep 6
  if ip -4 addr show dev "$IFACE" | grep -q " $VIP/"; then ok "This box currently holds the VIP $VIP"
  else ok "keepalived is running. The VIP is on the other box (normal for the secondary)."; fi
fi

# ============================================================================
if [[ -n $STATIC_CIDR ]]; then
step "Static IP $STATIC_CIDR"
# ============================================================================
  if systemctl is-active --quiet NetworkManager && command -v nmcli >/dev/null; then
    CON=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null | head -1)
    [[ -n $CON ]] || die "NetworkManager is not managing $IFACE."
    # This box asks itself first, then its peer, then the router, so it can still
    # resolve names (for updates and gravity) while its own Pi-hole restarts.
    cat >/usr/local/sbin/redundant-pihole-static.sh <<EOF
#!/bin/bash
sleep 4
nmcli con mod "$CON" ipv4.method manual ipv4.addresses "$STATIC_CIDR" ipv4.gateway "$GATEWAY" \
  ipv4.dns "127.0.0.1 $PEER_IP $GATEWAY" ipv4.dns-options "timeout:2 attempts:1" ipv4.ignore-auto-dns yes
nmcli con up "$CON"
EOF
    chmod 700 /usr/local/sbin/redundant-pihole-static.sh
    STATIC_PENDING=1
  else
    warn "NetworkManager is not running here, so I did not set a static IP. Set a DHCP reservation for $SELF_IP on your router instead, or configure netplan / /etc/network/interfaces by hand."
  fi
fi

# ============================================================================
step "Login message"
# ============================================================================
# Shown on every SSH login (pam_motd runs /etc/update-motd.d), so whoever logs
# in sees which box this is and, on the secondary, not to make changes here.
cat >/etc/redundant-pihole.conf <<EOF
# Written by redundant-pihole.sh. Read by /etc/update-motd.d/60-redundant-pihole.
ROLE=$ROLE
PEER_IP=$PEER_IP
VIP=$VIP
IFACE=$IFACE
SYNC=$([[ $ROLE == primary && $SKIP_SYNC != 1 ]] && echo 1 || echo 0)
EOF
mkdir -p /etc/update-motd.d
cat >/etc/update-motd.d/60-redundant-pihole <<'MOTD'
#!/bin/sh
# Login banner for a box built by redundant-pihole.sh.
[ -r /etc/redundant-pihole.conf ] || exit 0
# shellcheck source=/dev/null
. /etc/redundant-pihole.conf
B=$(printf '\033[1m'); Y=$(printf '\033[1;33m'); G=$(printf '\033[32m')
R=$(printf '\033[1;31m'); N=$(printf '\033[0m')
svc() {
  if systemctl is-active --quiet "$1" 2>/dev/null; then printf ' %s%s up%s' "$G" "$1" "$N"
  else printf ' %s%s DOWN%s' "$R" "$1" "$N"; fi
}
IP=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
IP=${IP%/*}
ROLE_UC=$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')
if [ "$ROLE" = primary ]; then OTHER=secondary; else OTHER=primary; fi

echo
echo "  ${B}=== Pi-hole ${ROLE_UC} === ${IP}${N}"
echo "  Partner:  $PEER_IP ($OTHER)"
echo "  Admin:    http://$IP/admin"
SERVICES="$(svc pihole-FTL)$(svc unbound)"
[ "$SYNC" = 1 ] && SERVICES="$SERVICES$(svc nebula-sync)"
[ -n "$VIP" ] && SERVICES="$SERVICES$(svc keepalived)"
echo "  Services:$SERVICES"
if [ -n "$VIP" ]; then
  if ip -4 addr show dev "$IFACE" | grep -q " $VIP/"; then
    echo "  VIP:      $VIP is on THIS box"
  else
    echo "  VIP:      $VIP is on the other box"
  fi
fi
echo
if [ "$ROLE" = primary ]; then
  echo "  Make all Pi-hole changes on this box. nebula-sync copies them to $PEER_IP."
else
  echo "  ${Y}DON'T MAKE CHANGES HERE.${N} The primary overwrites this box on every sync."
  echo "  Make changes on the primary instead: http://$PEER_IP/admin"
fi
echo "  Updates don't sync. Run 'sudo pihole -up' on each box, one at a time."
echo
MOTD
chmod 755 /etc/update-motd.d/60-redundant-pihole
ok "Login message shows this box's role on every SSH login"

# ============================================================================
step "Done"
# ============================================================================
FINAL_IP=${STATIC_CIDR%/*}; FINAL_IP=${FINAL_IP:-$SELF_IP}
cat <<EOF

  ${B}This box:${N}   $ROLE at $FINAL_IP
  ${B}Admin UI:${N}   http://$FINAL_IP/admin
  ${B}Upstream:${N}   Unbound on 127.0.0.1#5335 (recursive, DNSSEC)
EOF
if [[ $ROLE == primary && $SKIP_SYNC != 1 ]]; then
  echo "  ${B}Sync:${N}       nebula-sync -> $PEER_IP, schedule \"$SYNC_CRON\". Watch it: journalctl -u nebula-sync -f"
  echo "              Make every change on THIS box. The secondary is overwritten on each sync."
fi
if [[ $ROLE == secondary ]]; then
  echo "  ${B}Note:${N}       Don't make changes here. The primary ($PEER_IP) overwrites this box on each sync."
fi
echo
if [[ -n $VIP ]]; then
  echo "  ${B}Next:${N} in your router's DHCP settings, hand out $VIP as the only DNS server."
else
  echo "  ${B}Next:${N} in your router's DHCP settings, hand out both Pi-holes as DNS servers:"
  echo "        $( [[ $ROLE == primary ]] && echo "$SELF_IP and $PEER_IP" || echo "$PEER_IP and $SELF_IP" )"
fi
if (( ${#WARNINGS[@]} )); then
  echo; echo "  ${Y}Warnings:${N}"; for w in "${WARNINGS[@]}"; do echo "   - $w"; done
fi
echo "  Full log: $LOG"
if [[ ${STATIC_PENDING:-0} == 1 ]]; then
  echo
  echo "  ${Y}Switching to static IP ${STATIC_CIDR%/*} in a few seconds. Your SSH session will drop;${N}"
  echo "  ${Y}reconnect at the new address.${N}"
  nohup /usr/local/sbin/redundant-pihole-static.sh >/var/log/redundant-pihole-static.log 2>&1 &
fi
