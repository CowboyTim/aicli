#!/bin/bash
#
# Run aicli in its docker image, in the current directory.
#
#   ./aicli.sh                 the dev image (local/ai/aicli)
#   ./aicli.sh --base          the small image (local/ai/aicli-base)
#   ./aicli.sh --dev           the dev image (the default)
#   ./aicli.sh -c              anything else goes to ai.pl
#   ./aicli.sh --ui [PORT]     the web interface (ai.pl --ui); the container shares the host network,
#                              so it is at http://127.0.0.1:PORT (8080) on the host, token on stderr
#   ./aicli.sh --broker        the broker's socket (volume aicli-broker, see docker-compose.yaml): the web
#                              interface's agents page (enrollment, the list, revocation) talks to the broker
#                              through it. The tools run in this container, not in the broker
#   ./aicli.sh --root DIR      DIR is mounted as a whole, the projects are the directories of its accounts (DIR/<account>/<project>), and
#                              the container starts in the current directory (which must be in DIR):
#                              one container for all projects, one web interface (ai.pl --ui from DIR)
#
# The flags come first, in any order. Only the flags above are taken; ai.pl's
# own options (-c, -p, ...) pass through.
#
# Hardware is not in this image: the boards, GPUs, radios and meters are the
# device images, each one a remote agent (see PLAN.md, "a thin ai.pl image"). The
# model server (llama.cpp, lemonade) runs on the host and the container reaches it
# over --network=host.
#
# Environment overrides:
#   DOCKER_IMAGE    image to run                        (default: from the flags above)
#   DOCKER_RUN_OPTS extra "docker run" arguments, word-split
#   every AI_* variable of your shell is passed into the container

image=local/ai/aicli:latest
broker=0
root=
while :; do
    case "${1:-}" in
        --base)             image=local/ai/aicli-base:latest ;;
        --dev)              image=local/ai/aicli:latest ;;
        --broker)           broker=1 ;;
        --root)             root=${2:?"aicli.sh: --root needs a directory"}; shift ;;
        --root=*)           root=${1#--root=} ;;
        *) break ;;
    esac
    shift
done
DOCKER_IMAGE=${DOCKER_IMAGE:-$image}

HERE=$(readlink -f "${PWD}")
# the directory mounted, its name, and where the container starts
MOUNT=$HERE
MNAME=${HERE##*/}
WDIR=/workdir/$MNAME
cname_kind=
if [ -n "$root" ]; then
    ROOT_ABS=$(readlink -f "$root")
    case "$HERE" in
        "$ROOT_ABS"|"$ROOT_ABS"/*) ;;
        *) echo "aicli.sh: the current directory is not inside the root $ROOT_ABS" >&2; exit 2 ;;
    esac
    MOUNT=$ROOT_ABS
    MNAME=${ROOT_ABS##*/}
    WDIR=/workdir/$MNAME${HERE#"$ROOT_ABS"}
    cname_kind=root-
fi
BDIR=$MNAME
cname=aicli-${LOGNAME}-${cname_kind}${BDIR}

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

# the broker's socket: only with --broker (the volume is created by compose)
if [ "$broker" = 1 ]; then
    extra_opts="-v aicli-broker:/run/aicli-broker $extra_opts"
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

exec docker run --rm -it \
    $extra_opts \
    $DOCKER_RUN_OPTS \
    -e TERM \
    -e ALL_PROXY \
    -e HTTP_PROXY \
    -e HTTPS_PROXY \
    -e TMPDIR=/tmp \
    -e UID=${EUID} \
    -e GID=$(id -g) \
    -e LOGNAME \
    -e BDIR="${BDIR}" \
    -e CDIR="${WDIR}" \
    -e GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no" \
    -e AI_DIR=/workspace/.aicli \
    -e AI_SESSION \
    -e AI_UI_TOKEN \
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
    --name "$cname" \
    -v aicli-${LOGNAME}:/workspace \
    -v "${MOUNT}":/workdir/${MNAME} \
    -w "${WDIR}" \
        "$DOCKER_IMAGE" \
            "$@"
