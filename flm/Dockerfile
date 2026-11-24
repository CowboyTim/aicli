# FastFlowLM (flm): the NPU runtime and server of the AMD Ryzen AI NPU (Strix Halo). The
# server here does the speech recognition (whisper, the OpenAI compatible transcription endpoint
# on port 52625) for ai.pl's /voice. FastFlowLM publishes no container image: this one installs
# the release's .deb, pinned by its sha256.
#
# The NPU runtime (libxrt2, libxrt-npu2, amdxdna-dkms) is not in Ubuntu's archive. It comes from
# the lemonade-team/stable PPA (the one FastFlowLM's docs name). The PPA's signing key is fetched by
# its fingerprint and checked against it before it is trusted. The NPU itself is the host's: the
# amdxdna driver, and /dev/accel/accel0 passed in by docker-compose.yaml.

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG FLM_VERSION=1.0.13
ARG FLM_URL=https://github.com/ROCm/FastFlowLM/releases/download/v1.0.13/fastflowlm_1.0.13_ubuntu24.04_amd64.deb
ARG FLM_SHA256=48483a6757522be1dcdb33f85bbd41630f72819f5d1f2d81c79848cdd5902ea7
# the PPA, and the fingerprint of its signing key (Launchpad: ~lemonade-team/ubuntu/stable)
ARG XRT_APT_LINE="deb [signed-by=/usr/share/keyrings/lemonade-team-stable.gpg] https://ppa.launchpadcontent.net/lemonade-team/stable/ubuntu noble main"
ARG XRT_KEY_FPR=881CF4B40B0BFA288D6776E83BF36CFA0BD50AEC

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg iproute2 \
 && rm -rf /var/lib/apt/lists/*

# the PPA's signing key: fetched by its fingerprint, checked against it, kept as a keyring
RUN set -eux; \
    gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "${XRT_KEY_FPR}"; \
    gpg --batch --export "${XRT_KEY_FPR}" > /usr/share/keyrings/lemonade-team-stable.gpg; \
    got=$(gpg --batch --with-colons --show-keys /usr/share/keyrings/lemonade-team-stable.gpg | awk -F: '/^fpr:/ {print $10; exit}'); \
    [ "$got" = "${XRT_KEY_FPR}" ] || { echo "flm: the PPA key is $got, not ${XRT_KEY_FPR}" >&2; exit 1; }; \
    rm -rf /root/.gnupg; \
    echo "${XRT_APT_LINE}" > /etc/apt/sources.list.d/lemonade-team-stable.list; \
    apt-get update

# the release's .deb, checked against its sha256, with the packages it depends on
RUN set -eux; \
    curl -fsSL -o /tmp/flm.deb "${FLM_URL}"; \
    echo "${FLM_SHA256}  /tmp/flm.deb" | sha256sum -c -; \
    apt-get install -y --no-install-recommends /tmp/flm.deb; \
    rm -f /tmp/flm.deb; \
    rm -rf /var/lib/apt/lists/*

# the libraries of the models, and the binary on the PATH
RUN echo /opt/fastflowlm/lib > /etc/ld.so.conf.d/fastflowlm.conf && ldconfig
ENV PATH=/opt/fastflowlm/bin:${PATH} \
    HOME=/var/lib/flm

# the models are kept in HOME (a volume in docker-compose.yaml), so a restart does not download them
RUN mkdir -p /var/lib/flm
VOLUME ["/var/lib/flm"]

EXPOSE 52625

# the speech recognizer by default, on every interface of the container (flm serves on localhost
# otherwise, and the agent reaches it by name); other models with other arguments (flm --help)
ENTRYPOINT ["flm"]
CMD ["serve", "-a", "whisper-v3:turbo", "--host", "0.0.0.0"]
