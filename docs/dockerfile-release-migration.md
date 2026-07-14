# Dockerfile release image migration

This note tracks the Dockerfile-based replacement for the current `ko` image
build flow.

For the full implementation README, see
`README-dockerfile-ko-replacement.md` at the repository root.

## Current ko references

The source manifests keep `ko://` references. The Dockerfile flow does not edit
these files directly; `hack/render-docker-release-yaml.sh` replaces them only in
generated release output.

| File | ko references | Dockerfile replacement |
| --- | --- | --- |
| `config/controller.yaml` | `cmd/controller`, `cmd/entrypoint`, `cmd/nop`, `cmd/sidecarlogresults`, `cmd/workingdirinit` | Rendered to `${CONTAINER_REGISTRY}/${PACKAGE}/cmd/<name>:${VERSION_TAG}` or digest form |
| `config/webhook.yaml` | `cmd/webhook` | Rendered to the Dockerfile-built webhook image |
| `config/events.yaml` | `cmd/events` | Rendered to the Dockerfile-built events image |
| `config/resolvers/resolvers-deployment.yaml` | `cmd/resolvers` | Rendered to the Dockerfile-built resolvers image; this image installs `git-core` and provides a `/sbin/tini` compatibility wrapper for the existing manifest command |

## Images built

The release builds one image per Go command package:

```text
controller
webhook
entrypoint
nop
workingdirinit
resolvers
sidecarlogresults
events
```

The image names intentionally preserve the existing import-path style used by
the `ko` flow:

```text
${CONTAINER_REGISTRY}/${PACKAGE}/cmd/${CMD}:${VERSION_TAG}
```

For example:

```text
ghcr.io/tektoncd/pipeline/github.com/tektoncd/pipeline/cmd/controller:v1.14.0
```

## Files changed for the Dockerfile flow

| File | Purpose |
| --- | --- |
| `Dockerfile` | Root UBI9 multi-stage Dockerfile. It builds any `cmd/<name>` binary via `ARG CMD`. |
| `build.sh` | Root single-platform Docker build entrypoint. Builds one image when `CMD` is set, or all release images by default. |
| `hack/build-ubi9-images.sh` | Builds and pushes all release images with `docker buildx`, then writes `/workspace/built_images` as `tag@digest` references. |
| `hack/render-docker-release-yaml.sh` | Concatenates `config/**/*.yaml`, replaces `ko://` image refs, and writes `release.yaml` plus `release.notags.yaml`. |
| `tekton/publish.yaml` | Uses the Dockerfile build/render scripts instead of `create-ko-yaml`, `run-ko`, and `koparse`; adds a Docker-in-Docker sidecar for `docker buildx`. |
| `tekton/release-pipeline.yaml` | Passes Docker build args and uses Linux-only publish platforms for UBI9 images. |
| `.github/workflows/nightly-builds.yaml` | Passes the renamed Docker build argument parameter. |
| `.github/workflows/ci.yaml` | Validates release YAML rendering without invoking `ko resolve`. |
| `config/controller.yaml` | Updates stale wording so helper image placeholders are described as release-rendered references. |

## Behavioral differences from ko

`ko` previously handled three jobs:

1. Build Go binaries.
2. Build and push container images.
3. Rewrite `ko://` references in release YAML.

The Dockerfile flow splits those jobs:

1. `Dockerfile` builds a binary image for one `cmd/<name>`.
2. `hack/build-ubi9-images.sh` builds and pushes all images.
3. `hack/render-docker-release-yaml.sh` rewrites release YAML.

UBI9 images are Linux images, so the Dockerfile flow rejects `windows/*`
platforms. Windows helper images are not produced by this replacement.

The publish Task now requires a privileged Docker daemon sidecar. Clusters that
disallow privileged sidecars need a different builder backend, such as a remote
BuildKit service, before this flow can run there.

## Remaining ko usage outside release publishing

This migration is scoped to release image publication. Some development and e2e
paths still use `ko` to build temporary images or install Tekton into test
clusters, including:

```text
.github/workflows/e2e-matrix.yml
.github/workflows/e2e-matrix-extras.yaml
test/presubmit-tests.sh
test/e2e-common.sh
test/README.md
hack/setup-kind.sh
```

Those paths are separate from `tekton/publish.yaml` and would need their own
Dockerfile-based install flow if the goal is to remove `ko` from all developer
and test workflows.
