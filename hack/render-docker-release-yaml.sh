#!/usr/bin/env sh
set -eu

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PACKAGE="${PACKAGE:-github.com/tektoncd/pipeline}"
IMAGES="${IMAGES:-controller webhook entrypoint nop workingdirinit resolvers sidecarlogresults events}"
VERSION_TAG="${VERSION_TAG:?VERSION_TAG is required}"
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:?CONTAINER_REGISTRY is required, for example ghcr.io/tektoncd/pipeline}"
OUTPUT_RELEASE_DIR="${OUTPUT_RELEASE_DIR:?OUTPUT_RELEASE_DIR is required}"
BUILT_IMAGES_FILE="${BUILT_IMAGES_FILE:-/workspace/built_images}"
CONFIG_DIR="${CONFIG_DIR:-${PROJECT_ROOT}/config}"

mkdir -p "${OUTPUT_RELEASE_DIR}"

release_yaml="${OUTPUT_RELEASE_DIR}/release.yaml"
release_notags_yaml="${OUTPUT_RELEASE_DIR}/release.notags.yaml"

write_config_bundle() {
  local output="$1"
  : > "${output}"
  find "${CONFIG_DIR}" -type f -name '*.yaml' | sort | while IFS= read -r file; do
    printf -- '---\n' >> "${output}"
    cat "${file}" >> "${output}"
    printf '\n' >> "${output}"
  done
}

image_with_digest_for() {
  local cmd="$1"
  local image="${CONTAINER_REGISTRY}/${PACKAGE}/cmd/${cmd}:${VERSION_TAG}"
  local resolved=""
  if [ -f "${BUILT_IMAGES_FILE}" ]; then
    resolved="$(grep -F "/cmd/${cmd}:${VERSION_TAG}@sha256:" "${BUILT_IMAGES_FILE}" | head -n 1 || true)"
  fi
  printf '%s\n' "${resolved:-${image}}"
}

digest_only_ref() {
  local image="$1"
  case "${image}" in
    *@*)
      local before_at="${image%%@*}"
      local digest="${image##*@}"
      local repository="${before_at%:*}"
      printf '%s@%s\n' "${repository}" "${digest}"
      ;;
    *)
      printf '%s\n' "${image}"
      ;;
  esac
}

replace_refs() {
  local output="$1"
  local no_tags="$2"
  local cmd image replacement

  for cmd in ${IMAGES}; do
    image="$(image_with_digest_for "${cmd}")"
    if [ "${no_tags}" = "true" ]; then
      replacement="$(digest_only_ref "${image}")"
    else
      replacement="${image}"
    fi
    sed -i "s|ko://${PACKAGE}/cmd/${cmd}|${replacement}|g" "${output}"
  done

  sed -i \
    -e "s|\(pipeline.tekton.dev/release\): \"devel\"|\1: \"${VERSION_TAG}\"|g" \
    -e "s|\(app.kubernetes.io/version\): \"devel\"|\1: \"${VERSION_TAG}\"|g" \
    -e "s|\(version\): \"devel\"|\1: \"${VERSION_TAG}\"|g" \
    "${output}"

  if grep -q 'ko://' "${output}"; then
    echo "Unresolved ko:// references remain in ${output}" >&2
    grep -n 'ko://' "${output}" >&2
    exit 1
  fi
}

write_config_bundle "${release_yaml}"
cp "${release_yaml}" "${release_notags_yaml}"

replace_refs "${release_yaml}" false
replace_refs "${release_notags_yaml}" true
