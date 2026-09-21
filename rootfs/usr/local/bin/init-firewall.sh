#!/bin/bash
# Egress-Allowlist per iptables + ipset. Angelehnt an
# github.com/anthropics/claude-code/.devcontainer/init-firewall.sh, angepasst
# für rootless Podman (slirp4netns/pasta) und um Rust/Neovim-Quellen ergänzt.
#
# Erlaubt: DNS zu den konfigurierten Resolvern, loopback, GitHub-IP-Ranges
# (api.github.com/meta) und alles, was in /etc/devbox/allowed-domains.txt
# bzw. $DEVBOX_EXTRA_DOMAINS steht (zur Startzeit aufgelöst). Alles andere: REJECT.
set -euo pipefail
IFS=$'\n\t'

DOMAINS_FILE=/etc/devbox/allowed-domains.txt
log()  { echo "[firewall] $*"; }
warn() { echo "[firewall] WARNUNG: $*" >&2; }
die()  { echo "[firewall] FEHLER: $*" >&2; exit 1; }

# --- Reset ---------------------------------------------------------------------
iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT; iptables -P FORWARD ACCEPT
iptables -F; iptables -X
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
ipset destroy allowed-domains 2>/dev/null || true
ipset create allowed-domains hash:net

# --- Grundregeln ------------------------------------------------------------------
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS nur zu den Resolvern aus /etc/resolv.conf
mapfile -t RESOLVERS < <(awk '/^nameserver/ && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf)
[ "${#RESOLVERS[@]}" -gt 0 ] || die "keine IPv4-Nameserver in /etc/resolv.conf"
for ns in "${RESOLVERS[@]}"; do
  iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
done
log "DNS erlaubt zu: $(printf '%s ' "${RESOLVERS[@]}")"

# --- GitHub-IP-Ranges ------------------------------------------------------------------
gh_meta="$(curl -fsS --connect-timeout 10 https://api.github.com/meta 2>/dev/null || true)"
if [ -n "$gh_meta" ] && echo "$gh_meta" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
  n=0
  while read -r cidr; do
    [[ "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || continue
    ipset add allowed-domains "$cidr" -exist; n=$((n+1))
  done < <(echo "$gh_meta" | jq -r '(.web + .api + .git)[]' | grep -v ':' | aggregate -q)
  log "GitHub: $n IPv4-Ranges"
else
  warn "GitHub-Ranges nicht abrufbar - github.com evtl. nicht erreichbar"
fi

# --- Domains auflösen (parallel, über den glibc-Resolver wie curl/cargo) ---------------
mapfile -t DOMAINS < <(
  { [ -f "$DOMAINS_FILE" ] && sed 's/#.*//' "$DOMAINS_FILE"; echo "${DEVBOX_EXTRA_DOMAINS:-}" | tr ' ,' '\n\n'; } \
    | tr -d '[:blank:]' | grep -v '^$' | sort -u)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for domain in "${DOMAINS[@]}"; do
  ( timeout 10 getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u >"$tmp/$domain" ) &
done
wait
for domain in "${DOMAINS[@]}"; do
  if [ -s "$tmp/$domain" ]; then
    while read -r ip; do
      [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && ipset add allowed-domains "$ip" -exist
    done <"$tmp/$domain"
    log "$domain -> $(tr '\n' ' ' <"$tmp/$domain")"
  else
    warn "$domain nicht auflösbar"
  fi
done

# --- Host-Zugang (optional) -------------------------------------------------------------
# Standardmäßig NICHT erlaubt: unter pasta wäre das Gateway-/24 das echte LAN,
# unter slirp4netns erreicht 10.0.2.2 die Loopback-Dienste des Hosts.
if [ "${DEVBOX_ALLOW_HOST:-0}" = "1" ]; then
  gw="$(ip -4 route show default | awk '{print $3; exit}')"
  [ -n "$gw" ] && { iptables -A OUTPUT -d "$gw" -j ACCEPT; log "Host-Gateway $gw erlaubt (DEVBOX_ALLOW_HOST=1)"; }
fi

# --- Policy -------------------------------------------------------------------------------
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# IPv6 komplett zu (die Allowlist ist IPv4-only, sonst wäre sie per AAAA umgehbar)
if command -v ip6tables >/dev/null && ip6tables -L -n >/dev/null 2>&1; then
  ip6tables -F; ip6tables -X 2>/dev/null || true
  ip6tables -A INPUT -i lo -j ACCEPT; ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -P INPUT DROP; ip6tables -P OUTPUT DROP; ip6tables -P FORWARD DROP
  log "IPv6 gesperrt"
elif ip -6 route show default 2>/dev/null | grep -q .; then
  die "IPv6-Default-Route vorhanden, aber ip6tables nicht nutzbar - Allowlist wäre umgehbar"
fi

# --- Verifikation -----------------------------------------------------------------------------
if curl -sS --connect-timeout 5 https://example.com >/dev/null 2>&1; then
  die "example.com ist erreichbar - Firewall wirkt nicht"
fi
if curl -sS --connect-timeout 5 -o /dev/null https://api.anthropic.com 2>/dev/null; then
  log "OK: example.com blockiert, api.anthropic.com erreichbar"
else
  warn "api.anthropic.com nicht erreichbar (Netz offline oder DNS-Problem?)"
fi
