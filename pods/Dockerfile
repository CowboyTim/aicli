# The images of this directory (pods/): the base image, a slim Debian with only what ai.pl needs
# to run (perl and its modules, bash, grep, find, sudo for the device nodes, CA certificates) and
# ai.pl with its modules, fetched from this project's repository on GitHub at the commit AICLI_REF.
# The device images add their own programs and their devices' side (see README.md); they are
# built on the base image, except rocm, which is built on the ROCm image: the same ai.pl layer
# goes on that image too (it has perl and bash, the layer adds what ai.pl loads).
#
# The layers, bottom up:
#   fetch   the repository's files of AICLI_REF (curl is only here, not in the images)
#   aicli   ROOT_IMAGE + the runtime packages of ai.pl + the user + ai.pl + the entrypoint
#   base    aicli: the image of the bash target too
#   arduino, android, rocm   aicli + their programs
#
# docker-bake.hcl sets the build arguments: ROOT_IMAGE is the image the aicli layer is put on.

ARG ROOT_IMAGE=debian:trixie-slim
ARG FETCH_IMAGE=debian:trixie-slim

# --------------------------------------------------------------------------
# fetch: ai.pl and the modules it loads, from the repository archive of one commit (pinned, so the
# same ai.pl in every build until AICLI_REF is changed). Its layout is the one of the main image:
# the modules at /, the templates and the web page under /ai. Copied into the images as /.
FROM ${FETCH_IMAGE} AS fetch
ARG AICLI_REPO=https://github.com/CowboyTim/aicli
ARG AICLI_REF=08e5f7e7eb03454c90bbfc3cc8307a59cf54e6ce
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    tmp=$(mktemp -d); \
    curl -fsSL "${AICLI_REPO}/archive/${AICLI_REF}.tar.gz" -o "$tmp/src.tar.gz"; \
    mkdir "$tmp/src"; \
    tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components=1; \
    mkdir -p /out; \
    install -m 0755 "$tmp/src/ai.pl" /out/ai.pl; \
    install -m 0644 "$tmp/src/ai.pm" "$tmp/src/md.pm" "$tmp/src/remote_agent.pm" \
        "$tmp/src/remote_hub.pm" "$tmp/src/tui.pm" "$tmp/src/utils.pm" "$tmp/src/ui.pm" \
        "$tmp/src/worker.pm" /out/; \
    cp -r "$tmp/src/ai" /out/ai; \
    rm -rf "$tmp"

# --------------------------------------------------------------------------
# aicli: the runtime of ai.pl on ROOT_IMAGE. Packages: perl with the modules ai.pl loads (JSON::XS,
# the curl binding WWW::Curl, Term::ReadLine::Gnu for the chat's input), bash, grep and find (the
# tools of a session), ca-certificates (HTTPS to the providers and the broker), and sudo, which the
# entrypoint uses to make the serial device nodes that run.sh asks for. No compiler, no
# documentation, no caches: the device images add what they need.
FROM ${ROOT_IMAGE} AS aicli
ARG USERNAME=agent
ARG UID=1000
ARG GID=1000
ENV DEBIAN_FRONTEND=noninteractive
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates perl libjson-xs-perl libwww-curl-perl libterm-readline-gnu-perl \
        bash grep findutils sudo \
 && rm -rf /var/lib/apt/lists/*

# Non-root user with the requested UID/GID (docker-bake.hcl passes the host's, so files written
# into a mounted workspace are the host user's). The ROCm image has an "ubuntu" user at uid 1000,
# which would clash with most host users: it is removed first (a no-op on Debian).
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

# ai.pl and its files (from fetch), the device nodes of the entrypoint
COPY --from=fetch /out/ /
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 usb-meter-nodes.sh /usr/local/bin/usb-meter-nodes
RUN perl -cw /ai.pl

USER ${USERNAME}
ENV HOME=/home/${USERNAME} \
    PATH=/home/${USERNAME}/.local/bin:${PATH}
WORKDIR /home/${USERNAME}
RUN mkdir -p "${HOME}/work"

# the device nodes that run.sh asks for, then ai.pl (the chat; options such as --agent), or the
# command given. usb-meter-nodes makes the USB meters' nodes.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# no arguments: ai.pl, the chat (the entrypoint)
CMD []

# --------------------------------------------------------------------------
# base: the aicli layer on the slim Debian image; the bash target of docker-bake.hcl is this too
FROM aicli AS base

# --------------------------------------------------------------------------
# rocm: the aicli layer on the ROCm image (ROOT_IMAGE, see docker-bake.hcl) with a Python venv for the
# agent user: torch, torchvision and torchaudio are the ROCm wheels that go with TheRock (AMD's ROCm
# build), from TheRock's nightly index for one GPU family (TORCH_INDEX; gfx1151 by default). The
# versions are one matching nightly set. The other packages are pinned. numpy stays 1.26.x,
# since pyarrow 17 does not work with NumPy 2.
FROM aicli AS rocm
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
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv python3-pip \
 && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}
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
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl python3 python3-venv pipx libusb-1.0-0 \
 && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}

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
# android: JDK 21 (trixie's; the current Android Gradle Plugin and Gradle 8.14 run on it), the SDK command-line tools with
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
 && apt-get install -y --no-install-recommends curl unzip openjdk-21-jdk-headless \
 && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
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
