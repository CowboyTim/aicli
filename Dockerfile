# Two stages share one "base" stage:
#
#   base   small: ai.pl and the basic unix tools (bash, git, curl, text tools).
#   dev    base + the development languages (python, lua, C/C++ with make, cmake and
#          pkg-config), ImageMagick, the perl tool's PDL and Audio::Wav, lame, and
#          the list of their modules for the devel tool, made at build time.
#
# The default target (the last stage) is dev, which is what aicli.sh runs.
# docker build --target base gives the small image.
#
# Ubuntu, not Debian: the specific stages that come later (ROCm, arduino-cli) start
# from Ubuntu images, so the layers share one distribution.

ARG BASE_IMAGE=ubuntu:24.04

# --------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS base
ENV DEBIAN_FRONTEND=noninteractive

# ai.pl dependencies: Perl, the JSON and readline modules, WWW::Curl for the HTTP
# requests, and the CA certificates for the HTTPS APIs
RUN apt-get update && apt-get install -y --no-install-recommends \
        perl libjson-xs-perl libwww-curl-perl libterm-readline-gnu-perl libdata-uuid-perl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# the unix tools the model uses: a shell, the text tools, git, and the network tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ripgrep grep findutils coreutils diffutils patch \
        git openssh-client openssl \
        curl wget socat \
    && rm -rf /var/lib/apt/lists/*

# ai.pl and its modules, named one by one (a glob would also take scratch files)
COPY ai.pl ai.pm md.pm tui.pm utils.pm /
COPY ai /ai
# the entrypoint that makes the device nodes of the boards and USB devices (aicli.sh)
COPY aicli-devices.sh /usr/local/bin/aicli-devices
RUN chmod 0755 /usr/local/bin/aicli-devices \
 && perl -cw /ai.pl

ENV HOME=/ai
USER root
WORKDIR /ai
VOLUME /ai
#ENTRYPOINT ["strace", "-f", "-tt", "-s", "512", "/usr/bin/perl", "/ai.pl"]
ENTRYPOINT ["/usr/bin/perl", "/ai.pl"]

# --------------------------------------------------------------------------
FROM base AS dev
ENV DEBIAN_FRONTEND=noninteractive

# python, lua, and the C/C++ toolchain (build-essential has no pkg-config, make is
# in it but cmake is not). libperl-dev is for the perl tool's XS modules.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-dev \
        lua5.4 luarocks \
        build-essential clang libssl-dev libperl-dev pkg-config make cmake \
    && rm -rf /var/lib/apt/lists/*

# the rest of the tools the model may use: ImageMagick (convert, image), the Perl
# modules of the perl tool, PDL (arrays, FFT) and Audio::Wav (WAV files), lame (an
# MP3 encoder), the perl docs, strace and the pipewire recorder (voice). aicli
# itself does not load the Perl modules.
RUN apt-get update && apt-get install -y --no-install-recommends \
        imagemagick \
        pdl libaudio-wav-perl lame perl-doc \
        strace pipewire-bin \
    && rm -rf /var/lib/apt/lists/*

# the radios and the USB power meters: rtl-sdr (rtl_test, rtl_sdr) for RTL-SDR
# dongles, libusb for the meters and dongles, usb_logger (the usb-multimeter package
# from PyPI, in a venv) for the JT-UM120 and FNIRSI power meters
RUN apt-get update && apt-get install -y --no-install-recommends \
        rtl-sdr libusb-1.0-0 python3-venv \
    && rm -rf /var/lib/apt/lists/*
ARG USB_METER_VERSION=3.0.0
RUN python3 -m venv /opt/usb-multimeter \
 && /opt/usb-multimeter/bin/pip install --no-cache-dir "usb-multimeter==${USB_METER_VERSION}" \
 && ln -s /opt/usb-multimeter/bin/usb_logger /usr/local/bin/usb_logger \
 && usb_logger --help >/dev/null

# nrfutil (Nordic), pinned by sha256: the device command flashes the nRF52840
# Dongle's sniffer firmware, ble-sniffer reads its output. Installed under /opt,
# with HOME there, so that any user can run it.
ARG NRFUTIL_URL="https://files.nordicsemi.com/artifactory/swtools/external/nrfutil/executables/x86_64-unknown-linux-gnu/nrfutil-x86_64-unknown-linux-gnu-1.4.2-8a9090a"
ARG NRFUTIL_SHA256=a14996288928a92081cadeefd2dd37fcb54ee99a568fd4eaa6fb9586a51fba57
ARG NRFUTIL_DEVICE=device=2.17.5
RUN curl -fsSL -o /usr/local/bin/nrfutil "${NRFUTIL_URL}" \
 && echo "${NRFUTIL_SHA256}  /usr/local/bin/nrfutil" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/nrfutil \
 && mkdir -p /opt/nrfutil \
 && HOME=/opt/nrfutil nrfutil install "${NRFUTIL_DEVICE}" \
 && HOME=/opt/nrfutil nrfutil install ble-sniffer --force \
 && HOME=/opt/nrfutil nrfutil device --help >/dev/null \
 && HOME=/opt/nrfutil nrfutil ble-sniffer --help >/dev/null

# the lists of the development languages (devel tool): made now, they are the same
# for every session of this image; bash is not listed, it is the PATH of the run
RUN perl -I/ -Mai -e 'tools::devel_build("/usr/share/aicli/devel")'
