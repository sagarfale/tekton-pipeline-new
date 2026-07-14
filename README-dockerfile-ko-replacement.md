# Replacing ko release builds with Dockerfile-based UBI9 images

This README explains how the Tekton Pipelines release image build path was
changed from `ko` to Dockerfile-based UBI9 images, which files are involved,
how `ko://` references are handled, and how to build and render release YAML.

## Summary

Tekton Pipelines originally used `ko` for release image publication.

`ko` did three things:

1. Compiled Go binaries from `cmd/*` packages.
2. Built and pushed container images.
3. Rewrote Kubernetes manifests from `ko://...` image placeholders to real image
   references in generated release YAML.

The replacement splits those jobs across Dockerfile and scripts:

1. `Dockerfile.ubi9` compiles one Go binary and creates a UBI9-based runtime image.
2. `build.sh` builds one or all Tekton images for a single target architecture.
3. `hack/build-ubi9-images.sh` is the release-task helper for multi-arch
   `docker buildx` builds.
4. `hack/render-docker-release-yaml.sh` replaces `ko://...` placeholders in
   generated release YAML.

The source manifests keep their `ko://` placeholders. They are not edited into
hard-coded image names. The generated `release.yaml` and `release.notags.yaml`
receive the final image references.

## Why ko could not be replaced by only a Dockerfile

A Dockerfile can build images, but `ko` also rewrote YAML.

Old flow:

```text
config/*.yaml with ko:// references
        |
        v
ko resolve
        |
        v
build images, push images, generate release.yaml
```

New flow:

```text
cmd/* Go packages
        |
        v
Dockerfile.ubi9 / build.sh
        |
        v
UBI9 images
        |
        v
hack/render-docker-release-yaml.sh
        |
        v
release.yaml and release.notags.yaml
```

That is the core replacement: Dockerfile handles image creation, and the render
script handles what `ko resolve` used to do to manifests.

## Images built

The release builds these eight images:

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

Each image maps to a Go command package:

| Image | Go package |
| --- | --- |
| `controller` | `./cmd/controller` |
| `webhook` | `./cmd/webhook` |
| `entrypoint` | `./cmd/entrypoint` |
| `nop` | `./cmd/nop` |
| `workingdirinit` | `./cmd/workingdirinit` |
| `resolvers` | `./cmd/resolvers` |
| `sidecarlogresults` | `./cmd/sidecarlogresults` |
| `events` | `./cmd/events` |

Image names preserve the existing import-path layout used by the previous `ko`
flow:

```text
${CONTAINER_REGISTRY}/${PACKAGE}/cmd/${CMD}:${VERSION_TAG}
```

Example:

```text
icr.io/my-namespace/tekton/github.com/tektoncd/pipeline/cmd/controller:v1.14.0
```

## Files added

| File | Purpose |
| --- | --- |
| `Dockerfile.ubi9` | Root multi-stage Dockerfile. Builds any Tekton `cmd/<name>` binary into a UBI9 runtime image. |
| `.dockerignore` | Keeps `.git`, docs, tests, examples, and other unnecessary files out of Docker build context. |
| `build.sh` | User-facing build entrypoint. Builds one image when `CMD` is set, or all eight images by default. |
| `hack/build-ubi9-images.sh` | Release-task helper. Uses `docker buildx` for multi-platform push builds and writes `/workspace/built_images`. |
| `hack/render-docker-release-yaml.sh` | Generates `release.yaml` and `release.notags.yaml` by replacing `ko://...` placeholders. |
| `docs/dockerfile-release-migration.md` | Short tracking note listing changed files and remaining `ko` usage outside release publishing. |

## Files changed

| File | Change |
| --- | --- |
| `tekton/publish.yaml` | Replaces `create-ko-yaml`, `run-ko`, and `koparse` with Dockerfile build and release-render steps. Adds a Docker-in-Docker sidecar for `docker buildx`. |
| `tekton/release-pipeline.yaml` | Renames `koExtraArgs` to `dockerBuildExtraArgs` and makes UBI9 publish platforms Linux-only. |
| `.github/workflows/nightly-builds.yaml` | Passes `dockerBuildExtraArgs` and removes `windows/amd64` from publish platforms. |
| `.github/workflows/ci.yaml` | Replaces the CI `ko resolve` release check with `hack/render-docker-release-yaml.sh` validation. |
| `config/controller.yaml` | Updates a stale comment from "`ko resolve` replaces these" to "release rendering replaces these." |

## ko references and how they are handled

The following source files still contain `ko://` placeholders:

| File | References |
| --- | --- |
| `config/controller.yaml` | `cmd/controller`, `cmd/entrypoint`, `cmd/nop`, `cmd/sidecarlogresults`, `cmd/workingdirinit` |
| `config/webhook.yaml` | `cmd/webhook` |
| `config/events.yaml` | `cmd/events` |
| `config/resolvers/resolvers-deployment.yaml` | `cmd/resolvers` |

These references are intentionally left in source manifests. They are replaced
only when release YAML is generated.

Example source reference:

```yaml
image: ko://github.com/tektoncd/pipeline/cmd/controller
```

Example rendered release reference:

```yaml
image: icr.io/my-namespace/tekton/github.com/tektoncd/pipeline/cmd/controller:v1.14.0@sha256:<digest>
```

For `release.notags.yaml`, the render script removes the tag and keeps the
digest-only form:

```yaml
image: icr.io/my-namespace/tekton/github.com/tektoncd/pipeline/cmd/controller@sha256:<digest>
```

## Dockerfile behavior

The root `Dockerfile.ubi9` is parameterized by `CMD`.

Important build arguments:

| Argument | Meaning | Default |
| --- | --- | --- |
| `CMD` | The command package under `cmd/` to build. Required. |
| `TARGETOS` | Go target OS. | `linux` |
| `TARGETARCH` | Go target architecture. | `amd64` |
| `BUILDER_IMAGE` | Builder base image. | `registry.access.redhat.com/ubi9/ubi:9.8-1782841664` |
| `RUNTIME_IMAGE` | Runtime base image. | `registry.access.redhat.com/ubi9/ubi-minimal:9.8-1782797275` |
| `INSTALL_RESOLVER_TOOLS` | Installs resolver-only runtime tooling. | `false` |

## UBI9 image choices

The migration pins UBI images instead of using floating `latest` tags.

Available UBI9 image inputs considered:

| Image type | Image |
| --- | --- |
| UBI9 default | `registry.access.redhat.com/ubi9/ubi:9.8-1782841664` |
| UBI9 minimal | `registry.access.redhat.com/ubi9/ubi-minimal:9.8-1782797275` |
| UBI9 Python | `registry.access.redhat.com/ubi9/python-312:9.8-1783600910` |
| UBI9 micro | `registry.access.redhat.com/ubi9/ubi-micro:9.8-1782840931` |

Current Dockerfile usage:

| Stage | Image | Reason |
| --- | --- | --- |
| Builder | `registry.access.redhat.com/ubi9/ubi:9.8-1782841664` | Full UBI has `dnf`, so the builder can install Go and build the Tekton binaries. |
| Runtime | `registry.access.redhat.com/ubi9/ubi-minimal:9.8-1782797275` | Smaller UBI runtime image while still supporting `microdnf` for resolver-only `git-core`. |

The Python image is not used because Tekton Pipelines release binaries are Go
programs, not Python applications.

The micro image is not used for the current runtime because the resolver image
needs `git-core`; UBI micro is too small for that package-install flow. If all
runtime dependencies were copied in from a builder stage, UBI micro could be
evaluated separately.

The builder stage:

```text
go build -mod=vendor -buildvcs=false -trimpath -ldflags="-s -w" ./cmd/${CMD}
```

The runtime stage:

```text
registry.access.redhat.com/ubi9/ubi-minimal:9.8-1782797275
```

The final binary is copied to:

```text
/ko-app/${CMD}
```

and a generic symlink is created:

```text
/ko-app/app -> /ko-app/${CMD}
```

The default container entrypoint is:

```text
/ko-app/app
```

### Resolver image special case

`cmd/resolvers` needs `git` at runtime. The old `.ko.yaml` used a special base
image with `git` and `/sbin/tini`.

The Dockerfile replacement handles that with:

```text
--build-arg INSTALL_RESOLVER_TOOLS=true
```

For resolver images, the Dockerfile:

1. Installs `git-core` using `microdnf`.
2. Creates a small `/sbin/tini` compatibility wrapper.

The wrapper exists because `config/resolvers/resolvers-deployment.yaml` still
runs:

```yaml
command:
- /sbin/tini
- --
- /ko-app/resolvers
```

UBI9 minimal does not provide a `tini` package in the enabled repositories, so
the wrapper preserves the existing command shape without pulling a non-UBI base.

## build.sh usage

Run from the repo root:

```bash
cd /root/sovereign-core/test-tekton/pipeline-v1.14.0
```

### Build one image locally

Example for `nop`:

```bash
CMD=nop \
IMAGE_NAME=local/tekton-nop \
IMAGE_TAG=test \
TARGETOS=linux \
TARGETARCH=amd64 \
PUSH=false \
OUTPUT_BUILT_IMAGES=/tmp/tekton-built-images \
./build.sh
```

### Build resolver locally

```bash
CMD=resolvers \
CONTAINER_REGISTRY=local/tekton \
VERSION_TAG=test \
TARGETOS=linux \
TARGETARCH=amd64 \
PUSH=false \
OUTPUT_BUILT_IMAGES=/tmp/tekton-built-images-resolvers \
./build.sh
```

### Build all eight images locally

```bash
CONTAINER_REGISTRY=local/tekton \
VERSION_TAG=test \
TARGETOS=linux \
TARGETARCH=amd64 \
PUSH=false \
OUTPUT_BUILT_IMAGES=/tmp/tekton-built-images-all \
./build.sh
```

### Push images to a registry

Authenticate first. For IBM Cloud Container Registry:

```bash
ibmcloud login
ibmcloud cr login
ibmcloud cr namespaces
```

Then push with a real namespace:

```bash
CONTAINER_REGISTRY=icr.io/<your-namespace>/tekton \
VERSION_TAG=v1.14.0 \
TARGETOS=linux \
TARGETARCH=amd64 \
PUSH=true \
OUTPUT_BUILT_IMAGES=/tmp/tekton-built-images \
./build.sh
```

Do not use placeholder values such as `your-namespace`; the registry will reject
the push with `401 Unauthorized`.

## Multi-platform release builds

`build.sh` is a simple single-platform entrypoint. The release task uses
`hack/build-ubi9-images.sh` for multi-platform builds with `docker buildx`.

Example:

```bash
CONTAINER_REGISTRY=icr.io/<your-namespace>/tekton \
VERSION_TAG=v1.14.0 \
PLATFORMS=linux/amd64,linux/arm64,linux/s390x,linux/ppc64le \
PUSH=true \
OUTPUT_BUILT_IMAGES=/tmp/tekton-built-images \
hack/build-ubi9-images.sh
```

`PUSH=false` with `hack/build-ubi9-images.sh` supports only one platform because
Docker cannot `--load` a multi-platform manifest list into the local daemon.

## Rendering release YAML

After images are built and `/tmp/tekton-built-images` exists, render release
YAML:

```bash
PACKAGE=github.com/tektoncd/pipeline \
VERSION_TAG=v1.14.0 \
CONTAINER_REGISTRY=icr.io/<your-namespace>/tekton \
OUTPUT_RELEASE_DIR=/tmp/tekton-release \
BUILT_IMAGES_FILE=/tmp/tekton-built-images \
hack/render-docker-release-yaml.sh
```

Generated files:

```text
/tmp/tekton-release/release.yaml
/tmp/tekton-release/release.notags.yaml
```

Check that rendering replaced all placeholders:

```bash
rg 'ko://' /tmp/tekton-release
```

Expected result: no matches.

## How the Tekton release task changed

The old release task in `tekton/publish.yaml` had these main steps:

```text
container-registry-auth
create-ko-yaml
run-ko
koparse
tag-images
```

The new release task has:

```text
container-registry-auth
build-ubi9-images
render-release-yaml
tag-images
```

The new `build-ubi9-images` step:

1. Starts from the Docker CLI image.
2. Talks to a Docker-in-Docker sidecar.
3. Calls `hack/build-ubi9-images.sh`.
4. Produces `/workspace/built_images`.

The new `render-release-yaml` step:

1. Calls `hack/render-docker-release-yaml.sh`.
2. Produces `release.yaml`.
3. Produces `release.notags.yaml`.

The existing `tag-images` step still reads:

```text
/workspace/built_images
```

That keeps the later image-copying and Tekton Chains signing behavior close to
the original shape.

## Platform behavior

UBI9 images are Linux images. This replacement intentionally removes the
previous Windows publish platform:

```text
windows/amd64
```

Supported release platforms are now:

```text
linux/amd64
linux/arm64
linux/s390x
linux/ppc64le
```

If Windows helper images are still required, they need a separate Windows image
build flow. They cannot be produced from UBI9.

## Validation commands

Run static checks:

```bash
bash -n build.sh
sh -n hack/build-ubi9-images.sh
sh -n hack/render-docker-release-yaml.sh
git diff --check
```

Validate edited YAML:

```bash
python3 -c 'import sys, yaml
for path in sys.argv[1:]:
    with open(path) as f:
        list(yaml.safe_load_all(f))
    print(path)' \
  .github/workflows/ci.yaml \
  .github/workflows/nightly-builds.yaml \
  tekton/publish.yaml \
  tekton/release-pipeline.yaml \
  config/controller.yaml
```

Render with fake digests:

```bash
tmpdir=$(mktemp -d /tmp/tekton-render.XXXXXX)
built="$tmpdir/built_images"
: > "$built"
for cmd in controller webhook entrypoint nop workingdirinit resolvers sidecarlogresults events; do
  echo "example.com/github.com/tektoncd/pipeline/cmd/${cmd}:v0.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111" >> "$built"
done

PACKAGE=github.com/tektoncd/pipeline \
VERSION_TAG=v0.0.0 \
CONTAINER_REGISTRY=example.com \
OUTPUT_RELEASE_DIR="$tmpdir/out" \
BUILT_IMAGES_FILE="$built" \
hack/render-docker-release-yaml.sh

rg 'ko://' "$tmpdir/out"
```

Expected result: no `ko://` matches.

## Troubleshooting

### Registry push returns 401 Unauthorized

Example:

```text
failed to fetch anonymous token ... 401 Unauthorized
```

Cause: Docker is trying to push to a registry path where you are not
authenticated or where the namespace is only a placeholder.

Fix:

```bash
ibmcloud login
ibmcloud cr login
ibmcloud cr namespaces
```

Then use a real namespace:

```bash
CONTAINER_REGISTRY=icr.io/<your-namespace>/tekton
```

For local-only builds, use:

```bash
PUSH=false
```

### `tini` is not available in UBI9 minimal

UBI9 minimal does not provide a `tini` package in the enabled repositories.
`Dockerfile.ubi9` creates `/sbin/tini` as a small wrapper for the resolver image.

### Go build fails with VCS stamping

`Dockerfile.ubi9` uses:

```text
-buildvcs=false
```

This avoids failures when `.git` is excluded from the Docker build context.

### Docker daemon permission denied

Example:

```text
permission denied while trying to connect to the docker API
```

Fix locally:

```bash
sudo docker ps
```

or add your user to the Docker group if appropriate for your environment.

In Tekton, the publish task uses a privileged Docker-in-Docker sidecar. Clusters
that disallow privileged sidecars need a different builder backend, such as a
remote BuildKit service.

## Remaining ko usage outside release publishing

This replacement is scoped to release image publication. Some development and
test flows still use `ko`, including:

```text
.github/workflows/e2e-matrix.yml
.github/workflows/e2e-matrix-extras.yaml
test/presubmit-tests.sh
test/e2e-common.sh
test/README.md
hack/setup-kind.sh
```

Those paths build temporary images and install Tekton into local test clusters.
They are separate from `tekton/publish.yaml` and require a separate migration if
the goal is to remove `ko` from every workflow.

## Quick end-to-end local example

Build all images locally:

```bash
CONTAINER_REGISTRY=local/tekton \
VERSION_TAG=test \
TARGETOS=linux \
TARGETARCH=amd64 \
PUSH=false \
OUTPUT_BUILT_IMAGES=/tmp/tekton-built-images-all \
./build.sh
```

Render manifests:

```bash
PACKAGE=github.com/tektoncd/pipeline \
VERSION_TAG=test \
CONTAINER_REGISTRY=local/tekton \
OUTPUT_RELEASE_DIR=/tmp/tekton-release \
BUILT_IMAGES_FILE=/tmp/tekton-built-images-all \
hack/render-docker-release-yaml.sh
```

Inspect output:

```bash
ls -l /tmp/tekton-release
rg 'ko://' /tmp/tekton-release
```

Expected result: `release.yaml` and `release.notags.yaml` exist, and there are
no `ko://` references in either file.
