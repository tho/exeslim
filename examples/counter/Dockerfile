# A stateful service on exeslim: build a static binary, then install it and
# its unit, root-owned, into an image derived from exeslim.
#
#   docker build -t counter .
#   docker build --build-arg BASE=exeslim:dev -t counter .   # a local base

# Declared before the first FROM so the second FROM can use it.
ARG BASE=ghcr.io/tho/exeslim:latest

FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /counter

FROM ${BASE}
COPY --from=build --chmod=0755 /counter /usr/local/bin/counter
COPY --chmod=0644 svc-counter.service /etc/systemd/system/svc-counter.service
RUN systemctl enable svc-counter.service
# No token here: anything in the image is readable by whoever can pull it. It
# goes on the VM after `new`; see docs/deploying.md#secrets.
