# The base pod: the basic tools of every session (bash, perl and grep), in the
# project's directory (/work). Not the agent: no ai.pl here, the agent runs elsewhere.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends perl bash grep coreutils \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
