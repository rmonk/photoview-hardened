# Hardened Photoview image: upstream's source at the release tag, built like upstream's Dockerfile
# but with the newest stable Go (upstream uses Debian 12's golang package, Go 1.19) and bumped Go
# modules; runtime packages installed without "recommends" (which pulled in printing/desktop extras
# such as ipp-usb, another Go 1.19 binary) and upgraded; a fixed non-root uid.
#
# Build context: build/src (upstream source + hardening/), prepared by scripts/prepare.sh.
# Build args come from build/build-args.

ARG NODE_IMAGE
ARG GO_IMAGE
ARG RUNTIME_IMAGE

### UI (as upstream) ###
FROM ${NODE_IMAGE} AS ui
ARG UPSTREAM_VERSION
ARG UPSTREAM_SHA
ARG BUILD_DATE
ENV REACT_APP_BUILD_VERSION=${UPSTREAM_VERSION} \
    REACT_APP_BUILD_DATE=${BUILD_DATE} \
    REACT_APP_BUILD_COMMIT_SHA=${UPSTREAM_SHA} \
    UI_PUBLIC_URL=/
COPY ui /app
WORKDIR /app
RUN npm ci --omit=dev --ignore-scripts \
 && npm run build -- --base=$UI_PUBLIC_URL

### API (upstream's build, native amd64, current Go) ###
FROM ${GO_IMAGE} AS api
# go-face (dlib) and libheif need these, as in upstream's docker/install_build_dependencies.sh.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libdlib-dev libblas-dev libatlas-base-dev liblapack-dev libjpeg-dev libheif-dev \
 && rm -rf /var/lib/apt/lists/*
ENV GOTOOLCHAIN=local CGO_ENABLED=1
COPY api /app
COPY hardening /hardening
WORKDIR /app
RUN sh /hardening/go-bump.sh /hardening/go-bumps.txt \
 && go mod download \
 # Patch go-face like upstream: no -march=native, so the binary runs on any amd64 CPU
 && sed -i 's/-march=native//g' "$(go env GOMODCACHE)"/github.com/\!kagami/go-face*/face.go \
 && go build -trimpath -v -o photoview . \
 && go version -m photoview | head -1

### Runtime (upstream's, minus recommends, plus upgrade and a fixed uid) ###
FROM ${RUNTIME_IMAGE}
ARG UPSTREAM_VERSION
ARG UPSTREAM_SHA
ARG HARDENED_VERSION=dev
ARG HARDENED_SOURCE=
# Fixed IDs; upstream's 999 is a system account on many hosts (systemd-oom on futomaki).
ARG PHOTOVIEW_UID=8082
ARG PHOTOVIEW_GID=8082

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN groupadd -g "${PHOTOVIEW_GID}" photoview \
 && useradd -r -u "${PHOTOVIEW_UID}" -g photoview -m photoview \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg gpg \
 && echo 'deb https://download.opensuse.org/repositories/graphics:/darktable/Debian_12/ /' \
      > /etc/apt/sources.list.d/graphics:darktable.list \
 && curl -fsSL https://download.opensuse.org/repositories/graphics:/darktable/Debian_12/Release.key \
      | gpg --dearmor > /etc/apt/trusted.gpg.d/graphics_darktable.gpg \
 && apt-get update \
 && apt-get upgrade -y \
 # Upstream's packages; va-driver-all (Intel iHD/i965 and Mesa VA-API drivers for hardware video
 # transcoding), media-types (/etc/mime.types, used for content types such as .mp4/.heic) and
 # netbase were recommends that upstream got implicitly.
 && apt-get install -y --no-install-recommends libdlib19.1 ffmpeg exiftool libheif1 sqlite3 darktable \
      va-driver-all media-types netbase \
 && apt-get purge -y gnupg gpg \
 && apt-get autoremove -y \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

LABEL org.opencontainers.image.title="photoview (hardened)" \
      org.opencontainers.image.version="${HARDENED_VERSION}" \
      org.opencontainers.image.source="${HARDENED_SOURCE}" \
      org.opencontainers.image.description="Photoview ${UPSTREAM_VERSION} built from source with current Go, non-root" \
      org.opencontainers.image.licenses="AGPL-3.0" \
      org.photoview-hardened.upstream-version="${UPSTREAM_VERSION}" \
      org.photoview-hardened.upstream-revision="${UPSTREAM_SHA}"

WORKDIR /home/photoview
COPY api/data /app/data
COPY --from=ui /app/dist /app/ui
COPY --from=api /app/photoview /app/photoview

ENV PHOTOVIEW_LISTEN_IP=127.0.0.1
ENV PHOTOVIEW_LISTEN_PORT=80
ENV PHOTOVIEW_SERVE_UI=1
ENV PHOTOVIEW_UI_PATH=/app/ui
ENV PHOTOVIEW_FACE_RECOGNITION_MODELS_PATH=/app/data/models
ENV PHOTOVIEW_MEDIA_CACHE=/home/photoview/media-cache

EXPOSE ${PHOTOVIEW_LISTEN_PORT}

# Upstream's health check.
HEALTHCHECK --interval=60s --timeout=10s \
  CMD curl --fail http://localhost:${PHOTOVIEW_LISTEN_PORT}/api/graphql \
    -X POST -H 'Content-Type: application/json' \
    --data-raw '{"operationName":"CheckInitialSetup","variables":{},"query":"query CheckInitialSetup { siteInfo { initialSetup }}"}' \
    || exit 1

USER ${PHOTOVIEW_UID}:${PHOTOVIEW_GID}
ENTRYPOINT ["/app/photoview"]
