# Builds sandbox-probe (see main.go); export the binary with docker build -o.

FROM golang:1.27.4@sha256:205c7636d74e0ffbe3d007162df7d74f859f5a8c8322dfb9f907977686c126cf AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /sandbox-probe

FROM scratch
COPY --from=build /sandbox-probe /sandbox-probe
