ARG BUILDER_IMAGE=public.ecr.aws/docker/library/golang:1.27
ARG BASE_IMAGE=gcr.io/distroless/static:nonroot

FROM --platform=${BUILDPLATFORM} ${BUILDER_IMAGE} AS builder
WORKDIR /workspace

COPY go.mod go.sum ./
COPY hack/testing/retry.sh /usr/local/bin/retry.sh
RUN retry.sh --attempts 7 --delay 2 --exponential --stream -- go mod download

COPY . .
ARG GIT_TAG GIT_COMMIT TARGETARCH CGO_ENABLED=0
RUN make build GIT_TAG="${GIT_TAG}" GIT_COMMIT="${GIT_COMMIT}" GO_BUILD_ENV="GOARCH=${TARGETARCH} CGO_ENABLED=${CGO_ENABLED}"
RUN mkdir -p /workspace/ko-app && ln -s /manager /workspace/ko-app/kueue

FROM ${BASE_IMAGE}
WORKDIR /
USER 65532:65532
ENTRYPOINT ["/manager"]
COPY --from=builder /workspace/bin/manager /manager
COPY --from=builder /workspace/ko-app /ko-app
