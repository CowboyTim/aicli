# Build definition for the pod image of this project: "base", the basic tools of a session's
# pod (bash, perl, grep, find, Rust, nodejs, npm, go). The agent images (rocm, arduino,
# android) are built outside this project.
#
#   docker buildx bake                 build base into the local image store
#   docker buildx bake --print         show the resolved configuration
#   docker buildx bake --pull          also pull a fresh base image
#
# The image also gets the tag ${REGISTRY}/pod-base:latest, which is what the broker pulls
# (broker.json). To make it available to the broker, push it:
#   docker push $REGISTRY/pod-base:latest
# PLAN.md, "Decided: no pods", says what is left of this directory.
#
# Every variable can be overridden from the environment, e.g.
#   AGENT_UID=$(id -u) AGENT_GID=$(id -g) docker buildx bake
# (Bash's UID is a non-exported shell variable, hence the AGENT_ prefix.)

variable "IMAGE_REPO" {
  default = "aicli-pod"
}

variable "AICLI_REGISTRY_HOST" {
  # the registry host the pod image is pushed to and pulled from (an external registry, set in
  # the environment; bake reads a variable of the same name from it). The broker takes
  # AICLI_POD_REGISTRY from its compose settings.
  default = ""
}

variable "REGISTRY" {
  # the image prefix of the pod image: ${AICLI_REGISTRY_HOST}/aicli
  default = "${AICLI_REGISTRY_HOST}/aicli"
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
  tags     = ["${IMAGE_REPO}:base", "${REGISTRY}/pod-base:latest"]
  args = {
    BASE_IMAGE = UBUNTU_IMAGE
  }
}
