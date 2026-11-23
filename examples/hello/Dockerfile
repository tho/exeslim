# A stateless service on exeslim: build a static binary, then install it and
# its unit, root-owned, into an image derived from exeslim.
#
#   docker build -t hello .
#   docker build --build-arg BASE=ghcr.io/tho/exeslim:<build-id> -t hello .
#   docker build --build-arg BASE=ghcr.io/tho/exeslim:dev -t hello .   # a local base

ARG BASE=ghcr.io/tho/exeslim:latest

FROM golang:1.27.4@sha256:205c7636d74e0ffbe3d007162df7d74f859f5a8c8322dfb9f907977686c126cf AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hello

FROM ${BASE}
COPY --from=build --chmod=0755 /hello /usr/local/bin/hello
COPY --chmod=0644 svc-hello.service /etc/systemd/system/svc-hello.service
RUN systemctl enable svc-hello.service
