#!/bin/bash

DOCKER_IMAGE=${DOCKER_IMAGE:-local/ai/aicli:latest}
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

ROCM_PATH=${ROCM_PATH:-~/therock-dist-linux-gfx1151-latest}
ROCM_PATH=$(readlink -f "$ROCM_PATH")
exec docker run --rm -it \
    $extra_opts \
    $DOCKER_RUN_OPTS \
    -e TERM \
    -e ALL_PROXX \
    -e HTTP_PROXY \
    -e HTTPS_PROX \
    -e TMPDIR=/tmp \
    -e UID=${EUID} \
    -e LOGNAME \
    -e BDIR="${BDIR}" \
    -e CDIR="/workdir/${BDIR}" \
    -e GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no" \
    -e AI_LOCAL_SERVER=${AI_LOCAL_SERVER:-http://[::1]:8000} \
    -e AI_MODEL=${AI_MODEL:-NVIDIA-Nemotron-3-Super-120B-A12B-UD-Q4_K_XL-00001-of-00003} \
    -e AI_PROVIDER=${AI_PROVIDER:-lemonade} \
    -e AI_DIR=/workspace/.aicli \
    -e AI_SESSION \
    -e AI_CLEAR \
    -e AI_STREAM=${AI_STREAM:-0} \
    -e DEBUG \
    -e GIT_AUTHOR_NAME \
    -e GIT_AUTHOR_EMAIL \
    -e GIT_COMITTER_NAME \
    -e GIT_COMITTER_EMAIL \
    -e GIT_EDITOR="true" \
    -e ROCM_PATH=/opt/rocm \
    -v $ROCM_PATH:/opt/rocm:ro \
    --ulimit memlock=-1:-1 \
    --ulimit stack=67108864:67108864 \
    --group-add=video \
    --ipc=host \
    --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --group-add 986 \
    --group-add 109 \
    --group-add 992 \
    --tmpfs /tmp:rw,suid,exec,size=2G \
    --tmpfs /var/tmp:rw,suid,exec,size=1G \
    --device /dev/kfd \
    --device /dev/dri \
    --network=host \
    --name aicli-${LOGNAME}-${BDIR} \
    -v aicli-${LOGNAME}:/workspace \
    -v "${PWD}":/workdir/${BDIR} \
        "$DOCKER_IMAGE" \
            $*
