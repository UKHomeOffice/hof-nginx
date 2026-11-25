# hof-nginx

An Alpine-based reverse proxy using Alpine's native NGINX and NAXSI packages.
It does not use OpenResty, GeoIP or either of the retired proxy images. This
is a new, specification-first implementation, not a drop-in replacement for
the old proxy. Service migration and Home Office security and branding approval
are still required before production use.

The base is pinned to an Alpine 3.24 image digest for reproducibility. The
build upgrades Alpine packages and installs NGINX, NAXSI, OpenSSL, CA
certificates and `envsubst`. It runs as UID 1000 and listens on unprivileged
ports 10080 (HTTP) and 10443 (HTTPS). The NGINX Alpine package supplies NAXSI's
core rules. The inherited GOV.UK error pages cover 403, 404, 500, 502, 503 and
504, including errors returned by the upstream. These are GOV.UK assets from
the former image; whether they meet current Home Office branding requirements
needs confirmation.

## Build and test

From this directory, with Docker running and GNU Make installed:

```sh
make help   # List local commands
make build  # Build hof-nginx:local
make test   # Build and run smoke tests
```

`make scan` builds and scans the image using a locally installed Trivy.
These commands do not push an image. Set `IMAGE=your-tag` on a make command
to use a different local image tag.

The smoke test creates temporary containers, a Docker network and a volume,
then removes them. It checks non-root startup, HTTP and HTTPS proxying, TLS
upstream verification, error pages, NAXSI blocking and rule overrides, and
invalid configuration. Test each service's real configuration and traffic
separately before migration.

To run against an existing upstream reachable from Docker Desktop, replace
the host and port with your upstream:

```sh
make run PROXY_SERVICE_HOST=http://host.docker.internal PROXY_SERVICE_PORT=8080
```

This builds the image, binds ports 10080 and 10443 on localhost, and runs in
the foreground with HTTPS redirection disabled for local testing. If those
host ports are already in use, add `HTTP_PORT=18080 HTTPS_PORT=18443` to the
command and use those ports in the curl examples. Set `HTTPS_REDIRECT=TRUE`
to test redirects to the configured HTTPS host port instead.

In another terminal:

```sh
curl -i http://localhost:10080/ping
curl -i http://localhost:10080/
curl -ki https://localhost:10443/
```

`/ping` is a liveness check only; it does not check the upstream. The `/`
request requires a running upstream. Stop the container with Ctrl-C.

## Configuration

| Variable | Description |
| --- | --- |
| `PROXY_SERVICE_HOST` | Required upstream hostname or IP, optionally prefixed with `http://` or `https://`; no path or port. HTTP is the default. |
| `PROXY_SERVICE_PORT` | Required upstream port, 1–65535. |
| `HTTP_LISTEN_PORT`, `HTTPS_LISTEN_PORT` | Container ports; default 10080 and 10443. |
| `HTTPS_REDIRECT` | `TRUE` (default) redirects HTTP requests to HTTPS; `FALSE` allows HTTP proxying. `/ping` and error assets are not redirected. |
| `HTTPS_REDIRECT_PORT` | Optional external HTTPS port to include in redirects. |
| `SERVER_CERT`, `SERVER_KEY` | Certificate and private-key paths; default `/etc/keys/crt` and `/etc/keys/key`. |
| `NAME_RESOLVER` | DNS server IP, optionally with a port. Defaults to the first nameserver in `/etc/resolv.conf`. |
| `EXTRA_NAXSI_RULES` | Additional NAXSI directives, applied to the proxy location. |

NGINX starts only if its generated configuration passes `nginx -t`. Upstream
HTTPS verifies the server certificate and hostname using the system CA bundle,
and sends SNI. For a private CA, provide a complete trusted CA bundle at
`/etc/ssl/certs/ca-certificates.crt`. The proxy forwards the host without its
port and adds standard `X-Forwarded-*` headers. It appends the connection's
address to any client-supplied `X-Forwarded-For` value; configure the upstream
to trust forwarded addresses only from known proxies. `X-Real-IP` is the
immediate peer's address, which may be a load balancer.

Mount a real server certificate and key readable by UID 1000 for production. If
both default files are absent, the container generates a self-signed
certificate **for testing only**. Custom or partially mounted certificate
paths must exist and be readable. `curl -k` is appropriate only for testing.
If TLS is terminated by an external load balancer, configure redirects at the
load balancer or disable `HTTPS_REDIRECT` to avoid redirect loops.

## NAXSI rules

NAXSI core rules and blocking thresholds are enabled for proxied requests.
Pass service-specific rules already maintained in `hof-services-config` via
the deployment's `EXTRA_NAXSI_RULES` environment variable, or mount `.rules`
files in `/etc/nginx/naxsi.d/`. Rules must be valid in an NGINX location
context; malformed rules fail startup. Restart or roll out containers after
changing rules so that NGINX loads and validates the new configuration.
Only trusted deployment administrators should be able to modify these rules:
they can change WAF protection. Review and test each service's rules against
real traffic before rollout. `/ping` and `/nginx-proxy/` are not WAF protected.

## Migrating from the retired images

This image supports one upstream location. Multiple locations and per-location
variables, GeoIP and country filtering, OpenResty/Lua and UUID injection,
StatsD, arbitrary NGINX config injection, basic authentication, rate limiting,
client certificates, upstream client certificates and downloadable NAXSI rules
are not implemented. Several legacy settings fail startup instead of being
silently ignored; other old settings are not recognised. Review all service
configuration rather than assuming old variables still work. The old JSON log
format and its fields are not preserved; standard NGINX access logs include
the request URI and query string. WebSocket behaviour is not part of this
implementation. The old `/readyness` endpoint is not provided.

These features do not depend on Alpine's version: native NGINX can support
multiple locations, rate limiting, mutual TLS and WebSockets, but this image
does not configure them. Check whether each service requires them and provide
equivalent protection or functionality before migration. For example,
`LOCATIONS_CSV`, `ADD_NGINX_SERVER_CFG` and `CLIENT_CERT_REQUIRED` cause startup
to fail when set; other unsupported legacy variables can be ignored.

Error responses from the upstream are replaced by the corresponding branded
pages for the six configured statuses. Validate this change with services that
need application-specific error responses.

## Vulnerability scanning and dependency updates

The GitHub Actions build, scan and publishing workflow is deferred to a
separate ticket. This branch does not publish images or send Slack
notifications. Run `make test` and `make scan` locally in the meantime, and
put the required automated checks in place before a production release.

[Dependabot](.github/dependabot.yml) checks the Alpine base image daily and
GitHub Actions dependencies weekly, following `hof-nodejs`. It can propose
base-image digest and non-major version updates; Alpine major upgrades remain
manual. The configuration takes effect after it is merged to the default
branch. Review and test dependency updates before merging.

Dependabot does not update Alpine packages installed by `apk`. Review those
separately. There is currently no scheduled image build. Trivy scans Alpine
packages for known vulnerabilities, not all malicious packages.

To scan locally without an allow list:

```sh
trivy image --scanners vuln --pkg-types os,library --dependency-tree \
  --severity MEDIUM,HIGH,CRITICAL --ignorefile /dev/null \
  --exit-code 1 hof-nginx:local
```

Vulnerability results change as databases and Alpine packages change. To
remediate findings, review the advisory, update the pinned Alpine version and
digest when needed, rebuild without cache, run tests and scans for both
architectures, and deploy a newly published image through the approved release
process. If no fix is available, follow the team's risk acceptance process; do
not silently suppress findings. Local scans do not automatically scan deployed
image digests or perform Quay scans.

The copied GOV.UK assets retain their upstream notices in [licenses/](licenses/).
