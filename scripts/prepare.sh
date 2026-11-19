#!/usr/bin/env bash
# Set up the hardened build context for photoview at the pinned upstream version.
# Result: build/src (Docker context: upstream source + hardening/) with
# build/src/Dockerfile.hardened, and build/build-args (KEY=VALUE lines for --build-arg).
#
# Our Dockerfile replaces upstream's, so it depends on how upstream builds and lays out its
# image. The anchors below are read from upstream's tree at the same tag; if any is missing,
# upstream changed its image and overlay/Dockerfile must be reviewed before the build can go on.
#
# Usage: scripts/prepare.sh [upstream-version]   (default: contents of UPSTREAM_VERSION)
# Needs: git, curl, jq.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="${1:-$(tr -d '[:space:]' < "$root/UPSTREAM_VERSION")}"
src="$root/build/src"
upstream_repo="${UPSTREAM_REPO:-https://github.com/photoview/photoview.git}"

rm -rf "$root/build"
mkdir -p "$root/build"
git clone --quiet --depth 1 --branch "$ref" "$upstream_repo" "$src" 2>/dev/null
sha="$(git -C "$src" rev-parse HEAD)"
echo "prepare: upstream $ref @ ${sha:0:12}"
rm -rf "$src/.git" "$src/.github"

fail() { echo "prepare: $*" >&2; echo "prepare: upstream changed its image; review overlay/Dockerfile." >&2; exit 1; }
need() {  # need <description> <file> <extended regex>: must occur exactly once
  local n
  [ -f "$src/$2" ] || fail "anchor '$1': $2 is missing"
  n="$(grep -cE "$3" "$src/$2" || true)"
  [ "$n" = 1 ] || fail "anchor '$1' matched $n times in $2 (expected 1)"
}

need "UI stage on node"              Dockerfile '^FROM --platform=\$\{BUILDPLATFORM:-linux/amd64\} node:[0-9]+ as ui$'
need "UI build"                      Dockerfile 'npm ci --omit=dev --ignore-scripts'
need "API build deps script"         Dockerfile '^COPY docker/install_build_dependencies\.sh /tmp/$'
need "go-face -march patch"          Dockerfile "sed -i 's/-march=native//g'"
need "API build"                     Dockerfile 'go build -v -o photoview \.$'
need "runtime base"                  Dockerfile '^FROM debian:bookworm-slim$'
need "runtime packages"              Dockerfile 'apt-get install -y curl gnupg gpg libdlib19\.1 ffmpeg exiftool libheif1 sqlite3'
need "darktable repo"                Dockerfile 'download\.opensuse\.org/repositories/graphics:/darktable/Debian_12/ /'
need "api data copied"               Dockerfile '^COPY api/data /app/data$'
need "ui copied"                     Dockerfile '^COPY --from=ui /app/dist /app/ui$'
need "media cache env"               Dockerfile '^ENV PHOTOVIEW_MEDIA_CACHE /home/photoview/media-cache$'
need "health check query"            Dockerfile 'CheckInitialSetup'
need "entrypoint"                    Dockerfile '^ENTRYPOINT \["/app/photoview"\]$'
need "build deps list"               docker/install_build_dependencies.sh 'libdlib-dev:\$\{DEBIAN_ARCH\}'
need "go-face dependency"            api/go.mod 'github\.com/Kagami/go-face '
need "sqlite3 dependency"            api/go.mod 'github\.com/mattn/go-sqlite3 '

node_major="$(sed -nE 's/^FROM --platform=\$\{BUILDPLATFORM:-linux\/amd64\} node:([0-9]+) as ui$/\1/p' "$src/Dockerfile")"
go_version="$(curl -fsS 'https://go.dev/dl/?mode=json' | jq -r '[.[] | select(.stable)][0].version' | sed 's/^go//')"
for v in node_major go_version; do
  [ -n "${!v}" ] || { echo "prepare: could not determine $v" >&2; exit 1; }
done
echo "prepare: node $node_major (upstream's), go $go_version"

mkdir -p "$src/hardening"
cp "$root/overlay/go-bump.sh" "$root/overlay/go-bumps.txt" "$src/hardening/"
cp "$root/overlay/Dockerfile" "$src/Dockerfile.hardened"

cat > "$root/build/build-args" <<ARGS
NODE_IMAGE=docker.io/library/node:$node_major
GO_IMAGE=docker.io/library/golang:$go_version-bookworm
RUNTIME_IMAGE=docker.io/library/debian:bookworm-slim
UPSTREAM_VERSION=$ref
UPSTREAM_SHA=$sha
BUILD_DATE=$(date -u +%Y-%m-%d)
ARGS
echo "prepare: build context ready at $src"
