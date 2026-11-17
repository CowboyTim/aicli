#!/bin/bash
# Writes .env and agent.env for the stack (what ~/aicli.sh did), from the environment and
# from the files already there:
#   - a setting given in the environment is written;
#   - a setting already in the file stays as it is;
#   - a secret that is missing is made (and an existing one is kept: the tokens of
#     other tools must not change between runs);
#   - the ids of the user and the socket path are always the current ones;
#   - IPV6_ADDRESS is not kept (deploy.sh looks up the AAAA record on every run).
# Usage: setup-env.sh [directory of the compose file]
set -eu
umask 077
dir=${1:-.}
env_f=$dir/.env
agent_f=$dir/agent.env
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
        echo "setup-env: $1 is needed (in the environment, or in $env_f)" >&2
        exit 1
    fi
    printf '%s' "$v"
}

# the IPv6 prefix of the containers (the /120 and its gateway), as the network needs them
ipv6_prefix=${IPV6_PREFIX:-2a02:a03f:8789:e700:c::8}

v=$(need PUBLIC_DOMAIN)
set_key "$env_f" PUBLIC_DOMAIN "$v"
v=$(need CERTBOT_EMAIL)
set_key "$env_f" CERTBOT_EMAIL "$v"
v=$(need AI_PROJECTS)
set_key "$env_f" AI_PROJECTS "$v"
set_key "$env_f" IPV6_SUBNET "$(pick "$env_f" IPV6_SUBNET "$ipv6_prefix:0/120")"
set_key "$env_f" IPV6_GATEWAY "$(pick "$env_f" IPV6_GATEWAY "$ipv6_prefix:1")"
set_key "$env_f" PODMAN_SOCKET "/run/user/$(id -u)/podman/podman.sock"
set_key "$env_f" BROKER_UID "$(id -u)"
set_key "$env_f" BROKER_GID "$(id -g)"

for k in SEARXNG_SECRET SEARXNG_API_TOKEN; do
    v=$(get "$env_f" "$k")
    [ -n "$v" ] || v=$(openssl rand -hex 32)
    set_key "$env_f" "$k" "$v"
done

sed -i '/^IPV6_ADDRESS=/d' "$env_f"

set_key "$agent_f" AI_LOCAL_SERVER "$(pick "$agent_f" AI_LOCAL_SERVER "http://[2a02:a03f:8789:e700::20]:8000/rocm/v1")"
set_key "$agent_f" AI_ASR_URL "$(pick "$agent_f" AI_ASR_URL "http://[2a02:a03f:8789:e700::20]:52625/v1/audio/transcriptions")"
set_key "$agent_f" AI_MODEL "$(pick "$agent_f" AI_MODEL "Qwen3.8-Flash-Next-Q4_0_ROCMFP4_FAST-PLE_Q8_0")"
