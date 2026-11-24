# Two stages share one "system" stage:
#
#   base   small: ai.pl and the basic unix tools (bash, git, curl, text tools).
#   dev    base + the dev tools (python3, C/C++ with make, cmake and pkg-config), image
#          conversion (ImageMagick, ffmpeg), the perl tool's PDL and Audio::Wav, lame,
#          and the list of their modules for the devel tool, made at build time.
#
# The default target (the last stage) is dev, which is what aicli.sh runs. Hardware is
# not in these images: each kind of device (arduino, rocm, android, usb meters, rtl-sdr,
# nrf) is its own image in its own repository, which runs ai.pl as a remote agent.
# docker build --target base gives the small image.
#
# The package installs come before the COPY of ai.pl and ai/ in each stage. Docker
# caches layers in order, so a change to the code would otherwise rebuild every
# install after it. Both stages copy the code themselves (dev does not build on
# base), so a code change rebuilds only the copy and the steps after it.
#
# Ubuntu, not Debian: the specific stages that come later (ROCm, arduino-cli) start
# from Ubuntu images, so the layers share one distribution.

ARG BASE_IMAGE=ubuntu:24.04

# --------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS system
ENV DEBIAN_FRONTEND=noninteractive

# ai.pl dependencies: Perl, the JSON and readline modules, WWW::Curl for the HTTP
# requests, the CA certificates for the HTTPS APIs, and Net::SSLeay for the
# web interface over https (ai.pl --tls-cert)
RUN apt-get update && apt-get install -y --no-install-recommends \
        perl libjson-xs-perl libwww-curl-perl libterm-readline-gnu-perl libdata-uuid-perl \
        libnet-ssleay-perl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# the unix tools the model uses: a shell, the text tools, git, and the network tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ripgrep grep findutils coreutils diffutils patch \
        git openssh-client openssl \
        curl wget socat iproute2 \
    && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------------------------------
FROM system AS base
ENV DEBIAN_FRONTEND=noninteractive

# ai.pl and its modules, named one by one (a glob would also take scratch files)
COPY ai.pl ai.pm md.pm remote_agent.pm remote_hub.pm tui.pm utils.pm ui.pm worker.pm /
COPY ai /ai
RUN perl -cw /ai.pl

ENV HOME=/ai
USER root
WORKDIR /ai
#ENTRYPOINT ["strace", "-f", "-tt", "-s", "512", "/usr/bin/perl", "/ai.pl"]
ENTRYPOINT ["/usr/bin/perl", "/ai.pl"]

# --------------------------------------------------------------------------
FROM system AS dev
ENV DEBIAN_FRONTEND=noninteractive

# the development tools: python3, and the C/C++ toolchain with make, cmake and pkg-config
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-dev \
        build-essential clang libssl-dev libperl-dev pkg-config make cmake \
    && rm -rf /var/lib/apt/lists/*

# image conversion and media: ImageMagick (the convert tool and the image tool), ffmpeg,
# the perl tool's modules, PDL (arrays, FFT) and Audio::Wav (WAV files), lame (an MP3
# encoder), the perl docs, qrencode (the QR code of the web interface), and the pipewire
# recorder (voice)
RUN apt-get update && apt-get install -y --no-install-recommends \
        imagemagick ffmpeg \
        pdl libaudio-wav-perl lame perl-doc \
        qrencode pipewire-bin \
    && rm -rf /var/lib/apt/lists/*

COPY ai.pl ai.pm md.pm remote_agent.pm remote_hub.pm tui.pm utils.pm ui.pm worker.pm /
COPY ai /ai
RUN perl -cw /ai.pl
RUN perl -I/ -Mai -e 'tools::devel_build("/usr/share/aicli/devel")'

ENV HOME=/ai
USER root
WORKDIR /ai
#ENTRYPOINT ["strace", "-f", "-tt", "-s", "512", "/usr/bin/perl", "/ai.pl"]
ENTRYPOINT ["/usr/bin/perl", "/ai.pl"]
