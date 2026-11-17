#!/bin/bash
# Starts the aicli stack on its own IPv6 network. nginx gets the public IPv6 address of
# PUBLIC_DOMAIN (its AAAA record, looked up here) on the routed network dmz-aicli; the
# agent, the broker and certbot are not on it, so they have no public address.
#
#   PUBLIC_DOMAIN=ai.example.org \
#   IPV6_SUBNET=2001:db8:c::1:0/120 \
#   IPV6_GATEWAY=2001:db8:c::1:1 \
#   ./deploy.sh [docker compose up arguments, default: -d --build]
#
# The other settings are in .env (compose reads it), and the agent's in agent.env.
set -eu
cd "$(dirname "$(readlink -f "$0")")"

: "${PUBLIC_DOMAIN:?Need PUBLIC_DOMAIN (the public name, its AAAA record is looked up)}"
: "${IPV6_SUBNET:?Need IPV6_SUBNET (the routed prefix for the containers, e.g. 2001:db8:c::1:0/120)}"
: "${IPV6_GATEWAY:?Need IPV6_GATEWAY (the gateway of that prefix, e.g. 2001:db8:c::1:1)}"

NET=dmz-aicli

IPV6=$(dig AAAA +short "$PUBLIC_DOMAIN" | head -n 1 || true)
if [ -z "$IPV6" ]; then
    echo "no AAAA record for $PUBLIC_DOMAIN: add it (the address of this host's IPv6 in $IPV6_SUBNET)" >&2
    exit 1
fi
export IPV6_ADDRESS=${IPV6_ADDRESS:-$IPV6}
echo "$PUBLIC_DOMAIN is $IPV6_ADDRESS"

if ! docker network inspect "$NET" >/dev/null 2>&1; then
    echo "creating the network $NET ($IPV6_SUBNET, routed)"
    docker network create \
        --driver bridge \
        --ipv6 \
        --ipam-driver default \
        --subnet "$IPV6_SUBNET" \
        --gateway "$IPV6_GATEWAY" \
        --opt com.docker.network.bridge.gateway_mode_ipv6=routed \
        --opt com.docker.network.container_iface_prefix=dmz \
        --opt com.docker.network.bridge.enable_icc=true \
        --opt com.docker.network.bridge.enable_ip_masquerade=false \
        --opt com.docker.network.bridge.enable_ip6_masquerade=false \
        --opt com.docker.network.bridge.inhibit_ipv4=true \
        --opt com.docker.network.driver.mtu=1500 \
        "$NET" >/dev/null
fi

echo "building and starting with docker compose"
if [ "$#" -eq 0 ]; then
    set -- up -d --build
fi
exec docker compose "$@"
