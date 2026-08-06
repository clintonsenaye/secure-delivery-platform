##############################################################################
# demo-app
#
# A two stage build producing a distroless, non-root, statically linked image.
#
# The application is trivial. This file is not, and it is the part worth
# reading: on a platform whose premise is proving where software came from, the
# shape of the artefact is the argument. Every decision below is written out,
# because "we used distroless" is not an answer, and "here is what distroless
# removes and what that costs" is.
##############################################################################

##############################################################################
# Stage 1: build
#
# WHY TWO STAGES AT ALL
#
# A Go toolchain image is roughly 800 MB. It contains a compiler, a linker, a
# package manager, git, a shell, and a full userland. None of that is needed to
# *run* the program, and all of it is available to an attacker who gets code
# execution inside the container.
#
# A single stage build ships the entire build environment to production. The
# compiler that built your binary becomes a tool for compiling the attacker's.
# Two stages means the build environment exists only on the build machine, and
# the shipped image contains the binary and nothing else.
#
# The secondary benefit is size, and it is genuinely secondary. An 800 MB image
# is slow to pull and expensive to store. A 12 MB image is neither. But if size
# were the only argument, compressing the toolchain would do. The argument is
# that the toolchain should not be there.
#
# The builder is pinned to a minor version rather than floating on :latest, for
# the same reason .terraform.lock.hcl is committed in chapter 1: a build that
# resolves differently on different days is not reproducible, and reproducibility
# is the whole premise.
##############################################################################
FROM golang:1.26-alpine AS build

WORKDIR /src

# Dependencies are copied and downloaded before the source, so that editing
# main.go does not invalidate the layer holding the module cache. This is a
# build speed optimisation, not a security one, but it is why these two lines
# are separate from the COPY below.
COPY go.mod go.sum ./
RUN go mod download

COPY main.go ./

# Build provenance, supplied by the Makefile and linked into the binary. The
# binary can then report the commit it was built from at /version, which is
# what makes the running process traceable back to a line of source.
ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown

# WHY A STATIC BINARY
#
# CGO_ENABLED=0 makes the Go linker resolve everything at link time rather than
# leaving dynamic references to the system C library. The result depends on no
# shared object at runtime.
#
# That matters because it is what makes the final stage possible. A dynamically
# linked binary needs libc, a loader, and the correct versions of both, which
# means the runtime image must contain a userland. Static linking removes the
# runtime's dependency on the operating system entirely, so the runtime image
# can contain nothing but the binary.
#
# The cost is real and worth stating: Go's pure-Go DNS resolver behaves slightly
# differently from glibc's, and it ignores nsswitch.conf. For a service that
# resolves names through Kubernetes DNS this is fine, and it is one of the few
# places where "it works on my machine" and "it works in the cluster" can
# genuinely diverge.
#
# -trimpath removes local filesystem paths from the binary, so the artefact does
# not depend on which directory it was built in and does not leak the builder's
# layout. -s -w strip the symbol table and DWARF debug information, which cuts
# several megabytes. The trade is that a core dump is harder to read; for a
# service this small that is the right side of the trade.
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w \
        -X main.version=${VERSION} \
        -X main.gitCommit=${GIT_COMMIT} \
        -X main.buildTime=${BUILD_TIME}" \
      -o /out/demo-app .

##############################################################################
# Stage 2: run
#
# WHY DISTROLESS
#
# gcr.io/distroless/static contains CA certificates, timezone data, /etc/passwd
# and a couple of other files. It does not contain a shell, a package manager,
# curl, wget, or any of the standard binaries.
#
# The point is not that those tools are dangerous in themselves. The point is
# that an attacker who achieves code execution in a container normally proceeds
# by running things: a shell to look around, a package manager to install what
# is missing, curl to pull down a second stage. In an image with no shell and no
# package manager, that entire playbook fails at the first step. The attacker is
# reduced to whatever the application binary itself can be made to do.
#
# It also collapses the vulnerability surface. Most CVEs reported against a
# typical container image are in operating system packages the application never
# calls. Removing the packages removes the CVEs, which means the scanner output
# in chapter 3 is short enough that someone will actually read it. A scan with
# 400 findings is ignored; a scan with none is a signal.
#
# WHY THIS IS A REAL COST, NOT A FREE WIN
#
# You cannot `kubectl exec` into this container and look around, because there
# is nothing to exec. Debugging is done through logs, metrics, and
# `kubectl debug` ephemeral containers, which is a different skill and a slower
# one at three in the morning. Choosing distroless is choosing to invest in
# observability instead of interactive access. That is the correct trade for
# production and it is a trade, not a freebie.
#
# The alternative considered and rejected was `scratch`, which is genuinely
# empty. It was rejected because it has no CA certificate bundle (so outbound
# TLS fails) and no /etc/passwd (so a numeric user has no name and some tooling
# behaves oddly). distroless/static is scratch plus exactly the handful of files
# that stop those two problems, which makes it the better default.
#
# WHY NON-ROOT
#
# The :nonroot tag runs as UID 65532 and ships an /etc/passwd entry for it.
#
# Root inside a container is not root on the host, but the isolation is a
# kernel namespace rather than a security boundary designed to be attacked. A
# container escape from an unprivileged user has considerably less to work with
# than one from UID 0. Running as non-root also means that if the root
# filesystem were ever mounted writable by mistake, the process still could not
# write to paths it does not own.
#
# The Deployment manifest sets runAsNonRoot: true, which makes the kubelet
# *refuse to start* the pod if the image would run as UID 0. That is the belt to
# this image's braces: the image chooses non-root, and the cluster enforces it,
# so neither one is trusted alone.
##############################################################################
FROM gcr.io/distroless/static-debian12:nonroot

# OCI metadata. Not decoration: these labels are what lets a registry, a scanner
# or an admission controller say which source revision an image came from
# without unpacking it.
ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
LABEL org.opencontainers.image.title="demo-app" \
      org.opencontainers.image.description="Deliberately boring demo service for the secure-delivery-platform" \
      org.opencontainers.image.source="https://github.com/clintonsenaye/secure-delivery-platform" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.licenses="MIT"

COPY --from=build /out/demo-app /demo-app

# Documentation only. Publishing a port in the image does not open it; the
# Service and the containerPort in the Deployment do that. It is here so anyone
# reading the image knows what it listens on.
EXPOSE 8080

# Inherited from the :nonroot tag, but stated explicitly. An image should not
# rely on a base tag for a property this important, because the base tag can be
# changed by a one word edit and the change is easy to miss in review.
USER 65532:65532

# No shell exists in this image, so this is the exec form by necessity as well
# as by preference. The exec form also makes the binary PID 1, which means it
# receives SIGTERM directly from the kubelet and can drain in-flight requests
# rather than being killed by a shell that ignores the signal.
ENTRYPOINT ["/demo-app"]
