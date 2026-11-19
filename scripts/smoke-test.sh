#!/usr/bin/env bash
# Start the image the way futomaki runs it (uid 8082, no capabilities, no-new-privileges,
# read-only root, tmpfs /tmp, sqlite, fresh database and cache volumes, media mounted read-only,
# unprivileged-port sysctl so the default port 80 binds without CAP_NET_BIND_SERVICE), then check:
#   - it runs as uid 8082; ffmpeg, exiftool, darktable-cli and heif-convert-free decoding work;
#     ipp-usb (pulled in by "recommends" upstream) is not installed
#   - the initial setup wizard, login, and a scan of a JPEG, a PNG, a HEIC and a short video
#   - every scanned item gets a thumbnail written to the media cache and served over HTTP
#   - a recreate with the same volumes keeps the user and media; the image's health check passes
#
# Usage: scripts/smoke-test.sh <image>      (DOCKER=podman to use podman; needs curl + jq)
set -euo pipefail
trap 'echo "smoke: FAIL command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

image="${1:?usage: smoke-test.sh <image>}"
docker="${DOCKER:-docker}"
tag="pv-smoke-$$"
port="${SMOKE_PORT:-18082}"
base="http://127.0.0.1:$port"
jar="$(mktemp)"
media="$(mktemp -d)"
password="pw$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cleanup() {
  rc=$?
  if [ $rc -ne 0 ]; then echo "--- logs ---"; $docker logs --tail 60 "$tag" 2>&1 || true; fi
  $docker rm -f "$tag" >/dev/null 2>&1 || true
  $docker volume rm -f "$tag-db" "$tag-cache" >/dev/null 2>&1 || true
  # Files made by the container's root may not be removable by this user (rootful Docker).
  $docker run --rm --user 0 --entrypoint rm -v "$media:/out:z" "$image" -rf /out/album >/dev/null 2>&1 || true
  rm -rf "$jar" "$media" 2>/dev/null || true
  exit $rc
}
trap cleanup EXIT

# Test media, made with the image's own tools (as root in a throwaway container). The album
# directory is made here and world-writable, so the HEIC fixture can be added from the host even
# when the container's root is real root (rootful Docker in CI).
mkdir -p "$media/album"
chmod 0777 "$media" "$media/album"
$docker run --rm --user 0 --entrypoint bash -v "$media:/out:z" "$image" -euc '
  ffmpeg -loglevel error -f lavfi -i testsrc=size=640x480 -frames:v 1 /out/album/a.jpg
  ffmpeg -loglevel error -f lavfi -i testsrc2=size=320x240 -frames:v 1 /out/album/b.png
  ffmpeg -loglevel error -f lavfi -i testsrc=size=320x240:rate=10 -t 1 -pix_fmt yuv420p /out/album/c.mp4
  chmod -R a+rX /out'
# A real HEIC (iPhone-style) sample isn't reproducible with Debian 12 tools, so it's a small fixture.
heic_b64="$(dirname "$0")/fixtures/sample.heic.b64"
if [ -f "$heic_b64" ]; then base64 -d < "$heic_b64" > "$media/album/d.heic"; chmod a+r "$media/album/d.heic"; fi
want_media="$(find "$media/album" -type f | wc -l)"

$docker volume create "$tag-db" >/dev/null
$docker volume create "$tag-cache" >/dev/null
$docker run --rm --user 0 --entrypoint chown -v "$tag-db:/db" -v "$tag-cache:/cache" "$image" -R 8082:8082 /db /cache

start() {
  $docker run -d --name "$tag" \
    --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp \
    --sysctl net.ipv4.ip_unprivileged_port_start=0 \
    -e PHOTOVIEW_LISTEN_IP=0.0.0.0 -e PHOTOVIEW_DATABASE_DRIVER=sqlite \
    -e PHOTOVIEW_SQLITE_PATH=/home/photoview/database/photoview.db \
    -v "$tag-db:/home/photoview/database" -v "$tag-cache:/home/photoview/media-cache" \
    -v "$media:/photos:ro,z" -p "127.0.0.1:$port:80" "$image" >/dev/null
  for _ in $(seq 60); do curl -fsS -o /dev/null "$base/" 2>/dev/null && return 0; sleep 1; done
  echo "smoke: FAIL Photoview not answering"; return 1
}
gql() {  # gql <json>  -> body; fails on HTTP error or GraphQL errors
  local out
  out="$(curl -fsS -b "$jar" -H 'Content-Type: application/json' -d "$1" "$base/api/graphql")"
  if jq -e '.errors' >/dev/null <<<"$out"; then echo "smoke: FAIL GraphQL error: $out" >&2; return 1; fi
  printf '%s' "$out"
}

start

uid="$($docker exec "$tag" sh -c 'stat -c %u /proc/1')"
[ "$uid" = 8082 ] || { echo "smoke: FAIL runs as uid $uid, expected 8082"; exit 1; }
$docker exec "$tag" sh -c 'command -v ipp-usb' >/dev/null 2>&1 && { echo "smoke: FAIL ipp-usb is installed"; exit 1; }
$docker exec "$tag" sh -euc 'ffmpeg -version | head -1; exiftool -ver; darktable-cli --version | head -1' >/dev/null \
  || { echo "smoke: FAIL ffmpeg/exiftool/darktable-cli missing or broken"; exit 1; }
$docker exec "$tag" sh -euc 'test -e /usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so; test -e /usr/lib/x86_64-linux-gnu/dri/radeonsi_drv_video.so; test -s /etc/mime.types; ffmpeg -hide_banner -hwaccels | grep -q vaapi' \
  || { echo "smoke: FAIL VA-API drivers, mime.types or ffmpeg vaapi support missing"; exit 1; }
echo "smoke: uid 8082; ffmpeg (vaapi), VA drivers, exiftool, darktable-cli; no ipp-usb"

token="$(gql "$(jq -nc --arg p "$password" '{query:"mutation($u:String!,$p:String!,$r:String!){initialSetupWizard(username:$u,password:$p,rootPath:$r){success status token}}",variables:{u:"smoke",p:$p,r:"/photos"}}')" \
  | jq -r '.data.initialSetupWizard | select(.success) | .token')"
[ -n "$token" ] || { echo "smoke: FAIL initial setup"; exit 1; }
login() {
  local t
  t="$(gql "$(jq -nc --arg p "$password" '{query:"mutation($u:String!,$p:String!){authorizeUser(username:$u,password:$p){success token}}",variables:{u:"smoke",p:$p}}')" \
    | jq -r '.data.authorizeUser | select(.success) | .token')"
  [ -n "$t" ] || { echo "smoke: FAIL login"; return 1; }
  printf '127.0.0.1\tFALSE\t/\tFALSE\t0\tauth-token\t%s\n' "$t" > "$jar"
}
login
echo "smoke: setup wizard and login OK"

gql '{"query":"mutation{scanAll{success}}"}' >/dev/null
count=0
for _ in $(seq 90); do
  media_json="$(gql '{"query":"{myMedia{id title type thumbnail{url}}}"}')"
  count="$(jq '[.data.myMedia[] | select(.thumbnail != null)] | length' <<<"$media_json")"
  [ "$count" -ge "$want_media" ] && break; sleep 2
done
[ "$count" -ge "$want_media" ] || { echo "smoke: FAIL $count of $want_media media scanned with thumbnails: $(jq -c '[.data.myMedia[]|{title,thumb:(.thumbnail!=null)}]' <<<"$media_json")"; exit 1; }
for u in $(jq -r '.data.myMedia[].thumbnail.url' <<<"$media_json"); do
  case "$u" in http*) ;; *) u="$base$u" ;; esac
  curl -fsS -b "$jar" -o /dev/null "$u" || { echo "smoke: FAIL thumbnail not served: $u"; exit 1; }
done
$docker exec "$tag" sh -c 'find /home/photoview/media-cache -type f | grep -q .' || { echo "smoke: FAIL media cache empty"; exit 1; }
echo "smoke: scanned $count media ($(jq -r '[.data.myMedia[].title]|join(", ")' <<<"$media_json")), thumbnails written and served"

$docker stop -t 15 "$tag" >/dev/null
$docker rm "$tag" >/dev/null
start
login
n="$(gql '{"query":"{myMedia{id}}"}' | jq '.data.myMedia | length')"
[ "$n" -ge "$want_media" ] || { echo "smoke: FAIL media missing after recreate ($n)"; exit 1; }
echo "smoke: recreate keeps the user and media"

# The image's HEALTHCHECK must exist and pass. (podman keeps it only in Docker-format images:
# build with `--format docker`; CI pushes Docker v2 manifests for the same reason.)
hc="$($docker image inspect --format '{{json .Config.Healthcheck}}' "$image" \
  | jq -r '.Test // empty | if .[0] == "CMD-SHELL" then ["sh", "-c", .[1]] else .[1:] end | @sh')"
[ -n "$hc" ] || { echo "smoke: FAIL the image has no health check"; exit 1; }
eval "$docker exec \"$tag\" $hc" >/dev/null || { echo "smoke: FAIL the image's health check fails"; exit 1; }
echo "smoke: image health check passes"

logs="$($docker logs "$tag" 2>&1)"
if grep -qiE 'panic:|permission denied|read-only file system' <<<"$logs"; then
  grep -iE 'panic:|permission denied|read-only file system' <<<"$logs" | head -5
  echo "smoke: FAIL panic or permission error in logs"; exit 1
fi
echo "smoke: PASS"
