FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive

# ai.pl dependencies: Perl, the JSON and readline modules, WWW::Curl for the HTTP
# requests, and the CA certificates for the HTTPS APIs
RUN apt-get update && apt-get install -y --no-install-recommends \
        perl libjson-xs-perl libwww-curl-perl libterm-readline-gnu-perl libdata-uuid-perl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# tools the model may use, and the Perl modules of the perl tool: PDL (arrays,
# FFT) and Audio::Wav (WAV files). aicli itself does not load them.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ripgrep grep findutils coreutils diffutils patch \
        git openssh-client openssl \
        curl wget socat \
        imagemagick \
        pdl libaudio-wav-perl \
        python3 python3-dev \
        lua5.4 luarocks \
        build-essential clang libssl-dev libperl-dev \
        strace \
        pipewire-bin \
    && rm -rf /var/lib/apt/lists/*

# ai.pl
COPY *.pm *.pl /
COPY ai /ai
RUN perl -cw /ai.pl
ENV HOME=/ai
USER root
WORKDIR /ai
VOLUME /ai
#ENTRYPOINT ["strace", "-f", "-tt", "-s", "512", "/usr/bin/perl", "/ai.pl"]
ENTRYPOINT ["/usr/bin/perl", "/ai.pl"]
