#!/usr/bin/env bash
set -euo pipefail

image="${1:-hof-nginx:local}"
network="hof-nginx-test-$$"
upstream="hof-nginx-upstream-$$"
proxy="hof-nginx-proxy-$$"
system_resolved_proxy="hof-nginx-system-resolved-proxy-$$"
limited_proxy="hof-nginx-limited-proxy-$$"
json_proxy="hof-nginx-json-proxy-$$"
body_log_proxy="hof-nginx-body-log-proxy-$$"
text_log_proxy="hof-nginx-text-log-proxy-$$"
enhanced_proxy="hof-nginx-enhanced-proxy-$$"
whitelist="hof-nginx-whitelist-$$"
environment_rules="hof-nginx-env-rules-$$"
redirect="hof-nginx-redirect-$$"
tls_upstream="hof-nginx-tls-upstream-$$"
untrusted_upstream="hof-nginx-untrusted-upstream-$$"
mismatched_upstream="hof-nginx-mismatched-upstream-$$"
rules_volume="hof-nginx-rules-$$"
body="$(mktemp)"
cert="$(mktemp)"
public_dir="$(mktemp -d)"
chmod 755 "$public_dir"
printf 'public-asset-ok' > "$public_dir/test.txt"
server_config='
add_header Cache-Control private;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options nosniff always;
add_header X-XSS-Protection "1; mode=block" always;
location /public {
    add_header Cache-Control max-age=86400;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    alias /public;
}
'

cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        for container in "$proxy" "$system_resolved_proxy" "$limited_proxy" "$json_proxy" "$body_log_proxy" "$text_log_proxy" "$enhanced_proxy" "$whitelist" "$environment_rules" "$redirect" "$tls_upstream" "$untrusted_upstream" "$mismatched_upstream" "$upstream"; do
            if docker container inspect "$container" >/dev/null 2>&1; then
                docker logs "$container" >&2 || true
            fi
        done
    fi
    docker rm -f "$proxy" "$system_resolved_proxy" "$limited_proxy" "$json_proxy" "$body_log_proxy" "$text_log_proxy" "$enhanced_proxy" "$whitelist" "$environment_rules" "$redirect" "$tls_upstream" "$untrusted_upstream" "$mismatched_upstream" "$upstream" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    docker volume rm "$rules_volume" >/dev/null 2>&1 || true
    rm -f "$body" "$cert" "$public_dir/test.txt"
    rmdir "$public_dir"
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
    underscores_in_headers on;
    server {
        listen 8080;
        location = /s403 { return 403; }
        location = /s404 { return 404; }
        location = /s429 { return 429; }
        location = /s500 { return 500; }
        location = /s501 { return 501; }
        location = /s502 { return 502; }
        location = /s503 { return 503; }
        location = /s504 { return 504; }
        location = /headers { return 200 "\$http_x_custom_header"; }
        location = /upgrade { return 200 "\$server_protocol|\$http_upgrade|\$http_connection"; }
        location / { return 200 "proxy-ok"; }
    }
}
EOF
    exec nginx -e /dev/stderr -c /tmp/upstream.conf -g "daemon off;"
' >/dev/null

docker run -d --name "$proxy" --network "$network" --network-alias test \
    -p 127.0.0.1::10080 -p 127.0.0.1::10443 \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e REQS_PER_MIN_PER_IP=1 -e RATE_LIMIT_BURST=0 \
    -e FEEDBACK_EMAIL=support@example.org \
    -e "ADD_NGINX_SERVER_CFG=$server_config" "$image" >/dev/null
http_port="$(port_for "$proxy" 10080)"
https_port="$(port_for "$proxy" 10443)"
wait_for_proxy "$http_port"

test "$(docker exec "$proxy" id -u)" = 1000
docker exec "$proxy" nginx -e /dev/stderr -t
docker exec "$proxy" /healthcheck.sh
docker exec "$proxy" touch -t 200001010000 /run/nginx/nginx_reload.txt
health_output="$(docker exec -e NGINX_RELOAD_INTERVAL=1 "$proxy" /healthcheck.sh)"
printf '%s\n' "$health_output" | grep -q 'Validating and reloading NGINX'
test "$(docker exec "$proxy" stat -c %Y /run/nginx/nginx_reload.txt)" -gt 946684800
if docker exec -e NGINX_RELOAD_INTERVAL=invalid "$proxy" /healthcheck.sh >/dev/null 2>&1; then
    echo "Expected health check to reject invalid reload interval" >&2
    exit 1
fi
test "$(curl -fsS "http://127.0.0.1:$http_port/")" = proxy-ok
test "$(curl -kfsS "https://127.0.0.1:$https_port/")" = proxy-ok
upstream_ip="$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "$upstream")"
docker run -d --name "$system_resolved_proxy" --network "$network" \
    --add-host "upstream-host.test:$upstream_ip" -p 127.0.0.1::10080 \
    -e PROXY_SERVICE_HOST=upstream-host.test -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
system_resolved_port="$(port_for "$system_resolved_proxy" 10080)"
wait_for_proxy "$system_resolved_port"
test "$(curl -fsS "http://127.0.0.1:$system_resolved_port/")" = proxy-ok
test "$(curl -fsS -H 'X_Custom_Header: header-ok' "http://127.0.0.1:$http_port/headers")" = header-ok
test "$(curl -fsS -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
    "http://127.0.0.1:$http_port/upgrade")" = 'HTTP/1.1|websocket|upgrade'
test "$(curl -fsS "http://127.0.0.1:$http_port/upgrade")" = 'HTTP/1.1||close'
curl -fsS "http://127.0.0.1:$http_port/nginx-proxy/style/app.css" >/dev/null
curl -fsS "http://127.0.0.1:$http_port/nginx-proxy/style/govuk-template.css" > "$body"
asset_paths="$(grep -oE 'images/(govuk-crest|open-government-licence)[^)]*' "$body" | sort -u)"
test -n "$asset_paths"
while IFS= read -r asset; do
    curl -fsS "http://127.0.0.1:$http_port/nginx-proxy/style/$asset" >/dev/null
done <<< "$asset_paths"
test "$(curl -fsS "http://127.0.0.1:$http_port/public/test.txt")" = public-asset-ok
curl -fsSI "http://127.0.0.1:$http_port/public/test.txt" |
    grep -qi '^Cache-Control: max-age=86400'

docker run -d --name "$json_proxy" --network "$network" -p 127.0.0.1::10080 \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e ACCESS_LOG_FORMAT=extended_json "$image" >/dev/null
json_port="$(port_for "$json_proxy" 10080)"
wait_for_proxy "$json_port"
curl -fsS -A 'test"agent' --data-binary 'test-body-sample' \
    "http://127.0.0.1:$json_port/json-log" >/dev/null
json_log="$(docker logs "$json_proxy" 2>/dev/null | grep -F '"request_uri": "/json-log"')"
printf '%s\n' "$json_log" | grep -Fq '"http_user_agent": "test\"agent"'
printf '%s\n' "$json_log" | grep -Fq '"server_port": "10080"'
if printf '%s\n' "$json_log" | grep -Eq 'request_body|test-body-sample|response_body'; then
    echo "Unexpected body in default JSON log" >&2
    exit 1
fi

docker run -d --name "$body_log_proxy" --network "$network" -p 127.0.0.1::10080 \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e ACCESS_LOG_FORMAT=extended_json \
    -e LOG_REQUEST_BODY=TRUE "$image" >/dev/null
body_log_port="$(port_for "$body_log_proxy" 10080)"
wait_for_proxy "$body_log_port"
curl -fsS --data-binary 'test-body-sample' \
    "http://127.0.0.1:$body_log_port/body-log" >/dev/null
body_log="$(docker logs "$body_log_proxy" 2>/dev/null | grep -F '"request_uri": "/body-log"')"
printf '%s\n' "$body_log" | grep -Fq '"request_body": "test-body-sample"'
if printf '%s\n' "$body_log" | grep -Fq 'response_body'; then
    echo "Unexpected response body in JSON log" >&2
    exit 1
fi

docker run -d --name "$text_log_proxy" --network "$network" -p 127.0.0.1::10080 \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e ACCESS_LOG_FORMAT=extended_text \
    -e LOG_REQUEST_BODY=TRUE "$image" >/dev/null
text_log_port="$(port_for "$text_log_proxy" 10080)"
wait_for_proxy "$text_log_port"
curl -fsS --data-binary 'test-body-sample' \
    "http://127.0.0.1:$text_log_port/text-log" >/dev/null
text_log="$(docker logs "$text_log_proxy" 2>/dev/null | grep -F 'POST /text-log')"
printf '%s\n' "$text_log" | grep -Fq '"test-body-sample"'

docker run -d --name "$limited_proxy" --network "$network" -p 127.0.0.1::10080 \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e RATE_LIMIT_ENABLED=TRUE \
    -e REQS_PER_MIN_PER_IP=1 -e RATE_LIMIT_BURST=0 "$image" >/dev/null
limited_port="$(port_for "$limited_proxy" 10080)"
wait_for_proxy "$limited_port"
test "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$limited_port/ping")" = 200
test "$(curl -fsS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$limited_port/")" = 200
test "$(curl -sS -o "$body" -w '%{http_code}' "http://127.0.0.1:$limited_port/")" = 429
grep -q '<h2>429 Too many requests</h2>' "$body"
test "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$limited_port/ping")" = 200
curl -fsS "http://127.0.0.1:$limited_port/nginx-proxy/style/app.css" >/dev/null

for code in 403 404 429 500 501 502 503 504; do
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
grep -q 'support@example.org' "$body"

docker run -d --name "$enhanced_proxy" --network "$network" -p 127.0.0.1::10080 \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e GZIP_ENABLED=TRUE -e VERBOSE_ERROR_PAGES=TRUE \
    "$image" >/dev/null
enhanced_port="$(port_for "$enhanced_proxy" 10080)"
wait_for_proxy "$enhanced_port"
status="$(curl -sS -o "$body" -w '%{http_code}' "http://127.0.0.1:$enhanced_port/$attack")"
test "$status" = 418
grep -q 'ORIG URL:' "$body"
grep -q 'Generated at' "$body"
curl -sS -H 'Accept-Encoding: gzip' -o /dev/null -D "$body" \
    "http://127.0.0.1:$enhanced_port/s404"
grep -qi '^Content-Encoding: gzip' "$body"
curl -sS -H 'Accept-Encoding: gzip' -o /dev/null -D "$body" \
    "http://127.0.0.1:$http_port/s404"
if grep -qi '^Content-Encoding: gzip' "$body"; then
    echo "Gzip unexpectedly enabled by default" >&2
    exit 1
fi

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
    'EXTRA_NAXSI_RULES_2=BasicRule wl:0;' REQS_PER_MIN_PER_IP=0 \
    REQS_PER_MIN_PER_IP=2147483648 RATE_LIMIT_BURST=-1 REQS_PER_MIN_PER_IP_2=10 \
    RATE_LIMIT_ENABLED=invalid ACCESS_LOG_FORMAT=invalid LOG_REQUEST_BODY=invalid \
    GZIP_ENABLED=invalid VERBOSE_ERROR_PAGES=invalid FEEDBACK_EMAIL='bad;value' \
    LOG_REQUEST_BODY=TRUE \
    'ADD_NGINX_SERVER_CFG=invalid directive;' \
    'EXTRA_NAXSI_RULES=invalid directive;' \
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
