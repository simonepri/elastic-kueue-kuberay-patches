ARG BUILDER_IMAGE=golang:1.27
ARG BASE_IMAGE=gcr.io/distroless/base-debian12:nonroot

FROM --platform=${BUILDPLATFORM} ${BUILDER_IMAGE} AS builder
WORKDIR /workspace

COPY go.mod go.sum ./
RUN go mod download

COPY . .

USER root
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -ldflags="-w -s" -a -o /workspace/manager main.go
RUN mkdir -p /workspace/ko-app && ln -s /manager /workspace/ko-app/ray-operator

FROM ${BASE_IMAGE}
WORKDIR /
USER 65532:65532
ENTRYPOINT ["/manager"]
COPY --from=builder /workspace/manager /manager
COPY --from=builder /workspace/ko-app /ko-app
