# Build definitions for the aicli pod images: plain dev images, one per toolchain.
#
#   docker buildx bake                 build all of them into the local image store
#   docker buildx bake bash            only aicli-pod:bash
#   docker buildx bake rocm            only aicli-pod:rocm (arduino, android, node likewise)
#   docker buildx bake --print         show the resolved configuration
#   docker buildx bake --pull          also pull fresh base images
#
# Each image also gets the tag ${REGISTRY}/pod-<name>:latest, which is what the
# broker pulls (broker.json). To make them available to it, push them, e.g.
#   for p in bash rocm arduino android node; do docker push $REGISTRY/pod-$p:latest; done
# README.md, "The pods", has the registry setup.
#
# Every variable can be overridden from the environment, e.g.
#   AGENT_UID=$(id -u) AGENT_GID=$(id -g) docker buildx bake
# run.sh sets AGENT_UID/AGENT_GID to your host ids for you. (Bash's UID is a
# non-exported shell variable, hence the AGENT_ prefix.)

variable "IMAGE_REPO" {
  default = "aicli-pod"
}

variable "REGISTRY" {
  # the registry the broker pulls from and pushes go to: the stack's public name and the
  # registry port (nginx-local, see docker-compose.yaml). Set PUBLIC_DOMAIN in the environment.
  default = "${getenv("PUBLIC_DOMAIN")}:5443/aicli"
}

variable "ROCM_IMAGE" {
  # Pin to a digest or ROCm version tag for reproducible builds.
  default = "rocm/dev-ubuntu-24.04:latest"
}

variable "UBUNTU_IMAGE" {
  default = "ubuntu:24.04"
}

variable "NODE_IMAGE" {
  # Pin to a version for reproducible builds (node.Dockerfile).
  default = "node:22-bookworm-slim"
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

variable "NRFUTIL_REFRESH" {
  default = "0"
}

variable "TORCH_INDEX" {
  # TheRock nightly index for one GPU family (gfx1151 = Strix Halo)
  default = "https://rocm.nightlies.amd.com/v2/gfx1151/"
}

variable "TORCH_VERSION" {
  default = "2.9.1+rocm7.13.0a20260513"
}

variable "TORCHVISION_VERSION" {
  default = "0.24.0+rocm7.13.0a20260513"
}

variable "TORCHAUDIO_VERSION" {
  default = "2.9.0+rocm7.13.0a20260513"
}

variable "ARDUINO_CLI_VERSION" {
  default = "1.5.1"
}

variable "ARDUINO_BOARD_URLS" {
  default = "https://espressif.github.io/arduino-esp32/package_esp32_index.json"
}

variable "ARDUINO_CORES" {
  default = "esp32:esp32"
}

variable "USB_METER_VERSION" {
  # usb-multimeter on PyPI (usb_logger)
  default = "3.0.0"
}

variable "ANDROID_CMDLINE_TOOLS" {
  # build number in commandlinetools-linux-<n>_latest.zip (developer.android.com/studio)
  default = "15859902"
}

variable "ANDROID_PLATFORM" {
  default = "android-35"
}

variable "ANDROID_BUILD_TOOLS" {
  default = "35.0.0"
}

variable "GRADLE_VERSION" {
  default = "8.14.6"
}

group "default" {
  targets = ["local"]
}

# Everything, loaded into the local image store
group "local" {
  targets = ["rocm", "bash", "arduino", "android", "node"]
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

target "rocm" {
  inherits = ["_common"]
  target   = "rocm"
  tags     = ["${IMAGE_REPO}:rocm", "${REGISTRY}/pod-rocm:latest"]
  args = {
    BASE_IMAGE          = ROCM_IMAGE
    TORCH_INDEX         = TORCH_INDEX
    TORCH_VERSION       = TORCH_VERSION
    TORCHVISION_VERSION = TORCHVISION_VERSION
    TORCHAUDIO_VERSION  = TORCHAUDIO_VERSION
  }
}

target "bash" {
  inherits = ["_common"]
  target   = "bash"
  tags     = ["${IMAGE_REPO}:bash", "${REGISTRY}/pod-bash:latest"]
  args = {
    BASE_IMAGE = UBUNTU_IMAGE
  }
}

target "arduino" {
  inherits = ["_common"]
  target   = "arduino"
  tags     = ["${IMAGE_REPO}:arduino", "${REGISTRY}/pod-arduino:latest"]
  args = {
    BASE_IMAGE          = UBUNTU_IMAGE
    ARDUINO_CLI_VERSION = ARDUINO_CLI_VERSION
    ARDUINO_BOARD_URLS  = ARDUINO_BOARD_URLS
    ARDUINO_CORES       = ARDUINO_CORES
    USB_METER_VERSION   = USB_METER_VERSION
    NRFUTIL_REFRESH     = NRFUTIL_REFRESH
  }
}

target "android" {
  inherits = ["_common"]
  target   = "android"
  tags     = ["${IMAGE_REPO}:android", "${REGISTRY}/pod-android:latest"]
  args = {
    BASE_IMAGE            = UBUNTU_IMAGE
    ANDROID_CMDLINE_TOOLS = ANDROID_CMDLINE_TOOLS
    ANDROID_PLATFORM      = ANDROID_PLATFORM
    ANDROID_BUILD_TOOLS   = ANDROID_BUILD_TOOLS
    GRADLE_VERSION        = GRADLE_VERSION
  }
}

# nodejs and npm only (node.Dockerfile, not the Dockerfile above)
target "node" {
  context    = "."
  dockerfile = "node.Dockerfile"
  platforms  = ["linux/amd64"]
  args = {
    NODE_IMAGE = NODE_IMAGE
  }
  output = ["type=docker"]
  tags   = ["${IMAGE_REPO}:node", "${REGISTRY}/pod-node:latest"]
}
