#!/usr/bin/env bash
# build.sh - called by the pipeline to build Tekton Pipeline images.
# Builds Docker images using the multi-stage root Dockerfile that:
#   1. Compiles the requested Go binary in the builder stage
#   2. Creates the final minimal UBI9-based container image
set -euo pipefail

# Set variables to prevent unbound variable errors in pipeline scripts.
export VERBOSE="${VERBOSE:-0}"
export __SOURCED__="${__SOURCED__:-0}"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PACKAGE="${PACKAGE:-github.com/tektoncd/pipeline}"
IMAGES="${IMAGES:-controller webhook entrypoint nop workingdirinit resolvers sidecarlogresults events}"
VERSION_TAG="${VERSION_TAG:-${IMAGE_TAG:-v1.14.0}}"
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-${IMAGE_REGISTRY:-icr.io/tektoncd/pipeline}}"
TARGETARCH="${TARGETARCH:-amd64}"
TARGETOS="${TARGETOS:-linux}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
OUTPUT_BUILT_IMAGES="${OUTPUT_BUILT_IMAGES:-/workspace/built_images}"
PUSH="${PUSH:-false}"
DOCKER_BUILD_EXTRA_ARGS="${DOCKER_BUILD_EXTRA_ARGS:-}"

if [[ "${TARGETOS}" != "linux" ]]; then
  echo "UBI9 Dockerfile builds support linux targets only, got TARGETOS=${TARGETOS}" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for Dockerfile-based image builds" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT_BUILT_IMAGES}")"
: > "${OUTPUT_BUILT_IMAGES}"

cd "${PROJECT_ROOT}"

commands="${CMD:-${IMAGES}}"
for cmd in ${commands}; do
  image_name="${IMAGE_NAME:-${CONTAINER_REGISTRY}/${PACKAGE}/cmd/${cmd}}"
  image_ref="${image_name}:${VERSION_TAG}"

  resolver_args=()
  if [[ "${cmd}" == "resolvers" ]]; then
    resolver_args+=(--build-arg INSTALL_RESOLVER_TOOLS=true)
  fi

  push_args=()
  if [[ "${PUSH}" == "true" ]]; then
    push_args+=(--push)
  fi

  read -r -a extra_args <<< "${DOCKER_BUILD_EXTRA_ARGS}"

  docker build \
    -f "${DOCKERFILE}" \
    -t "${image_ref}" \
    --build-arg "CMD=${cmd}" \
    --build-arg "TARGETARCH=${TARGETARCH}" \
    --build-arg "TARGETOS=${TARGETOS}" \
    --label "org.opencontainers.image.source=https://${PACKAGE}" \
    --label "org.opencontainers.image.url=https://${PACKAGE}" \
    --label "org.opencontainers.image.title=pipeline" \
    --label "org.opencontainers.image.description=Tekton Pipelines" \
    "${resolver_args[@]}" \
    "${push_args[@]}" \
    "${extra_args[@]}" \
    .

  if [[ "${PUSH}" == "true" ]]; then
    digest="$(docker buildx imagetools inspect "${image_ref}" | awk '/^Digest:/ {print $2; exit}')"
    if [[ -z "${digest}" ]]; then
      echo "Unable to determine digest for ${image_ref}" >&2
      exit 1
    fi
    printf '%s@%s\n' "${image_ref}" "${digest}" >> "${OUTPUT_BUILT_IMAGES}"
  else
    printf '%s\n' "${image_ref}" >> "${OUTPUT_BUILT_IMAGES}"
  fi
done
