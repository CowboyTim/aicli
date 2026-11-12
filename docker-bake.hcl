// docker buildx bake             builds the image the wrapper aicli.sh runs
// docker buildx bake image-ci    the same, with the GitHub Actions build cache
//
// The defaults match DOCKER_IMAGE in aicli.sh. Override them from the
// environment: IMAGE=... TAG=... PLATFORMS=linux/amd64,linux/arm64

variable "IMAGE" {
  default = "local/ai/aicli"
}

variable "TAG" {
  default = "latest"
}

variable "PLATFORMS" {
  default = "linux/amd64"
}

group "default" {
  targets = ["image"]
}

target "image" {
  context    = "."
  dockerfile = "Dockerfile"
  tags       = ["${IMAGE}:${TAG}"]
  platforms  = split(",", PLATFORMS)
  output     = ["type=docker"]
}

target "image-ci" {
  inherits   = ["image"]
  cache-from = ["type=gha"]
  cache-to   = ["type=gha,mode=max"]
}
