FROM alpine
# ai.pl dependencies
RUN apk add --no-cache perl perl-json perl-lwp-protocol-https perl-term-readline-gnu perl-json-xs
RUN apk add --no-cache perl-net-curl --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing

# AI basic tool usage
RUN apk add --no-cache bash

# some tools
RUN apk add --no-cache ripgrep
RUN apk add --no-cache busybox
RUN apk add --no-cache grep
RUN apk add --no-cache findutils
RUN apk add --no-cache coreutils
RUN apk add --no-cache git
RUN apk add --no-cache openssh-client-common openssh-keygen openssh
RUN apk add --no-cache openssl

# dev stuff
RUN apk add --no-cache lua lua5.3 luajit-dev luajit lua5.3-stdlib lua5.3-posix lua5.3-socket luarocks5.3 luarocks
RUN apk add --no-cache python3 python3-dev
RUN apk add --no-cache curl
RUN apk add --no-cache socat
RUN apk add --no-cache wget
RUN apk add --no-cache perl-dev
RUN apk add --no-cache gcc make gcc-avr libgcc build-base musl-dev clang
RUN apk add --no-cache openssl-dev
RUN apk add --no-cache nasm
RUN apk add --no-cache diffutils patch

# debug
RUN apk add --no-cache strace

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
