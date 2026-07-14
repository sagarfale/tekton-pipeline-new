# syntax=docker/dockerfile:1

ARG BUILDER_IMAGE=registry.access.redhat.com/ubi9/go-toolset:latest
ARG RUNTIME_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest

FROM ${BUILDER_IMAGE} AS builder

ARG CMD
ARG TARGETOS=linux
ARG TARGETARCH=amd64

ENV CGO_ENABLED=0

WORKDIR /workspace/source
COPY . .

RUN test -n "${CMD}"
RUN GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
    go build -mod=vendor -buildvcs=false -trimpath -ldflags="-s -w" -o "/workspace/out/${CMD}" "./cmd/${CMD}"

RUN mkdir -p /workspace/out/kodata && \
    if [ -d "cmd/${CMD}/kodata" ]; then \
      cp -a "cmd/${CMD}/kodata/." /workspace/out/kodata/ && \
      tar -C vendor -czf /workspace/out/kodata/source.tar.gz .; \
    fi

FROM ${RUNTIME_IMAGE}

ARG CMD
ARG INSTALL_RESOLVER_TOOLS=false

RUN if [ "${INSTALL_RESOLVER_TOOLS}" = "true" ]; then \
      microdnf install -y git-core && \
      microdnf clean all && \
      printf '#!/bin/sh\nif [ "$1" = "--" ]; then shift; fi\nexec "$@"\n' > /sbin/tini && \
      chmod +x /sbin/tini; \
    fi

COPY --from=builder "/workspace/out/${CMD}" "/ko-app/${CMD}"
COPY --from=builder /workspace/out/kodata/ /var/run/ko/

RUN ln -s "/ko-app/${CMD}" /ko-app/app

ENV KO_DATA_PATH=/var/run/ko

ENTRYPOINT ["/ko-app/app"]
