#!/usr/bin/env bash
set -euo pipefail

image="${1:-hof-nginx:local}"
network="hof-nginx-test-$$"
upstream="hof-nginx-upstream-$$"
proxy="hof-nginx-proxy-$$"
whitelist="hof-nginx-whitelist-$$"
environment_rules="hof-nginx-env-rules-$$"
redirect="hof-nginx-redirect-$$"
tls_upstream="hof-nginx-tls-upstream-$$"
untrusted_upstream="hof-nginx-untrusted-upstream-$$"
mismatched_upstream="hof-nginx-mismatched-upstream-$$"
rules_volume="hof-nginx-rules-$$"
body="$(mktemp)"
cert="$(mktemp)"

cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        for container in "$proxy" "$whitelist" "$environment_rules" "$redirect" "$tls_upstream" "$untrusted_upstream" "$mismatched_upstream" "$upstream"; do
            if docker container inspect "$container" >/dev/null 2>&1; then
                docker logs "$container" >&2 || true
            fi
        done
    fi
    docker rm -f "$proxy" "$whitelist" "$environment_rules" "$redirect" "$tls_upstream" "$untrusted_upstream" "$mismatched_upstream" "$upstream" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    docker volume rm "$rules_volume" >/dev/null 2>&1 || true
    rm -f "$body" "$cert"
}
trap cleanup EXIT

wait_for_proxy() {
    local port="$1"
    for _ in {1..30}; do
        if curl -fsS "http://127.0.0.1:$port/ping" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

port_for() {
    local address
    address="$(docker port "$1" "$2/tcp")"
    printf '%s\n' "${address##*:}"
}

docker network create "$network" >/dev/null
docker run -d --name "$upstream" --network "$network" --entrypoint /bin/sh "$image" -c '
    cat > /tmp/upstream.conf <<EOF
pid /tmp/upstream.pid;
error_log /dev/stderr;
events {}
http {
    access_log /dev/stdout;
    server {
        listen 8080;
        location = /s403 { return 403; }
        location = /s404 { return 404; }
        location = /s500 { return 500; }
        location = /s502 { return 502; }
        location = /s503 { return 503; }
        location = /s504 { return 504; }
        location / { return 200 "proxy-ok"; }
    }
}
EOF
    exec nginx -e /dev/stderr -c /tmp/upstream.conf -g "daemon off;"
' >/dev/null

docker run -d --name "$proxy" --network "$network" --network-alias test \
    -p 127.0.0.1::10080 -p 127.0.0.1::10443 \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
http_port="$(port_for "$proxy" 10080)"
https_port="$(port_for "$proxy" 10443)"
wait_for_proxy "$http_port"

test "$(docker exec "$proxy" id -u)" = 1000
docker exec "$proxy" nginx -e /dev/stderr -t
test "$(curl -fsS "http://127.0.0.1:$http_port/")" = proxy-ok
test "$(curl -kfsS "https://127.0.0.1:$https_port/")" = proxy-ok
curl -fsS "http://127.0.0.1:$http_port/nginx-proxy/style/app.css" >/dev/null

for code in 403 404 500 502 503 504; do
    status="$(curl -sS -o "$body" -w '%{http_code}' "http://127.0.0.1:$http_port/s$code")"
    test "$status" = "$code"
    grep -q 'GOV.UK' "$body"
    grep -q "<h2>$code " "$body"
    if grep -q '<!--#' "$body"; then
        echo "Error page $code contains unprocessed SSI directives" >&2
        exit 1
    fi
done

status="$(curl -sS -o "$body" -w '%{http_code}' "http://127.0.0.1:$http_port/nginx-proxy/missing")"
test "$status" = 404
grep -q '<h1>Page not found</h1>' "$body"

attack='?a=%3Cscript%3Ealert%281%29%3C%2Fscript%3E'
status="$(curl -sS -o "$body" -w '%{http_code}' "http://127.0.0.1:$http_port/$attack")"
test "$status" = 418
grep -q 'GOV.UK' "$body"

docker volume create "$rules_volume" >/dev/null
docker run --rm --user 0:0 --entrypoint /bin/sh -v "$rules_volume:/rules" "$image" \
    -c 'printf "%s\n" '"'"'BasicRule wl:0 "mz:$ARGS_VAR:a";'"'"' > /rules/whitelist.rules'
docker run -d --name "$whitelist" --network "$network" -p 127.0.0.1::10080 \
    -v "$rules_volume:/etc/nginx/naxsi.d:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
whitelist_port="$(port_for "$whitelist" 10080)"
wait_for_proxy "$whitelist_port"
test "$(curl -fsS "http://127.0.0.1:$whitelist_port/$attack")" = proxy-ok

docker run -d --name "$environment_rules" --network "$network" -p 127.0.0.1::10080 \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e 'EXTRA_NAXSI_RULES=BasicRule wl:0 "mz:$ARGS_VAR:a";' \
    "$image" >/dev/null
environment_port="$(port_for "$environment_rules" 10080)"
wait_for_proxy "$environment_port"
test "$(curl -fsS "http://127.0.0.1:$environment_port/$attack")" = proxy-ok

docker run --rm --user 0:0 --entrypoint /bin/sh -v "$rules_volume:/rules" "$image" \
    -c 'printf "%s\n" "invalid directive;" > /rules/invalid.rules'
if output="$(docker run --rm --network "$network" \
    -v "$rules_volume:/etc/nginx/naxsi.d:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 "$image" 2>&1)"; then
    echo "Expected startup to fail with invalid mounted rules" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -q 'nginx: \[emerg\]'

docker run -d --name "$redirect" --network "$network" -p 127.0.0.1::10080 \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 "$image" >/dev/null
redirect_port="$(port_for "$redirect" 10080)"
wait_for_proxy "$redirect_port"
test "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$redirect_port/example")" = 301
test "$(curl -sS -o /dev/null -w '%{redirect_url}' "http://127.0.0.1:$redirect_port/example")" = 'https://127.0.0.1/example'

docker cp "$proxy:/etc/keys/crt" "$cert"
chmod 644 "$cert"
docker run -d --name "$tls_upstream" --network "$network" -p 127.0.0.1::10080 \
    -v "$cert:/etc/ssl/certs/ca-certificates.crt:ro" \
    -e PROXY_SERVICE_HOST=https://test -e PROXY_SERVICE_PORT=10443 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
tls_port="$(port_for "$tls_upstream" 10080)"
wait_for_proxy "$tls_port"
test "$(curl -fsS "http://127.0.0.1:$tls_port/")" = proxy-ok

docker run -d --name "$untrusted_upstream" --network "$network" -p 127.0.0.1::10080 \
    -e PROXY_SERVICE_HOST=https://test -e PROXY_SERVICE_PORT=10443 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
untrusted_port="$(port_for "$untrusted_upstream" 10080)"
wait_for_proxy "$untrusted_port"
test "$(curl -sS -o "$body" -w '%{http_code}' "http://127.0.0.1:$untrusted_port/")" = 502

docker run -d --name "$mismatched_upstream" --network "$network" -p 127.0.0.1::10080 \
    -v "$cert:/etc/ssl/certs/ca-certificates.crt:ro" \
    -e PROXY_SERVICE_HOST="https://$proxy" -e PROXY_SERVICE_PORT=10443 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
mismatched_port="$(port_for "$mismatched_upstream" 10080)"
wait_for_proxy "$mismatched_port"
test "$(curl -sS -o "$body" -w '%{http_code}' "http://127.0.0.1:$mismatched_port/")" = 502

for setting in ALLOW_COUNTRY_CSV_2=GB DENY_COUNTRY_ON_2=TRUE LOCATIONS_CSV=/ \
    'EXTRA_NAXSI_RULES_2=BasicRule wl:0;' 'EXTRA_NAXSI_RULES=invalid directive;' \
    PROXY_SERVICE_HOST='bad;host'; do
    if output="$(docker run --rm --network "$network" \
        -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
        -e "$setting" "$image" 2>&1)"; then
        echo "Expected startup to fail with invalid setting $setting" >&2
        exit 1
    fi
    printf '%s\n' "$output" | grep -Eq 'ERROR:|nginx: \[emerg\]'
done

docker run --rm --entrypoint /bin/sh "$image" -c \
    'test ! -e /usr/local/bin/geoipupdate && ! apk info -e libmaxminddb-libs >/dev/null'
echo "Smoke tests passed for $image"
