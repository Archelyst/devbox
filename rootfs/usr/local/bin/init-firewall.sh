#!/bin/bash
# Egress allowlist via iptables + ipset. Modelled on
# github.com/anthropics/claude-code/.devcontainer/init-firewall.sh, adapted for
# rootless Podman (slirp4netns/pasta) and extended with the Rust/Neovim sources.
#
# Allowed: DNS to the configured resolvers, loopback, the GitHub IP ranges
# (api.github.com/meta) and everything listed in /etc/devbox/allowed-domains.txt
# or $DEVBOX_EXTRA_DOMAINS (resolved at startup). Everything else: REJECT.
set -euo pipefail
IFS=$'\n\t'

DOMAINS_FILE=/etc/devbox/allowed-domains.txt
log()  { echo "[firewall] $*"; }
warn() { echo "[firewall] WARNING: $*" >&2; }
die()  { echo "[firewall] ERROR: $*" >&2; exit 1; }

# --- Reset ---------------------------------------------------------------------
iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT; iptables -P FORWARD ACCEPT
iptables -F; iptables -X
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
ipset destroy allowed-domains 2>/dev/null || true
ipset create allowed-domains hash:net

# --- Base rules ------------------------------------------------------------------
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS only to the resolvers from /etc/resolv.conf
mapfile -t RESOLVERS < <(awk '/^nameserver/ && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf)
[ "${#RESOLVERS[@]}" -gt 0 ] || die "no IPv4 nameservers in /etc/resolv.conf"
for ns in "${RESOLVERS[@]}"; do
  iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
done
log "DNS allowed to: $(printf '%s ' "${RESOLVERS[@]}")"

# --- GitHub IP ranges ------------------------------------------------------------------
gh_meta="$(curl -fsS --connect-timeout 10 https://api.github.com/meta 2>/dev/null || true)"
if [ -n "$gh_meta" ] && echo "$gh_meta" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
  n=0
  while read -r cidr; do
    [[ "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || continue
    ipset add allowed-domains "$cidr" -exist; n=$((n+1))
  done < <(echo "$gh_meta" | jq -r '(.web + .api + .git)[]' | grep -v ':' | aggregate -q)
  log "GitHub: $n IPv4 ranges"
else
  warn "could not fetch the GitHub ranges - github.com may be unreachable"
fi

# --- Resolve domains (in parallel, through the glibc resolver like curl/cargo) ---------------
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
    warn "$domain does not resolve"
  fi
done

# --- Host access (optional) -------------------------------------------------------------
# NOT allowed by default: under pasta the gateway /24 would be the real LAN,
# and under slirp4netns 10.0.2.2 reaches the host's loopback services.
if [ "${DEVBOX_ALLOW_HOST:-0}" = "1" ]; then
  gw="$(ip -4 route show default | awk '{print $3; exit}')"
  [ -n "$gw" ] && { iptables -A OUTPUT -d "$gw" -j ACCEPT; log "host gateway $gw allowed (DEVBOX_ALLOW_HOST=1)"; }
fi

# --- Policy -------------------------------------------------------------------------------
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Block IPv6 entirely (the allowlist is IPv4-only, so AAAA would bypass it)
if command -v ip6tables >/dev/null && ip6tables -L -n >/dev/null 2>&1; then
  ip6tables -F; ip6tables -X 2>/dev/null || true
  ip6tables -A INPUT -i lo -j ACCEPT; ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -P INPUT DROP; ip6tables -P OUTPUT DROP; ip6tables -P FORWARD DROP
  log "IPv6 blocked"
elif ip -6 route show default 2>/dev/null | grep -q .; then
  die "IPv6 default route present but ip6tables unusable - the allowlist could be bypassed"
fi

# --- Verification -----------------------------------------------------------------------------
if curl -sS --connect-timeout 5 https://example.com >/dev/null 2>&1; then
  die "example.com is reachable - the firewall is not in effect"
fi
if curl -sS --connect-timeout 5 -o /dev/null https://api.anthropic.com 2>/dev/null; then
  log "OK: example.com blocked, api.anthropic.com reachable"
else
  warn "api.anthropic.com unreachable (network offline or DNS problem?)"
fi
