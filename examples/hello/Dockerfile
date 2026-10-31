# A stateless service on exeslim: build a static binary, then install it and
# its unit, root-owned, into an image derived from exeslim.
#
#   docker build -t hello .
#   docker build --build-arg BASE=ghcr.io/tho/exeslim:<build-id> -t hello .
#   docker build --build-arg BASE=ghcr.io/tho/exeslim:dev -t hello .   # a local base

ARG BASE=ghcr.io/tho/exeslim:latest

FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hello

FROM ${BASE}
COPY --from=build --chmod=0755 /hello /usr/local/bin/hello
COPY --chmod=0644 svc-hello.service /etc/systemd/system/svc-hello.service
RUN systemctl enable svc-hello.service
