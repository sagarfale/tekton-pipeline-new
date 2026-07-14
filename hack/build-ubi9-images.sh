#!/usr/bin/env sh
set -eu

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PACKAGE="${PACKAGE:-github.com/tektoncd/pipeline}"
IMAGES="${IMAGES:-controller webhook entrypoint nop workingdirinit resolvers sidecarlogresults events}"
VERSION_TAG="${VERSION_TAG:?VERSION_TAG is required}"
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:?CONTAINER_REGISTRY is required, for example ghcr.io/tektoncd/pipeline}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64,linux/s390x,linux/ppc64le}"
DOCKERFILE="${DOCKERFILE:-${PROJECT_ROOT}/Dockerfile}"
OUTPUT_BUILT_IMAGES="${OUTPUT_BUILT_IMAGES:-/workspace/built_images}"
PUSH="${PUSH:-true}"
DOCKER_BUILD_EXTRA_ARGS="${DOCKER_BUILD_EXTRA_ARGS:-}"

if printf '%s\n' "${PLATFORMS}" | tr ',' '\n' | grep -q '^windows/'; then
  echo "UBI9 Dockerfile builds are Linux-only. Remove windows/* from PLATFORMS: ${PLATFORMS}" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for Dockerfile-based image builds" >&2
  exit 1
fi

if [ "${PUSH}" != "true" ] && printf '%s' "${PLATFORMS}" | grep -q ','; then
  echo "PUSH=false only supports a single platform because docker --load cannot load a manifest list" >&2
  exit 1
fi

if [ "${PUSH}" != "true" ]; then
  platform="${PLATFORMS}"
  TARGETOS="${platform%/*}" \
    TARGETARCH="${platform#*/}" \
    PROJECT_ROOT="${PROJECT_ROOT}" \
    PACKAGE="${PACKAGE}" \
    IMAGES="${IMAGES}" \
    VERSION_TAG="${VERSION_TAG}" \
    CONTAINER_REGISTRY="${CONTAINER_REGISTRY}" \
    DOCKERFILE="${DOCKERFILE}" \
    OUTPUT_BUILT_IMAGES="${OUTPUT_BUILT_IMAGES}" \
    PUSH=false \
    DOCKER_BUILD_EXTRA_ARGS="${DOCKER_BUILD_EXTRA_ARGS}" \
    "${PROJECT_ROOT}/build.sh"
  exit 0
fi

mkdir -p "$(dirname "${OUTPUT_BUILT_IMAGES}")"
: > "${OUTPUT_BUILT_IMAGES}"

for cmd in ${IMAGES}; do
  image="${CONTAINER_REGISTRY}/${PACKAGE}/cmd/${cmd}:${VERSION_TAG}"
  resolver_args=""
  if [ "${cmd}" = "resolvers" ]; then
    resolver_args="--build-arg INSTALL_RESOLVER_TOOLS=true"
  fi

  output_arg="--push"
  if [ "${PUSH}" != "true" ]; then
    output_arg="--load"
  fi

  # DOCKER_BUILD_EXTRA_ARGS is intentionally word-split so callers can pass
  # buildx flags such as "--no-cache" or "--progress=plain".
  # shellcheck disable=SC2086
  docker buildx build \
    --platform "${PLATFORMS}" \
    --file "${DOCKERFILE}" \
    --build-arg "CMD=${cmd}" \
    ${resolver_args} \
    --label "org.opencontainers.image.source=https://${PACKAGE}" \
    --label "org.opencontainers.image.url=https://${PACKAGE}" \
    --label "org.opencontainers.image.title=pipeline" \
    --label "org.opencontainers.image.description=Tekton Pipelines" \
    --tag "${image}" \
    ${output_arg} \
    ${DOCKER_BUILD_EXTRA_ARGS} \
    "${PROJECT_ROOT}"

  digest="$(docker buildx imagetools inspect "${image}" | awk '/^Digest:/ {print $2; exit}')"
  if [ -z "${digest}" ]; then
    echo "Unable to determine digest for ${image}" >&2
    exit 1
  fi
  printf '%s@%s\n' "${image}" "${digest}" >> "${OUTPUT_BUILT_IMAGES}"
done
