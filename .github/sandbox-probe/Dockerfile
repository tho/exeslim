# Builds sandbox-probe (see main.go); export the binary with docker build -o.

FROM golang:1.27@sha256:e519d3b0a5b285e5aa53ab9eef02bc6bbb9cb04608389b743a136a9ce75f0d1e AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /sandbox-probe

FROM scratch
COPY --from=build /sandbox-probe /sandbox-probe
