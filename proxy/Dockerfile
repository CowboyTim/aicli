# squid (ubuntu/squid) with the iproute2 tools (ip). The image runs as before, with its declared volumes;
# this only adds the package (docker-compose.yaml builds it from here).
ARG BASE_IMAGE=ubuntu/squid:latest
FROM ${BASE_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 \
 && rm -rf /var/lib/apt/lists/*
