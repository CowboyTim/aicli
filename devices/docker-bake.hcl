# Build definition for the base image of the device images: the basic tools, the toolchains,
# and ai.pl fetched from GitHub at AICLI_REF (see Dockerfile and README.md).
#
#   docker buildx bake                 build base into the local image store
#   docker buildx bake --print         show the resolved configuration
#   docker buildx bake --pull          also pull a fresh base image
#
# The image also gets the tag ${REGISTRY}/device-base:latest, the name the device images are
# built FROM when they are pulled from the registry. To push it:
#   docker push $REGISTRY/device-base:latest
#
# Every variable can be overridden from the environment, e.g.
#   AGENT_UID=$(id -u) AGENT_GID=$(id -g) docker buildx bake
# (Bash's UID is a non-exported shell variable, hence the AGENT_ prefix.)

variable "IMAGE_REPO" {
  default = "aicli-device"
}

variable "AICLI_REGISTRY_HOST" {
  # the registry host the images are pushed to and pulled from (an external registry, set in
  # the environment; bake reads a variable of the same name from it)
  default = ""
}

variable "REGISTRY" {
  # the image prefix of the images: ${AICLI_REGISTRY_HOST}/aicli
  default = "${AICLI_REGISTRY_HOST}/aicli"
}

variable "AICLI_REPO" {
  default = "https://github.com/CowboyTim/aicli"
}

# the commit of ai.pl (a full commit id of the repository above; see Dockerfile)
variable "AICLI_REF" {
  default = "0b70b5eaaec61cb55782df5d9f335ff46686ff2f"
}

variable "UBUNTU_IMAGE" {
  default = "ubuntu:24.04"
}

variable "AGENT_USER" {
  default = "agent"
}

variable "AGENT_UID" {
  default = "1000"
}

variable "AGENT_GID" {
  default = "1000"
}

group "default" {
  targets = ["base"]
}

# Shared settings; the leading underscore marks it as not meant to be built alone
target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
  args = {
    USERNAME = AGENT_USER
    UID      = AGENT_UID
    GID      = AGENT_GID
  }
  # Load into the local image store (like "docker build --load"),
  # so "docker run" and the broker's push can see the result.
  output = ["type=docker"]
}

target "base" {
  inherits = ["_common"]
  target   = "base"
  tags     = ["${IMAGE_REPO}:base", "${REGISTRY}/device-base:latest"]
  args = {
    BASE_IMAGE = UBUNTU_IMAGE
    AICLI_REPO = AICLI_REPO
    AICLI_REF  = AICLI_REF
  }
}
