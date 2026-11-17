#!/bin/bash
# Starts the aicli stack on its own IPv6 network. nginx gets the public IPv6 address of
# PUBLIC_DOMAIN (its AAAA record, looked up here) on the routed network dmz-aicli; the
# agent, the broker and certbot are not on it, so they have no public address.
#
#   PUBLIC_DOMAIN=ai.example.org CERTBOT_EMAIL=you@example.org \
#   AI_PROJECTS=/home/you/projects \
#   ./deploy.sh [docker compose up arguments, default: -d --build]
#   DO_CERTBOT=1 ./deploy.sh      also renews the certificate when it is due (every ~60 days)
#
# setup-env.sh writes .env and agent.env first (a setting given here is written, a setting
# already in the files stays, the secrets are made once). IPV6_SUBNET and IPV6_GATEWAY
# default to the prefix in setup-env.sh (IPV6_PREFIX overrides it).
set -eu
cd "$(dirname "$(readlink -f "$0")")"

# .env and agent.env from the environment and the files there (setup-env.sh)
./setup-env.sh .

# .env (read as compose reads it, not run as shell): a setting already in the environment
# wins, and a setting of .env is exported for this script. Only KEY=VALUE lines count.
if [ -f .env ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
            [A-Z_]*=*)
                key=${line%%=*}
                val=${line#*=}
                case "$val" in
                    \"*\") val=${val#\"}; val=${val%\"} ;;
                    \'*\') val=${val#\'}; val=${val%\'} ;;
                esac
                if [ -z "${!key+x}" ]; then export "$key=$val"; fi
                ;;
        esac
    done < .env
fi

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

# the certificate: certbot runs as its own container on the address of the domain and
# answers the HTTP challenge on port 80 itself. nginx has that address, so it is stopped
# while certbot runs. Only when DO_CERTBOT=1 (the first certificate, and renewals: with
# --keep-until-expiring a certificate is renewed only when it is due). Without a certificate
# nginx waits until one exists.
if [ "${DO_CERTBOT:-0}" = 1 ]; then
    echo "running certbot on $IPV6_ADDRESS (port 80 for the HTTP challenge)"
    docker compose stop nginx || echo "warning: nginx did not stop (it holds the address of the domain)" >&2
    docker run --rm --network "$NET" --ip6 "$IPV6_ADDRESS" \
        -v aicli-letsencrypt:/etc/letsencrypt \
        certbot/certbot:latest certonly --standalone --non-interactive --agree-tos \
        --keep-until-expiring -m "$CERTBOT_EMAIL" -d "$PUBLIC_DOMAIN" || exit $?
fi

echo "building and starting with docker compose"
if [ "$#" -eq 0 ]; then
    set -- up -d --build
fi
exec docker compose "$@"
