FROM alpine
RUN apk add --no-cache perl
COPY ai.pl /
ENV HOME=/ai
USER nobody
WORKDIR /ai
VOLUME /ai
ENTRYPOINT ["/usr/bin/perl", "/ai.pl"]
