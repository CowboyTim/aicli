FROM alpine
RUN apk add --no-cache perl perl-json perl-lwp-protocol-https perl-term-readline-gnu perl-json-xs
RUN apk add --no-cache perl-net-curl --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing
RUN apk add --no-cache bash
RUN apk add --no-cache strace
COPY ai.pl /
RUN perl -cw /ai.pl
ENV HOME=/ai
USER root
WORKDIR /ai
VOLUME /ai
#ENTRYPOINT ["strace", "-f", "-tt", "-s", "512", "/usr/bin/perl", "/ai.pl"]
ENTRYPOINT ["/usr/bin/perl", "/ai.pl"]
