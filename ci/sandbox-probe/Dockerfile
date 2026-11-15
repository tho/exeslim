# Builds sandbox-probe (see main.go); export the binary with docker build -o.

FROM golang:1.27@sha256:ec47ea3725fea0cc88f6de94919aef19f40f12fc1ec0e2d1b3426dbf15ecca04 AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /sandbox-probe

FROM scratch
COPY --from=build /sandbox-probe /sandbox-probe
