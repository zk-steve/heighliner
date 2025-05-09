ARG BASE_VERSION
FROM golang:${BASE_VERSION} AS build-env

RUN apk add --update --no-cache curl make git libc-dev bash gcc linux-headers eudev-dev ncurses-dev

ARG TARGETARCH
ARG BUILDARCH

ARG GITHUB_ORGANIZATION
ARG REPO_HOST

WORKDIR /go/src/${REPO_HOST}/${GITHUB_ORGANIZATION}

ARG GITHUB_REPO
ARG VERSION
ARG BUILD_TIMESTAMP

RUN git clone -b ${VERSION} --single-branch https://${REPO_HOST}/${GITHUB_ORGANIZATION}/${GITHUB_REPO}.git --recursive

WORKDIR /go/src/${REPO_HOST}/${GITHUB_ORGANIZATION}/${GITHUB_REPO}

ARG BUILD_TARGET
ARG BUILD_ENV
ARG BUILD_TAGS
ARG PRE_BUILD
ARG BUILD_DIR


RUN set -eux;\
    export ARCH=$(uname -m);\
    export CGO_ENABLED=1 LDFLAGS='-linkmode external -extldflags "-static"';\
    if [ ! -z "$PRE_BUILD" ]; then sh -c "${PRE_BUILD}"; fi;\
    if [ ! -z "$BUILD_TARGET" ]; then\
      if [ ! -z "$BUILD_ENV" ]; then export ${BUILD_ENV}; fi;\
      if [ ! -z "$BUILD_TAGS" ]; then export "${BUILD_TAGS}"; fi;\
      if [ ! -z "$BUILD_DIR" ]; then cd "${BUILD_DIR}"; fi;\
      sh -c "${BUILD_TARGET}";\
    fi

# Copy all binaries to /root/bin, for a single place to copy into final image.
# If a colon (:) delimiter is present, binary will be renamed to the text after the delimiter.
RUN mkdir /root/bin
ARG RACE
ARG BINARIES
ENV BINARIES_ENV ${BINARIES}
RUN bash -c 'set -eux;\
  BINARIES_ARR=();\
  IFS=, read -ra BINARIES_ARR <<< "$BINARIES_ENV";\
  for BINARY in "${BINARIES_ARR[@]}"; do\
    BINSPLIT=();\
    IFS=: read -ra BINSPLIT <<< "$BINARY";\
    BINPATH=${BINSPLIT[1]+"${BINSPLIT[1]}"};\
    BIN="$(eval "echo "${BINSPLIT[0]+"${BINSPLIT[0]}"}"")";\
    if [ ! -z "$RACE" ] && GOVERSIONOUT=$(go version -m $BIN); then\
      if echo $GOVERSIONOUT | grep build | grep "-race=true"; then\
        echo "Race detection is enabled in binary";\
      else\
        echo "Race detection not enabled in binary!";\
        exit 1;\
      fi;\
    fi;\
    if [ ! -z "$BINPATH" ]; then\
      if [[ $BINPATH == *"/"* ]]; then\
        mkdir -p "$(dirname "${BINPATH}")";\
        cp "$BIN" "${BINPATH}"; \
      else \
        cp "$BIN" "/root/bin/${BINPATH}";\
      fi;\
    else\
      cp "$BIN" /root/bin/;\
    fi;\
  done'

RUN mkdir -p /root/lib
ARG LIBRARIES
ENV LIBRARIES_ENV ${LIBRARIES}
RUN bash -c 'set -eux;\
  LIBRARIES_ARR=($LIBRARIES_ENV); for LIBRARY in "${LIBRARIES_ARR[@]}"; do cp $LIBRARY /root/lib/; done'

# Use minimal busybox from infra-toolkit image for final scratch image
FROM ghcr.io/strangelove-ventures/infra-toolkit:v0.1.12 AS infra-toolkit
RUN addgroup --gid 1025 -S heighliner && adduser --uid 1025 -S heighliner -G heighliner

# Use alpine to source the latest CA certificates
FROM alpine:3 as alpine-3

# Build final image from scratch
FROM scratch

LABEL org.opencontainers.image.source="https://github.com/strangelove-ventures/heighliner"

WORKDIR /bin

# Install minimal busybox as `sh` and `ln` binaries
# sh allows using `RUN` commands
COPY --from=infra-toolkit /busybox/busybox /bin/sh
# ln creates hardlinks for exposed binaries from infra-toolkit min config
COPY --from=infra-toolkit /busybox/busybox /bin/ln

# Install jq
COPY --from=infra-toolkit /usr/local/bin/jq /bin/

# Add hard links for utils
# Will then only have one copy of the busybox minimal binary file with all utils pointing to the same underlying inode
RUN for b in \
  cat \
  date \
  df \
  dirname \
  du \
  env \
  grep \
  head \
  less \
  ls \
  md5sum \
  mkdir \
  mv \
  pwd \
  rm \
  sed \
  sha1sum \
  sha256sum \
  sha3sum \
  sha512sum \
  sleep \
  stty \
  tail \
  tar \
  tee \
  tr \
  vi \
  watch \
  which \
  ; do ln ln $b; done; \
  rm -rf sh; \
  ln ln sh;

# Install chain binaries
COPY --from=build-env /root/bin /bin

# Install libraries
COPY --from=build-env /lib /lib

# Install trusted CA certificates
COPY --from=alpine-3 /etc/ssl/cert.pem /etc/ssl/cert.pem

# Install heighliner user
COPY --from=infra-toolkit /etc/passwd /etc/passwd
COPY --from=infra-toolkit --chown=1025:1025 /home/heighliner /home/heighliner
COPY --from=infra-toolkit --chown=1025:1025 /home/heighliner /tmp

WORKDIR /home/heighliner
USER heighliner
