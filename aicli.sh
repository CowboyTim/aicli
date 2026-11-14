#!/bin/bash
#
# Run aicli in its docker image, in the current directory.
#
#   ./aicli.sh                 the dev image (local/ai/aicli)
#   ./aicli.sh --base          the small image (local/ai/aicli-base)
#   ./aicli.sh --dev           the dev image (the default)
#   ./aicli.sh --rocm          share the AMD GPU: /dev/kfd and /dev/dri, the ROCm files
#   ./aicli.sh --arduino       share the serial boards: ttyUSB* and ttyACM* (or --serial)
#   ./aicli.sh -c              anything else goes to ai.pl
#
# The flags come first, in any order. Only the flags above are taken; ai.pl's
# own options (-c, -p, ...) pass through.
#
# A device is passed only when it exists on this host, and the groups that own
# the passed devices are added to the container (--group-add), read from the
# device nodes with stat. Nothing is hardcoded to one host's group numbers.
#
# Chat does not need the GPU: the model server (llama.cpp, lemonade) runs on the
# host and the container reaches it over --network=host. --rocm is for a
# container that runs ROCm compute itself.
#
# Serial: the container makes the nodes ttyUSB0..7 and ttyACM0..7 itself when it
# starts (serial-nodes.sh, as claude-agent does), and ttyUSB (major 188) and ttyACM
# (major 166) get a device cgroup rule. A board plugged in later uses one of those
# nodes, with no restart. SERIAL_MAX changes how many.
#
# Environment overrides:
#   DOCKER_IMAGE   image to run                         (default: from the flags above)
#   DOCKER_RUN_OPTS extra "docker run" arguments, word-split
#   ROCM_PATH      the ROCm files on this host, for --rocm (default: $HOME/therock-dist-linux-gfx1151-latest)
#   SERIAL_MAX     serial nodes made per type for --arduino (default: 8)
#   AI_GROUPS      groups for ai.pl to drop to (default: the groups of the devices passed)
#   every AI_* variable of your shell is passed into the container

image=local/ai/aicli:latest
rocm=0
serial=0
while :; do
    case "${1:-}" in
        --base)            image=local/ai/aicli-base:latest ;;
        --dev)             image=local/ai/aicli:latest ;;
        --rocm)            rocm=1 ;;
        --arduino|--serial) serial=1 ;;
        *) break ;;
    esac
    shift
done
DOCKER_IMAGE=${DOCKER_IMAGE:-$image}

HERE=$(readlink -f "${PWD}")
BDIR=${HERE##*/}

extra_opts=

# share ssh keys (dangerous)
if [ ! -z "$SSH_AUTH_SOCK" ]; then
    b_sock=$(readlink -f "$SSH_AUTH_SOCK")
    b_dir=${b_sock##*/}
    c_ssh_auth_sock=/dev/shm/$b_dir
    extra_opts="-v $SSH_AUTH_SOCK:/dev/shm/$b_dir -e SSH_AUTH_SOCK=$c_ssh_auth_sock $extra_opts"
fi

# Share git info: read only
if [ -f ~/.gitconfig ]; then
    fn=$(readlink -f ~/.gitconfig)
    extra_opts="-v $fn:/workspace/.gitconfig:ro $extra_opts"
fi
if [ -f ~/.gitexcludes ]; then
    fn=$(readlink -f ~/.gitexcludes)
    extra_opts="$extra_opts -v $fn:/workspace/.gitexcludes:ro $extra_opts"
fi

# the microphone: only the PipeWire socket is shared (pw-record in the container)
HOST_RUNTIME=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
if [ -S "$HOST_RUNTIME/pipewire-0" ]; then
    extra_opts="-v $HOST_RUNTIME/pipewire-0:$HOST_RUNTIME/pipewire-0 -e XDG_RUNTIME_DIR=$HOST_RUNTIME $extra_opts"
else
    echo "aicli.sh: no PipeWire socket at $HOST_RUNTIME/pipewire-0, /voice cannot record (start PipeWire, or set XDG_RUNTIME_DIR)" >&2
fi

# every AI_* setting of this shell goes into the container
for v in $(compgen -e | grep '^AI_'); do
    extra_opts="-e $v $extra_opts"
done

# the defaults of the local setup (lemonade on this machine): only without a
# key, a local server or another provider of this shell, so that a cloud
# provider gets no local endpoint and no local model name
if [ -z "$AI_LOCAL_SERVER" ] && [ -z "$AI_API_KEY" ] && { [ -z "$AI_PROVIDER" ] || [ "$AI_PROVIDER" = lemonade ]; }; then
    extra_opts="-e AI_LOCAL_SERVER=http://[::1]:8000 -e AI_PROVIDER=lemonade -e AI_MODEL=${AI_MODEL:-NVIDIA-Nemotron-3-Super-120B-A12B-UD-Q4_K_XL-00001-of-00003} $extra_opts"
fi

# Devices: only the ones that exist here, and the groups that own them
declare -A gids=()
dev_opts=()
add_dev() {
    local dev=$1 gid
    [ -e "$dev" ] || return 0
    dev_opts+=(--device="$dev")
    gid=$(stat -c %g "$dev")
    [ "$gid" != 0 ] && gids[$gid]=1
    return 0
}

if [ "$rocm" = 1 ]; then
    add_dev /dev/kfd                              # ROCm compute
    for d in /dev/dri/card* /dev/dri/renderD*; do # GPU
        add_dev "$d"
    done
    dev_opts+=(
        --security-opt seccomp=unconfined
        --ipc=host
        --ulimit memlock=-1:-1
        --ulimit stack=67108864:67108864
    )
    ROCM_PATH=$(readlink -f "${ROCM_PATH:-$HOME/therock-dist-linux-gfx1151-latest}")
    if [ -d "$ROCM_PATH" ]; then
        dev_opts+=(-v "$ROCM_PATH:/opt/rocm:ro" -e ROCM_PATH=/opt/rocm)
    else
        echo "aicli.sh: no ROCm files at $ROCM_PATH (set ROCM_PATH)" >&2
    fi
fi

if [ "$serial" = 1 ]; then
    # the boards: the container makes the nodes itself (serial-nodes.sh), so a board
    # plugged in after start works; it needs the dialout group of this host
    serial_gid=$(getent group dialout | cut -d: -f3)
    [ -n "$serial_gid" ] && gids[$serial_gid]=1
    dev_opts+=(
        --device-cgroup-rule "c 188:* rmw"
        --device-cgroup-rule "c 166:* rmw"
        --entrypoint /usr/local/bin/aicli-serial
        -e "SERIAL_GID=${serial_gid:-0}"
        -e "SERIAL_MAX=${SERIAL_MAX:-8}"
    )
fi

group_opts=()
for g in "${!gids[@]}"; do
    group_opts+=(--group-add "$g")
done
if [ -z "${AI_GROUPS+x}" ] && [ ${#gids[@]} -gt 0 ]; then
    extra_opts="-e AI_GROUPS=${!gids[*]} $extra_opts"
fi

exec docker run --rm -it \
    $extra_opts \
    $DOCKER_RUN_OPTS \
    "${dev_opts[@]}" \
    "${group_opts[@]}" \
    -e TERM \
    -e ALL_PROXY \
    -e HTTP_PROXY \
    -e HTTPS_PROXY \
    -e TMPDIR=/tmp \
    -e UID=${EUID} \
    -e GID=$(id -g) \
    -e LOGNAME \
    -e BDIR="${BDIR}" \
    -e CDIR="/workdir/${BDIR}" \
    -e GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no" \
    -e AI_DIR=/workspace/.aicli \
    -e AI_SESSION \
    -e AI_CLEAR \
    -e AI_PROMPT_TEMPLATE=${AI_PROMPT_TEMPLATE:-coder} \
    -e DEBUG \
    -e GIT_AUTHOR_NAME \
    -e GIT_AUTHOR_EMAIL \
    -e GIT_COMMITTER_NAME \
    -e GIT_COMMITTER_EMAIL \
    -e GIT_EDITOR="true" \
    -e HOME=/workspace \
    --cap-add=SYS_PTRACE \
    --tmpfs /tmp:rw,suid,exec,size=2G \
    --tmpfs /var/tmp:rw,suid,exec,size=1G \
    --network=host \
    --name aicli-${LOGNAME}-${BDIR} \
    -v aicli-${LOGNAME}:/workspace \
    -v "${PWD}":/workdir/${BDIR} \
        "$DOCKER_IMAGE" \
            "$@"
