FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive

# ai.pl dependencies: Perl, the JSON and readline modules, WWW::Curl for the HTTP
# requests, and the CA certificates for the HTTPS APIs
RUN apt-get update && apt-get install -y --no-install-recommends \
        perl libjson-xs-perl libwww-curl-perl libterm-readline-gnu-perl libdata-uuid-perl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# tools the model may use, the Perl modules of the perl tool: PDL (arrays, FFT)
# and Audio::Wav (WAV files), and lame, an MP3 encoder for the WAV files. aicli
# itself does not load them.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ripgrep grep findutils coreutils diffutils patch \
        git openssh-client openssl \
        curl wget socat \
        imagemagick \
        pdl libaudio-wav-perl lame perl-doc \
        python3 python3-dev \
        lua5.4 luarocks \
        build-essential clang libssl-dev libperl-dev pkg-config \
        strace \
        pipewire-bin \
    && rm -rf /var/lib/apt/lists/*

# ai.pl
COPY *.pm *.pl /
COPY ai /ai
# the lists of the development languages (devel tool): made now, they are the same
# for every session of this image; bash is not listed, it is the PATH of the run
RUN perl -I/ -Mai -e 'tools::devel_build("/usr/share/aicli/devel")'

RUN perl -cw /ai.pl
ENV HOME=/ai
USER root
WORKDIR /ai
VOLUME /ai
#ENTRYPOINT ["strace", "-f", "-tt", "-s", "512", "/usr/bin/perl", "/ai.pl"]
ENTRYPOINT ["/usr/bin/perl", "/ai.pl"]
