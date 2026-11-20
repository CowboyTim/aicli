# The base image of the device images (arduino, rocm, android, usb-meter, rtl-sdr, nrf): the
# basic tools of a session (bash, perl, grep, find), the toolchains (Rust, nodejs, npm, go), and
# ai.pl with its modules, fetched from this project's repository on GitHub at the commit AICLI_REF.
# Each device image is built FROM this one and adds its own device programs and the run of
# `ai.pl --agent` (see README.md). The image holds no device: devices are passed in at run time.
#
# docker-bake.hcl sets the build arguments; "docker buildx bake" builds base.

ARG BASE_IMAGE=ubuntu:24.04

# --------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS common

USER root
ENV DEBIAN_FRONTEND=noninteractive

# The Ubuntu base image drops man pages and docs (dpkg excludes); remove that so
# man, perldoc and the packages below keep their documentation.
RUN rm -f /etc/dpkg/dpkg.cfg.d/excludes \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl git sudo less jq python3 python3-serial \
        openssh-client \
        build-essential cmake ninja-build clang perl \
        lua5.4 luajit python-is-python3 \
        python3-dev python3-pip python3-venv \
        librsvg2-bin python3-cairosvg fonts-dejavu-core fontconfig \
        ripgrep fd-find file tree zip unzip xz-utils rsync wget patch \
        diffutils procps htop strace lsof git-lfs \
        gdb valgrind clang-format clang-tidy lld ccache pkg-config \
        autoconf automake libtool libtool-bin bear \
        libssl-dev zlib1g-dev libffi-dev libsqlite3-dev sqlite3 \
        liblua5.4-dev luarocks pipx shellcheck shfmt \
        iproute2 iputils-ping dnsutils netcat-openbsd socat \
        cpanminus perl-doc libperl-dev perltidy \
        libdbi-perl libdbd-sqlite3-perl libtext-csv-perl libyaml-libyaml-perl \
        libmoose-perl libreadonly-perl \
        time ltrace man-db manpages tmux vim-tiny gawk psmisc moreutils bc ncdu \
        entr direnv \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*

# Declared after apt so a different UID/GID doesn't invalidate the apt layer.
# docker-bake.hcl passes your host UID/GID (AGENT_UID, AGENT_GID) so files written into
# mounted workspaces end up owned by you, not by root or a random uid.
ARG USERNAME=agent
ARG UID=1000
ARG GID=1000

# Non-root user with the requested UID/GID. Ubuntu 24.04 images ship an
# "ubuntu" user at uid 1000, which would clash with most host users.
RUN set -eux; \
    if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu || userdel ubuntu; fi; \
    if getent group ubuntu >/dev/null; then groupdel ubuntu || true; fi; \
    if ! getent group "${GID}" >/dev/null; then groupadd -g "${GID}" "${USERNAME}"; fi; \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash "${USERNAME}"; \
    for g in video render dialout plugdev; do \
        if getent group "$g" >/dev/null; then usermod -aG "$g" "${USERNAME}"; fi; \
    done; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

ENV HOME=/home/${USERNAME} \
    PATH=/home/${USERNAME}/.local/bin:${PATH}

# The working directory of the user, owned by the user
RUN mkdir -p "${HOME}/work"

# No arguments -> bash. Arguments are the command to run (e.g. bash -c "...").
CMD ["bash"]

# --------------------------------------------------------------------------
FROM common AS base

# General-purpose: python, perl, lua/luajit, C/C++ (gcc, clang, cmake, ninja)
# come from common.
# Node.js (+ npm) and Go from Ubuntu's apt. ARGs don't carry across stages,
# hence USERNAME again (same default as in base).
ARG USERNAME=agent
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends nodejs npm golang-go \
        rtl-sdr \
        libjson-xs-perl libwww-curl-perl libterm-readline-gnu-perl libdata-uuid-perl \
 && rm -rf /var/lib/apt/lists/*
# ai.pl and the modules it loads, from this project's repository on GitHub. The commit is
# pinned (AICLI_REF): the same ai.pl in every build until it is changed here. Its layout is the
# one of the ai.pl image: the modules at /, the templates and the web page under /ai.
ARG AICLI_REPO=https://github.com/CowboyTim/aicli
ARG AICLI_REF=0b70b5eaaec61cb55782df5d9f335ff46686ff2f
RUN set -eux; \
    tmp=$(mktemp -d); \
    curl -fsSL "${AICLI_REPO}/archive/${AICLI_REF}.tar.gz" -o "$tmp/src.tar.gz"; \
    mkdir "$tmp/src"; \
    tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components=1; \
    install -m 0644 "$tmp/src/ai.pl" "$tmp/src/ai.pm" "$tmp/src/md.pm" "$tmp/src/remote_agent.pm" \
        "$tmp/src/remote_hub.pm" "$tmp/src/tui.pm" "$tmp/src/utils.pm" "$tmp/src/ui.pm" "$tmp/src/worker.pm" /; \
    chmod 0755 /ai.pl; \
    cp -r "$tmp/src/ai" /ai; \
    perl -cw /ai.pl; \
    rm -rf "$tmp"

USER ${USERNAME}

# Rust (rustc, cargo, clippy, rustfmt) via rustup, for the user, stable channel.
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile default --default-toolchain stable \
 && "${HOME}/.cargo/bin/cargo" --version
ENV PATH=${HOME}/.cargo/bin:${PATH}

WORKDIR ${HOME}/work
