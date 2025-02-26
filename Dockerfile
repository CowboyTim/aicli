FROM alpine
RUN apk add --no-cache perl perl-json perl-lwp-protocol-https
COPY ai.pl /
RUN perl -cw /ai.pl
ENV HOME=/ai
USER nobody
WORKDIR /ai
VOLUME /ai
ENTRYPOINT ["/usr/bin/perl", "/ai.pl"]