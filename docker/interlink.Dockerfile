ARG BUILDER_IMAGE=golang:1.27
ARG BASE_IMAGE=gcr.io/distroless/static:nonroot

FROM --platform=${BUILDPLATFORM} ${BUILDER_IMAGE} AS builder
WORKDIR /workspace

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG VERSION TARGETARCH
RUN KUBELET_VERSION="${VERSION}" ./cmd/virtual-kubelet/set-version.sh
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -ldflags="-w -s" -o /workspace/vk ./cmd/virtual-kubelet

FROM ${BASE_IMAGE}
WORKDIR /
USER 65532:65532
ENTRYPOINT ["/vk"]
COPY --from=builder /workspace/vk /vk
