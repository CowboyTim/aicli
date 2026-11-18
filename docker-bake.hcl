// docker buildx bake             builds every image: the base and the dev image
// docker buildx bake image       only the dev image, the one the wrapper aicli.sh runs
// docker buildx bake base        only the small base image
// docker buildx bake image-ci    the dev image, with the GitHub Actions build cache
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
  targets = ["base", "image"]
}

// the small image: ai.pl and the basic unix tools
target "base" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "base"
  tags       = ["${IMAGE}-base:${TAG}"]
  platforms  = split(",", PLATFORMS)
  output     = ["type=docker"]
}

// the development image: base plus the languages and the tools (the default stage)
target "image" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "dev"
  tags       = ["${IMAGE}:${TAG}"]
  platforms  = split(",", PLATFORMS)
  output     = ["type=docker"]
}

target "image-ci" {
  inherits   = ["image"]
  cache-from = ["type=gha"]
  cache-to   = ["type=gha,mode=max"]
}

// The pods of the broker: images of a registry the broker pulls from (REGISTRY, a
// local registry on the host by default; see README.md, "The pods").
variable "REGISTRY" {
  default = "localhost:5000"
}

group "pods" {
  targets = ["pod-base", "pod-node"]
}

// the base pod: bash, perl and grep, every project has it
target "pod-base" {
  context    = "pods"
  dockerfile = "base.Dockerfile"
  tags       = ["${REGISTRY}/aicli/pod-base:${TAG}"]
  platforms  = split(",", PLATFORMS)
  output     = ["type=registry"]
}

// the node pod: node, npm and npx
target "pod-node" {
  context    = "pods"
  dockerfile = "node.Dockerfile"
  tags       = ["${REGISTRY}/aicli/pod-node:${TAG}"]
  platforms  = split(",", PLATFORMS)
  output     = ["type=registry"]
}
