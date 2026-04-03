FROM ccd-base:latest

USER root

# Install Go
ARG GO_VERSION=1.23.4
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz

USER node

ENV PATH="/usr/local/go/bin:/home/node/go/bin:${PATH}"
ENV GOPATH=/home/node/go
ENV GOMODCACHE=/home/node/go/pkg/mod
