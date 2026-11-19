# photoview-hardened

Rebuilds [Photoview](https://github.com/photoview/photoview) release tags from source the way upstream's Dockerfile
does, but with the newest stable Go and bumped Go modules, runtime packages installed without "recommends" and
upgraded, and a fixed non-root uid. Each build is gated on a Trivy scan and a smoke test, and the result is published
to `ghcr.io/rmonk/photoview`. Drop-in for `photoview/photoview:2`: same binary, UI, paths, environment, port and
health check.

No fork: each build clones upstream at the tag in `UPSTREAM_VERSION` and builds it with `overlay/Dockerfile`.

## Why

- Upstream compiles with Debian 12's own `golang` package (Go 1.19), and the release (v2.4.0, June 2024) locks
  2024-era modules (`x/crypto` 0.22, `x/net` 0.24, `x/image` 0.15, `pgx` 5.5.5). `photoview/photoview:2` is rebuilt
  for new base packages, but from the same code.
- Upstream installs runtime packages with recommends, which pulls in printing and desktop extras (avahi, polkit,
  udev, SANE, ghostscript, python3, and `ipp-usb`, another Go 1.19 binary).

At v2.4.0 (tested 2026-11-19): Trivy went from 30 critical / 625 high to 21 / 496, with **none fixable**. What remains
is Debian 12's ffmpeg/libav, OpenEXR, libsoup and similar, with no fix released. The image is about 280 MB smaller.

## What gets changed

| | Upstream image | Hardened |
|---|---|---|
| `photoview` binary | Go 1.19 (Debian 12 `golang`), modules from the release | newest stable Go (`golang:<v>-bookworm`), modules in `overlay/go-bumps.txt` raised to latest (same major); same cgo build (dlib face recognition, sqlite, libheif) and go-face `-march=native` patch |
| Runtime packages | `apt-get install` with recommends | `--no-install-recommends` plus `va-driver-all` (VA-API drivers for hardware video), `media-types` and `netbase`, then `apt-get upgrade`; rebuilt weekly |
| User | `photoview`, uid 999 | `photoview`, uid/gid **8082** |

Upstream's UI build (node from upstream's Dockerfile), darktable from the openSUSE OBS repository, the paths, env
defaults (`PHOTOVIEW_LISTEN_PORT=80`, ...) and the health check are unchanged.

Not bumped on purpose: `github.com/vektah/gqlparser/v2` (must match the gqlgen-generated code) and
`github.com/strukturag/libheif` (the Go binding must match Debian's C libheif).

## Running it

```yaml
image: ghcr.io/rmonk/photoview:latest-hardened     # runs as 8082:8082
cap_drop: [ALL]
security_opt: [no-new-privileges:true]
read_only: true
tmpfs: [/tmp]
sysctls:
  net.ipv4.ip_unprivileged_port_start: "0"   # bind port 80 without CAP_NET_BIND_SERVICE (Docker sets this by default; podman doesn't)
devices:
  - /dev/dri:/dev/dri                        # optional, hardware video transcoding (VA-API)
volumes:
  - database:/home/photoview/database        # must be writable by 8082
  - cache:/home/photoview/media-cache        # must be writable by 8082
  - /path/to/photos:/photos:ro
```

Moving from upstream's image (or from `user: root`), once, with the container stopped: `chown -R 8082:8082` the
database and cache volumes on the host. The photos only need to be readable.

## Tags

- `latest-hardened`: newest successful build of the current `UPSTREAM_VERSION`
- `<upstream>-hardened`, e.g. `v2.4.0-hardened`
- `<upstream>-hardened-<YYYYMMDD>`: immutable, use this to pin or roll back

amd64 only.

## Automation

- `build.yml`: runs on push/PR, manually, and weekly (Mon 07:07 UTC). It runs prepare, then build, then the Trivy
  gate (fixable CRITICAL/HIGH fail the build; exceptions go in `.trivyignore.yaml`, scoped to a package URL with a
  reason and an expiry date), then the smoke test, then pushes Docker v2 manifests (podman ignores HEALTHCHECK in OCI
  images) on main only. If the `HC_PING_URL` secret is set, a successful run pings it.
- `watch-upstream.yml`: runs daily. When Photoview publishes a new release, it opens a PR that bumps
  `UPSTREAM_VERSION` and dispatches the build on that branch. Merge it when it is green.

## Keeping in step with upstream

Our Dockerfile replaces upstream's, so `scripts/prepare.sh` checks anchors in upstream's tree at the tag (UI build,
build dependencies, the go-face patch, the API build, runtime base and packages, the darktable repository, copied
paths, env, health check, entrypoint, and the cgo dependencies in `go.mod`). If one is missing, the build fails
instead of shipping something that only looks right. Then compare upstream's `Dockerfile` with `overlay/Dockerfile`.

## Smoke test

`scripts/smoke-test.sh` starts the image the way futomaki runs it (uid 8082, no capabilities, `no-new-privileges`,
read-only root, tmpfs `/tmp`, the unprivileged-port sysctl, sqlite, fresh volumes, photos read-only) and checks:
- uid 8082; ffmpeg (with VA-API), the VA drivers, `mime.types`, exiftool and darktable-cli; no `ipp-usb`
- the setup wizard and login; a scan of a JPEG, a PNG, a short video and a real HEIC (fixture made with `heif-enc`)
- every item gets a thumbnail in the media cache, served over HTTP
- a recreate keeps the user and media; the image's health check passes; no panics or permission errors

## Local build

```bash
scripts/prepare.sh
podman build --format docker -f build/src/Dockerfile.hardened $(sed 's/^/--build-arg /' build/build-args) \
  -t photoview:hardened build/src      # --format docker: OCI images drop HEALTHCHECK
DOCKER=podman scripts/smoke-test.sh photoview:hardened
```
