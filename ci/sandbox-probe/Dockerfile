# Builds sandbox-probe (see main.go); export the binary with docker build -o.

FROM golang:1.27.4@sha256:5e8afd493a7124a8586e134d9b532731161d4b9becf9dee5a5956b107426f93d AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /sandbox-probe

FROM scratch
COPY --from=build /sandbox-probe /sandbox-probe
