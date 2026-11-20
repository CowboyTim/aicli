# Build definition for the images of this directory (pods/): the base image (the basic tools,
# the toolchains, and ai.pl fetched from GitHub at AICLI_REF), and the device images built on it:
# rocm, arduino and android. bash is the base image under its own name (see README.md).
#
#   docker buildx bake                 build every image into the local image store
#   docker buildx bake local           build every image into the local image store
#   docker buildx bake arduino         build one image (also rocm, android, bash)
#   docker buildx bake --print         show the resolved configuration
#   docker buildx bake --pull          also pull fresh base images
#
# Each image gets two tags: ${IMAGE_REPO}:<kind> for local use, and ${REGISTRY}/pod-<kind>:latest
# (only when AICLI_REGISTRY_HOST is set), which is the name to push and pull (the device images are built from the registry's base
# image, see README.md). To push one:
#   docker push $REGISTRY/pod-arduino:latest
#
# Every variable can be overridden from the environment, e.g.
#   AGENT_UID=$(id -u) AGENT_GID=$(id -g) docker buildx bake
# (Bash's UID is a non-exported shell variable, hence the AGENT_ prefix.)

variable "IMAGE_REPO" {
  default = "aicli-pod"
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

variable "ROCM_IMAGE" {
  # Pin to a digest or ROCm version tag for reproducible builds.
  default = "rocm/dev-ubuntu-24.04:latest"
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

# rocm: the TheRock nightly index for one GPU family (gfx1151 = Strix Halo)
variable "TORCH_INDEX" {
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

# arduino
variable "ARDUINO_CLI_VERSION" {
  default = "1.5.1"
}

variable "ARDUINO_BOARD_URLS" {
  default = "https://espressif.github.io/arduino-esp32/package_esp32_index.json"
}

variable "ARDUINO_CORES" {
  default = "esp32:esp32"
}

# arduino: usb-multimeter on PyPI (usb_logger)
variable "USB_METER_VERSION" {
  default = "3.0.0"
}

# arduino: nrfutil's refresh (run.sh --update changes it, the layer is built again)
variable "NRFUTIL_REFRESH" {
  default = "0"
}

# android: the build number in commandlinetools-linux-<n>_latest.zip (developer.android.com/studio)
variable "ANDROID_CMDLINE_TOOLS" {
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

# docker buildx bake: every image, into the local image store
group "default" {
  targets = ["base", "bash", "rocm", "arduino", "android"]
}

# the same as default, by name
group "local" {
  targets = ["base", "bash", "rocm", "arduino", "android"]
}

# Shared settings; the leading underscore marks it as not meant to be built alone
target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
  args = {
    USERNAME  = AGENT_USER
    UID       = AGENT_UID
    GID       = AGENT_GID
    AICLI_REPO = AICLI_REPO
    AICLI_REF  = AICLI_REF
  }
  # Load into the local image store (like "docker build --load"),
  # so "docker run" and the push can see the result.
  output = ["type=docker"]
}

target "base" {
  inherits = ["_common"]
  target   = "base"
  tags     = concat(["${IMAGE_REPO}:base"], AICLI_REGISTRY_HOST == "" ? [] : ["${REGISTRY}/pod-base:latest"])
  args = {
    BASE_IMAGE = UBUNTU_IMAGE
  }
}

# bash: the base image, under the name run.sh uses for it
target "bash" {
  inherits = ["_common"]
  target   = "base"
  tags     = concat(["${IMAGE_REPO}:bash"], AICLI_REGISTRY_HOST == "" ? [] : ["${REGISTRY}/pod-bash:latest"])
  args = {
    BASE_IMAGE = UBUNTU_IMAGE
  }
}

target "rocm" {
  inherits = ["_common"]
  target   = "rocm"
  tags     = concat(["${IMAGE_REPO}:rocm"], AICLI_REGISTRY_HOST == "" ? [] : ["${REGISTRY}/pod-rocm:latest"])
  args = {
    BASE_IMAGE          = ROCM_IMAGE
    TORCH_INDEX         = TORCH_INDEX
    TORCH_VERSION       = TORCH_VERSION
    TORCHVISION_VERSION = TORCHVISION_VERSION
    TORCHAUDIO_VERSION  = TORCHAUDIO_VERSION
  }
}

target "arduino" {
  inherits = ["_common"]
  target   = "arduino"
  tags     = concat(["${IMAGE_REPO}:arduino"], AICLI_REGISTRY_HOST == "" ? [] : ["${REGISTRY}/pod-arduino:latest"])
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
  tags     = concat(["${IMAGE_REPO}:android"], AICLI_REGISTRY_HOST == "" ? [] : ["${REGISTRY}/pod-android:latest"])
  args = {
    BASE_IMAGE            = UBUNTU_IMAGE
    ANDROID_CMDLINE_TOOLS = ANDROID_CMDLINE_TOOLS
    ANDROID_PLATFORM      = ANDROID_PLATFORM
    ANDROID_BUILD_TOOLS   = ANDROID_BUILD_TOOLS
    GRADLE_VERSION        = GRADLE_VERSION
  }
}
