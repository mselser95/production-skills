# syntax=docker/dockerfile:1
FROM golang:1.26 AS builder
WORKDIR /app

COPY go.mod ./
RUN go mod download

COPY . .

# Build identity (operational determinism: production output is
# F(code, config, state, inputs), and an incident must be able to answer
# "this ran with commit X" -- see internal/platform/buildinfo).
# runtime/debug.ReadBuildInfo() is the PRIMARY source and needs no flags
# here (it works on any plain `go build` run inside a git checkout, and
# .dockerignore deliberately keeps .git in this build's context -- see
# that file's own comment for why). GIT_SHA/BUILD_TIME below are the
# -ldflags FALLBACK path only, for a build pipeline that cannot include
# .git in its context; both default to empty, which buildinfo.Get()
# treats exactly like "no VCS info available", not a build failure.
ARG GIT_SHA=""
ARG BUILD_TIME=""
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w \
      -X github.com/<OWNER>/<SERVICE>/internal/platform/buildinfo.ldRevision=${GIT_SHA} \
      -X github.com/<OWNER>/<SERVICE>/internal/platform/buildinfo.ldBuildTime=${BUILD_TIME}" \
      -o /out/svc ./cmd/<SERVICE>

# Pure-Go, static -> distroless static nonroot.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder --chown=nonroot:nonroot /out/svc /app/svc
EXPOSE 8081
ENTRYPOINT ["/app/svc"]
