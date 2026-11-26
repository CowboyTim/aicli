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
# First it writes .env and .agent.env (below). A setting given in the environment is written,
# a setting already in the files stays, and the secrets are made once and kept (the tokens of
# other tools must not change between runs). AICLI_ENV_ONLY=1 stops after the files.
set -eu
cd "$(dirname "$(readlink -f "$0")")"

# --- .env and .agent.env -----------------------------------------------------------------
umask 077
env_f=.env
agent_f=.agent.env
# an agent.env of earlier versions moves to .agent.env (its settings stay)
if [ -f agent.env ] && [ ! -e "$agent_f" ]; then
    mv agent.env "$agent_f"
    echo "moved agent.env to $agent_f"
fi
touch "$env_f" "$agent_f"

# the value of KEY in FILE, or nothing
get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

# KEY=VALUE in FILE: the line is replaced, or added
set_key() {
    local f=$1 k=$2 v=$3
    if grep -q "^$k=" "$f"; then
        local tmp
        tmp=$(mktemp "$f.XXXXXX")
        sed "s|^$k=.*|$k=$v|" "$f" > "$tmp"
        cat "$tmp" > "$f"
        rm -f "$tmp"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

# KEY is removed from FILE
del_key() {
    local f=$1 k=$2
    [ -f "$f" ] || return 0
    local tmp
    tmp=$(mktemp "$f.XXXXXX")
    sed "/^$k=/d" "$f" > "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
}

# the value of KEY: the environment, else FILE, else DEFAULT
pick() {
    local f=$1 k=$2 d=${3-} v
    v=${!k-}
    [ -n "$v" ] || v=$(get "$f" "$k")
    [ -n "$v" ] || v=$d
    printf '%s' "$v"
}

# the value of KEY, which must be there
need() {
    local v
    v=$(pick "$env_f" "$1")
    if [ -z "$v" ]; then
        echo "deploy.sh: $1 is needed (in the environment, or in $env_f)" >&2
        exit 1
    fi
    printf '%s' "$v"
}

v=$(need PUBLIC_DOMAIN)
set_key "$env_f" PUBLIC_DOMAIN "$v"
v=$(need CERTBOT_EMAIL)
set_key "$env_f" CERTBOT_EMAIL "$v"
v=$(need AI_PROJECTS)
set_key "$env_f" AI_PROJECTS "$v"
# the IPv6 prefix of the containers (the /120 and its gateway): from the environment or .env
# (kept from the first run on)
v=$(need IPV6_PREFIX)
set_key "$env_f" IPV6_PREFIX "$v"
ipv6_prefix=$v
set_key "$env_f" IPV6_SUBNET "$(pick "$env_f" IPV6_SUBNET "$ipv6_prefix:0/120")"
set_key "$env_f" IPV6_GATEWAY "$(pick "$env_f" IPV6_GATEWAY "$ipv6_prefix:1")"
set_key "$env_f" BROKER_UID "$(id -u)"
set_key "$env_f" BROKER_GID "$(id -g)"

for k in SEARXNG_SECRET SEARXNG_API_TOKEN AICLI_GATE_SECRET; do
    v=$(get "$env_f" "$k")
    [ -n "$v" ] || v=$(openssl rand -hex 32)
    set_key "$env_f" "$k" "$v"
done

# the chat model server: explicit (the environment or .agent.env; required)
v=$(pick "$agent_f" AI_LOCAL_SERVER)
if [ -z "$v" ]; then
    echo "deploy.sh: AI_LOCAL_SERVER is needed (its URL, in the environment or in $agent_f)" >&2
    exit 1
fi
set_key "$agent_f" AI_LOCAL_SERVER "$v"
# the speech recognizer: the flm service of docker-compose.yaml, unless AI_ASR_URL is set. Compose
# reads it from the shell or .env, so a URL that .agent.env has moves to .env. AI_ASR_URL= (set and
# empty) clears it: the lines are removed, and the flm service is the recognizer again.
if [ "${AI_ASR_URL+x}" = x ] && [ -z "$AI_ASR_URL" ]; then
    del_key "$env_f" AI_ASR_URL
    del_key "$agent_f" AI_ASR_URL
else
    v=$(pick "$agent_f" AI_ASR_URL)
    [ -n "$v" ] && set_key "$env_f" AI_ASR_URL "$v"
fi
# the image service of the generate_image tool (AI_IMAGE_URL, its base address). As the recognizer above: compose
# reads it from the shell or .env, so a URL that .agent.env has moves to .env. AI_IMAGE_URL= (set and empty) clears it:
# no image tool.
if [ "${AI_IMAGE_URL+x}" = x ] && [ -z "$AI_IMAGE_URL" ]; then
    del_key "$env_f" AI_IMAGE_URL
    del_key "$agent_f" AI_IMAGE_URL
else
    v=$(pick "$agent_f" AI_IMAGE_URL)
    [ -n "$v" ] && set_key "$env_f" AI_IMAGE_URL "$v"
fi
# the speech service of the speech tool (AI_SPEECH_URL, its base address). As the recognizer above: compose
# reads it from the shell or .env, so a URL that .agent.env has moves to .env. AI_SPEECH_URL= (set and empty) clears it:
# no speech tool.
if [ "${AI_SPEECH_URL+x}" = x ] && [ -z "$AI_SPEECH_URL" ]; then
    del_key "$env_f" AI_SPEECH_URL
    del_key "$agent_f" AI_SPEECH_URL
else
    v=$(pick "$agent_f" AI_SPEECH_URL)
    [ -n "$v" ] && set_key "$env_f" AI_SPEECH_URL "$v"
fi
# the audio service of the generate_audio tool (AI_AUDIO_URL, its base address). As the speech service above: compose
# reads it from the shell or .env, so a URL that .agent.env has moves to .env. AI_AUDIO_URL= (set and empty) clears it:
# no generate_audio tool.
if [ "${AI_AUDIO_URL+x}" = x ] && [ -z "$AI_AUDIO_URL" ]; then
    del_key "$env_f" AI_AUDIO_URL
    del_key "$agent_f" AI_AUDIO_URL
else
    v=$(pick "$agent_f" AI_AUDIO_URL)
    [ -n "$v" ] && set_key "$env_f" AI_AUDIO_URL "$v"
fi
# the 3D service of the generate_3d tool (AI_3D_URL, its base address). As the audio service above: compose reads it
# from the shell or .env, so a URL that .agent.env has moves to .env. AI_3D_URL= (set and empty) clears it: no
# generate_3d tool.
if [ "${AI_3D_URL+x}" = x ] && [ -z "$AI_3D_URL" ]; then
    del_key "$env_f" AI_3D_URL
    del_key "$agent_f" AI_3D_URL
else
    v=$(pick "$agent_f" AI_3D_URL)
    [ -n "$v" ] && set_key "$env_f" AI_3D_URL "$v"
fi
set_key "$agent_f" AI_MODEL "$(pick "$agent_f" AI_MODEL "Qwen3.5-4B-ROCMFP4")"

if [ "${AICLI_ENV_ONLY:-0}" = 1 ]; then
    exit 0
fi

# --- the settings of .env, for this script --------------------------------------------------
# read as compose reads it, not run as shell: a setting already in the environment wins.
# Only KEY=VALUE lines count.
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
done < "$env_f"

: "${PUBLIC_DOMAIN:?Need PUBLIC_DOMAIN (the public name, its AAAA record is looked up)}"
: "${IPV6_SUBNET:?Need IPV6_SUBNET (the routed prefix for the containers, e.g. 2001:db8:c::1:0/120)}"
: "${IPV6_GATEWAY:?Need IPV6_GATEWAY (the gateway of that prefix, e.g. 2001:db8:c::1:1)}"

NET=dmz-aicli

IPV6=$(dig AAAA +short "$PUBLIC_DOMAIN" | head -n 1 || true)
if [ -z "$IPV6" ]; then
    echo "no AAAA record for $PUBLIC_DOMAIN: add it (the address of this host's IPv6 in $IPV6_SUBNET)" >&2
    exit 1
fi
# the address is the AAAA record, on every run (compose reads it from .env)
export IPV6_ADDRESS=$IPV6
set_key "$env_f" IPV6_ADDRESS "$IPV6_ADDRESS"
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
# answers the HTTP challenge on port 80 itself. nginx has that address, so the stack is
# brought down while certbot runs. Only when DO_CERTBOT=1 (the first certificate, and
# renewals). Without a certificate nginx waits until one exists.
if [ "${DO_CERTBOT:-0}" = 1 ]; then
    echo "shutting down"
    docker compose down
    echo "running certbot on $IPV6_ADDRESS (port 80 for the HTTP challenge)"
    docker run \
        -p 80:80 \
        -e CERTBOT_MAIL="$CERTBOT_EMAIL" \
        --rm \
        --network "$NET" \
        --ip6 "$IPV6_ADDRESS" \
        -v aicli-letsencrypt:/certs:rw \
        local/certbot/certbot:${APP_CERTBOT_TAG:-latest} \
            certonly \
                --agree-tos \
                --force-renewal \
                --domains "$PUBLIC_DOMAIN" || exit $?
fi

echo "building and starting with docker compose"
if [ "$#" -eq 0 ]; then
    set -- up -d --build
fi
exec docker compose "$@"
