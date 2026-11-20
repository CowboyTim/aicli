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

# The device nodes that run.sh asks for, then ai.pl (the chat; options such as --agent), or the
# command given. usb-meter-nodes makes the USB meters' nodes.
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 usb-meter-nodes.sh /usr/local/bin/usb-meter-nodes
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# no arguments: ai.pl, the chat (the entrypoint)
CMD []

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

# --------------------------------------------------------------------------
# rocm: the ROCm image (ROCM_IMAGE, passed as BASE_IMAGE) with a Python venv for the agent
# user: torch, torchvision and torchaudio are the ROCm wheels that go with TheRock (AMD's ROCm
# build), from TheRock's nightly index for one GPU family (TORCH_INDEX; gfx1151 by default). The
# versions are one matching nightly set. The other packages are pinned. numpy stays 1.26.x,
# since pyarrow 17 does not work with NumPy 2.
FROM base AS rocm
ARG USERNAME=agent
ARG UID=1000
ARG GID=1000
ARG TORCH_INDEX=https://rocm.nightlies.amd.com/v2/gfx1151/
ARG TORCH_VERSION=2.9.1+rocm7.13.0a20260513
ARG TORCHVISION_VERSION=0.24.0+rocm7.13.0a20260513
ARG TORCHAUDIO_VERSION=2.9.0+rocm7.13.0a20260513
ARG NUMPY_VERSION=1.26.4
ARG PYARROW_VERSION=17.0.0
ARG SOUNDFILE_VERSION=0.14.0
ARG PILLOW_VERSION=13.0.0
ARG TRANSFORMERS_VERSION=5.5.1
# The downloads are large (the torch wheels alone are ~700 MB), so this is split into layers and
# uses a pip cache mount: a failed or timed-out download resumes from the wheels already fetched,
# and finished layers stay cached. Needs the BuildKit builder (the default for docker buildx bake).
RUN python3 -m venv "${HOME}/venv" \
 && "${HOME}/venv/bin/pip" --version
ENV PATH=${HOME}/venv/bin:${PATH} \
    PIP_RETRIES=10 \
    PIP_TIMEOUT=300
# torch, torchvision, torchaudio and numpy (torch's own deps come from the same index)
RUN --mount=type=cache,target=/var/cache/pip-rocm,uid=${UID},gid=${GID} \
    PIP_CACHE_DIR=/var/cache/pip-rocm \
 && pip install --extra-index-url "${TORCH_INDEX}" \
        "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" \
        "torchaudio==${TORCHAUDIO_VERSION}" "numpy==${NUMPY_VERSION}"
# the rest, from PyPI
RUN --mount=type=cache,target=/var/cache/pip-rocm,uid=${UID},gid=${GID} \
    PIP_CACHE_DIR=/var/cache/pip-rocm \
 && pip install "numpy==${NUMPY_VERSION}" "pyarrow==${PYARROW_VERSION}" \
        "soundfile==${SOUNDFILE_VERSION}" "pillow==${PILLOW_VERSION}" \
        "transformers==${TRANSFORMERS_VERSION}"
# check that the stack imports (no GPU is needed for that)
RUN python -c "import numpy, pyarrow, soundfile, PIL, transformers, torch, torchvision, torchaudio; print('torch', torch.__version__, 'hip', torch.version.hip, '| transformers', transformers.__version__, '| pyarrow', pyarrow.__version__)"

# --------------------------------------------------------------------------
# arduino: arduino-cli with the ESP32 core, usb_logger for the JT-UM120 and FNIRSI USB power
# meters (usb-multimeter from PyPI, via pipx; pyusb needs libusb), and nrfutil (Nordic), pinned by
# sha256: the device command flashes the nRF52840 dongle's sniffer firmware, and ble-sniffer reads
# its serial output. The devices come from run.sh (--arduino), not from the image.
FROM base AS arduino
ARG USERNAME=agent
ARG ARDUINO_CLI_VERSION=1.5.1
ARG ARDUINO_BOARD_URLS="https://espressif.github.io/arduino-esp32/package_esp32_index.json"
ARG ARDUINO_CORES="esp32:esp32"
ARG USB_METER_VERSION=3.0.0
ARG NRFUTIL_URL="https://files.nordicsemi.com/artifactory/swtools/external/nrfutil/executables/x86_64-unknown-linux-gnu/nrfutil-x86_64-unknown-linux-gnu-1.4.2-8a9090a"
ARG NRFUTIL_SHA256=a14996288928a92081cadeefd2dd37fcb54ee99a568fd4eaa6fb9586a51fba57
ARG NRFUTIL_DEVICE=device=2.17.5
ARG NRFUTIL_REFRESH=0

# arduino-cli from the official GitHub release
RUN mkdir -p "${HOME}/.local/bin" \
 && curl -fsSL "https://github.com/arduino/arduino-cli/releases/download/v${ARDUINO_CLI_VERSION}/arduino-cli_${ARDUINO_CLI_VERSION}_Linux_64bit.tar.gz" \
      | tar -xz -C "${HOME}/.local/bin" arduino-cli \
 && arduino-cli version

# board cores (ESP32 by default)
RUN arduino-cli config init \
 && arduino-cli config set board_manager.additional_urls ${ARDUINO_BOARD_URLS} \
 && arduino-cli core update-index \
 && arduino-cli core install ${ARDUINO_CORES} \
 && arduino-cli cache clean \
 && arduino-cli core list

# usb_logger (the rsfzi/JT-UM120-usb-power-data-logger project), into ~/.local/bin via pipx;
# pyusb talks to the meter through libusb, which needs its shared library
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends libusb-1.0-0 \
 && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}
RUN pipx install "usb-multimeter==${USB_METER_VERSION}" \
 && usb_logger --help >/dev/null

# nrfutil, installed for the agent user in ~/.local/bin (on PATH). Its launcher is pinned by
# sha256; it is then upgraded to the latest release, and ble-sniffer is installed at latest.
# Changing NRFUTIL_REFRESH ("run.sh --update") re-runs the upgrade and the ble-sniffer install.
RUN echo "nrfutil refresh: ${NRFUTIL_REFRESH}" \
 && mkdir -p "${HOME}/.local/bin" \
 && curl -fsSL -o "${HOME}/.local/bin/nrfutil" "${NRFUTIL_URL}" \
 && echo "${NRFUTIL_SHA256}  ${HOME}/.local/bin/nrfutil" | sha256sum -c - \
 && chmod 0755 "${HOME}/.local/bin/nrfutil" \
 && nrfutil self-upgrade \
 && nrfutil install "${NRFUTIL_DEVICE}" \
 && nrfutil install ble-sniffer --force \
 && nrfutil device --help >/dev/null \
 && nrfutil ble-sniffer --help >/dev/null

# --------------------------------------------------------------------------
# android: JDK 17 (what the current Android Gradle Plugin needs), the SDK command-line tools with
# one platform, build tools and platform-tools (adb), and Gradle. The SDK and Gradle live in the
# user's home, so sdkmanager can add platforms without root. Phones are not reachable over USB
# here (no device passthrough for them): use wireless debugging, adb pair and adb connect to the
# phone's IP:port.
FROM base AS android
ARG USERNAME=agent
ARG ANDROID_CMDLINE_TOOLS=15859902
ARG ANDROID_PLATFORM=android-35
ARG ANDROID_BUILD_TOOLS=35.0.0
ARG GRADLE_VERSION=8.14.6
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends openjdk-17-jdk-headless \
 && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    ANDROID_HOME=${HOME}/android-sdk \
    ANDROID_SDK_ROOT=${HOME}/android-sdk \
    GRADLE_HOME=${HOME}/gradle-${GRADLE_VERSION}
ENV PATH=${GRADLE_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}
RUN set -eux; \
    mkdir -p "${ANDROID_HOME}/cmdline-tools"; \
    curl -fsSL -o "${HOME}/cmdline-tools.zip" \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip"; \
    unzip -q "${HOME}/cmdline-tools.zip" -d "${ANDROID_HOME}/cmdline-tools"; \
    mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"; \
    rm "${HOME}/cmdline-tools.zip"
RUN yes | sdkmanager --licenses >/dev/null \
 && sdkmanager "platform-tools" "platforms;${ANDROID_PLATFORM}" "build-tools;${ANDROID_BUILD_TOOLS}" \
 && adb version
RUN curl -fsSL -o "${HOME}/gradle.zip" \
      "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
 && unzip -q "${HOME}/gradle.zip" -d "${HOME}" \
 && rm "${HOME}/gradle.zip" \
 && gradle --version
