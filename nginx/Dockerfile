# nginx with the iproute2 tools (ip): to look at the network from inside the container. The image is
# nginx:stable as before; this only adds the package (docker-compose.yaml builds it from here).
ARG BASE_IMAGE=nginx:stable
FROM ${BASE_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 \
 && rm -rf /var/lib/apt/lists/*
