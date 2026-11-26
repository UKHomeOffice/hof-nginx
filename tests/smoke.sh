#!/usr/bin/env bash
set -euo pipefail

image="${1:-hof-nginx:local}"
localhost_ip="$(docker run --rm --entrypoint getent "$image" ahostsv4 localhost | awk 'NR == 1 {print $1}')"
localhost_ipv6="$(docker run --rm --entrypoint getent "$image" ahostsv6 localhost | awk 'NR == 1 {print $1}')"
: "${localhost_ip:?Unable to resolve IPv4 localhost}"
: "${localhost_ipv6:?Unable to resolve IPv6 localhost}"
network="hof-nginx-test-$$"
upstream="hof-nginx-upstream-$$"
proxy="hof-nginx-proxy-$$"
limited_proxy="hof-nginx-limited-proxy-$$"
trusted_proxy="hof-nginx-trusted-proxy-$$"
json_proxy="hof-nginx-json-proxy-$$"
body_log_proxy="hof-nginx-body-log-proxy-$$"
text_log_proxy="hof-nginx-text-log-proxy-$$"
enhanced_proxy="hof-nginx-enhanced-proxy-$$"
optional_assets_proxy="hof-nginx-optional-assets-proxy-$$"
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
missing_public_dir="$(mktemp -d)"
chmod 755 "$public_dir"
chmod 755 "$missing_public_dir"
mkdir "$public_dir/css" "$public_dir/images"
mkdir "$missing_public_dir/css" "$missing_public_dir/images"
printf 'public-asset-ok' > "$public_dir/test.txt"
printf 'test-css' > "$public_dir/css/app.css"
printf 'test-logo' > "$public_dir/images/govuk-logo.svg"
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
        for container in "$proxy" "$limited_proxy" "$trusted_proxy" "$json_proxy" "$body_log_proxy" "$text_log_proxy" "$enhanced_proxy" "$optional_assets_proxy" "$whitelist" "$environment_rules" "$redirect" "$tls_upstream" "$untrusted_upstream" "$mismatched_upstream" "$upstream"; do
            if docker container inspect "$container" >/dev/null 2>&1; then
                docker logs "$container" >&2 || true
            fi
        done
    fi
    docker rm -f "$proxy" "$limited_proxy" "$trusted_proxy" "$json_proxy" "$body_log_proxy" "$text_log_proxy" "$enhanced_proxy" "$optional_assets_proxy" "$whitelist" "$environment_rules" "$redirect" "$tls_upstream" "$untrusted_upstream" "$mismatched_upstream" "$upstream" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    docker volume rm "$rules_volume" >/dev/null 2>&1 || true
    rm -f "$body" "$cert" "$public_dir/test.txt" \
        "$public_dir/css/app.css" "$public_dir/images/govuk-logo.svg" \
        "$missing_public_dir/css/app.css" "$missing_public_dir/images/govuk-logo.svg"
    rmdir "$public_dir/css" "$public_dir/images" "$public_dir"
    rmdir "$missing_public_dir/css" "$missing_public_dir/images" "$missing_public_dir"
}
trap cleanup EXIT

wait_for_proxy() {
    local port="$1"
    for _ in {1..30}; do
        if curl -fsS "http://${localhost_ip}:$port/ping" >/dev/null 2>&1; then
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
        location = /s403 { return 403 "upstream-403"; }
        location = /s404 { return 404 "upstream-404"; }
        location = /s429 { return 429 "upstream-429"; }
        location = /s500 { return 500 "upstream-500"; }
        location = /s501 { return 501 "upstream-501"; }
        location = /s502 { return 502 "upstream-502"; }
        location = /s503 { return 503 "upstream-503"; }
        location = /s504 { return 504 "upstream-504"; }
        location = /headers { return 200 "\$http_x_custom_header"; }
        location = /upgrade { return 200 "\$server_protocol|\$http_upgrade|\$http_connection"; }
        location / { return 200 "proxy-ok"; }
    }
}
EOF
    exec nginx -e /dev/stderr -c /tmp/upstream.conf -g "daemon off;"
' >/dev/null

docker run -d --name "$proxy" --network "$network" --network-alias test \
    -p "$localhost_ip::10080" -p "$localhost_ip::10443" \
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
test "$(curl -fsS "http://${localhost_ip}:$http_port/")" = proxy-ok
test "$(curl -kfsS "https://${localhost_ip}:$https_port/")" = proxy-ok
test "$(curl -fsS -H 'X_Custom_Header: header-ok' "http://${localhost_ip}:$http_port/headers")" = header-ok
test "$(curl -fsS -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
    "http://${localhost_ip}:$http_port/upgrade")" = 'HTTP/1.1|websocket|upgrade'
test "$(curl -fsS "http://${localhost_ip}:$http_port/upgrade")" = 'HTTP/1.1||close'
curl -fsS "http://${localhost_ip}:$http_port/nginx-proxy/403.shtml" > "$body"
grep -Fq 'class="govuk-template govuk-template--rebranded"' "$body"
grep -Fq 'href="/public/css/app.css"' "$body"
grep -Fq 'src="/public/images/govuk-logo.svg"' "$body"
if grep -Fq 'govuk-header__service-name' "$body"; then
    echo "Unexpected service name on the proxy error page" >&2
    exit 1
fi
grep -Fq 'href="/cookies"' "$body"
grep -Fq 'href="/terms-and-conditions"' "$body"
grep -Fq 'href="/accessibility"' "$body"
test "$(curl -fsS "http://${localhost_ip}:$http_port/public/css/app.css")" = test-css
test "$(curl -fsS "http://${localhost_ip}:$http_port/public/images/govuk-logo.svg")" = test-logo
curl -fsS "http://${localhost_ip}:$http_port/nginx-proxy/418.shtml" > "$body"
grep -q 'fact, a teapot' "$body"
if grep -Fq '/nginx-proxy/images/teapot.png' "$body"; then
    echo "The 418 page references the removed teapot image" >&2
    exit 1
fi
test "$(curl -fsS "http://${localhost_ip}:$http_port/public/test.txt")" = public-asset-ok
curl -fsSI "http://${localhost_ip}:$http_port/public/test.txt" |
    grep -qi '^Cache-Control: max-age=86400'

docker run -d --name "$json_proxy" --network "$network" -p "$localhost_ip::10080" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e ACCESS_LOG_FORMAT=extended_json "$image" >/dev/null
json_port="$(port_for "$json_proxy" 10080)"
wait_for_proxy "$json_port"
curl -fsS -A 'test"agent' --data-binary 'test-body-sample' \
    "http://${localhost_ip}:$json_port/json-log" >/dev/null
json_log="$(docker logs "$json_proxy" 2>/dev/null | grep -F '"request_uri": "/json-log"')"
printf '%s\n' "$json_log" | grep -Fq '"http_user_agent": "test\"agent"'
printf '%s\n' "$json_log" | grep -Fq '"server_port": "10080"'
if printf '%s\n' "$json_log" | grep -Eq 'request_body|test-body-sample|response_body'; then
    echo "Unexpected body in default JSON log" >&2
    exit 1
fi

docker run -d --name "$body_log_proxy" --network "$network" -p "$localhost_ip::10080" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e ACCESS_LOG_FORMAT=extended_json \
    -e LOG_REQUEST_BODY=TRUE "$image" >/dev/null
body_log_port="$(port_for "$body_log_proxy" 10080)"
wait_for_proxy "$body_log_port"
curl -fsS --data-binary 'test-body-sample' \
    "http://${localhost_ip}:$body_log_port/body-log" >/dev/null
body_log="$(docker logs "$body_log_proxy" 2>/dev/null | grep -F '"request_uri": "/body-log"')"
printf '%s\n' "$body_log" | grep -Fq '"request_body": "test-body-sample"'
if printf '%s\n' "$body_log" | grep -Fq 'response_body'; then
    echo "Unexpected response body in JSON log" >&2
    exit 1
fi

docker run -d --name "$text_log_proxy" --network "$network" -p "$localhost_ip::10080" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e ACCESS_LOG_FORMAT=extended_text \
    -e LOG_REQUEST_BODY=TRUE "$image" >/dev/null
text_log_port="$(port_for "$text_log_proxy" 10080)"
wait_for_proxy "$text_log_port"
curl -fsS --data-binary 'test-body-sample' \
    "http://${localhost_ip}:$text_log_port/text-log" >/dev/null
text_log="$(docker logs "$text_log_proxy" 2>/dev/null | grep -F 'POST /text-log')"
printf '%s\n' "$text_log" | grep -Fq '"test-body-sample"'

docker run -d --name "$limited_proxy" --network "$network" -p "$localhost_ip::10080" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e RATE_LIMIT_ENABLED=TRUE \
    -e REQS_PER_MIN_PER_IP=1 -e RATE_LIMIT_BURST=0 "$image" >/dev/null
limited_port="$(port_for "$limited_proxy" 10080)"
wait_for_proxy "$limited_port"
test "$(curl -sS -o /dev/null -w '%{http_code}' "http://${localhost_ip}:$limited_port/ping")" = 200
test "$(curl -fsS -o /dev/null -w '%{http_code}' "http://${localhost_ip}:$limited_port/")" = 200
test "$(curl -sS -o "$body" -w '%{http_code}' "http://${localhost_ip}:$limited_port/")" = 429
grep -q '<h2 class="govuk-heading-m">429 Too many requests</h2>' "$body"
test "$(curl -sS -o /dev/null -w '%{http_code}' "http://${localhost_ip}:$limited_port/ping")" = 200
curl -fsS "http://${localhost_ip}:$limited_port/nginx-proxy/429.shtml" >/dev/null
test "$(curl -fsS "http://${localhost_ip}:$limited_port/public/css/app.css")" = test-css
test "$(curl -fsS "http://${localhost_ip}:$limited_port/public/images/govuk-logo.svg")" = test-logo

upstream_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$upstream")"
proxy_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$proxy")"
limited_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$limited_proxy")"
json_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$json_proxy")"
body_log_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$body_log_proxy")"
text_log_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$text_log_proxy")"
test "$(docker exec "$upstream" curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-Forwarded-For: $body_log_ip" "http://$limited_proxy:10080/untrusted")" = 200
test "$(docker exec "$upstream" curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-Forwarded-For: $text_log_ip" "http://$limited_proxy:10080/untrusted")" = 429

docker run -d --name "$trusted_proxy" --network "$network" -p "$localhost_ip::10080" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e RATE_LIMIT_ENABLED=TRUE \
    -e REQS_PER_MIN_PER_IP=1 -e RATE_LIMIT_BURST=0 -e ACCESS_LOG_FORMAT=extended_json \
    -e "TRUSTED_PROXY_CIDRS=$upstream_ip/32,$json_ip/32,$localhost_ipv6/128" "$image" >/dev/null
trusted_port="$(port_for "$trusted_proxy" 10080)"
wait_for_proxy "$trusted_port"
test "$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-Forwarded-For: $body_log_ip" "http://${localhost_ip}:$trusted_port/untrusted")" = 200
test "$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-Forwarded-For: $text_log_ip" "http://${localhost_ip}:$trusted_port/untrusted")" = 429
test "$(docker exec "$upstream" curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-Forwarded-For: $body_log_ip, $json_ip" "http://$trusted_proxy:10080/trusted")" = 200
test "$(docker exec "$upstream" curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-Forwarded-For: $body_log_ip, $json_ip" "http://$trusted_proxy:10080/trusted")" = 429
test "$(docker exec "$upstream" curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-Forwarded-For: $text_log_ip, $json_ip" "http://$trusted_proxy:10080/trusted")" = 200
test "$(docker exec "$upstream" curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-Forwarded-For: $limited_ip, $proxy_ip, $json_ip" "http://$trusted_proxy:10080/trusted")" = 200
test "$(docker exec "$upstream" curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-Forwarded-For: $body_log_ip, $proxy_ip, $json_ip" "http://$trusted_proxy:10080/trusted")" = 429
test "$(docker exec "$upstream" curl -sS -o /dev/null -w '%{http_code}' \
    "http://$trusted_proxy:10080/no-forwarded-header")" = 200
test "$(docker exec "$upstream" curl -sS -o /dev/null -w '%{http_code}' \
    -H 'X-Forwarded-For: invalid' "http://$trusted_proxy:10080/no-forwarded-header")" = 429
docker logs "$trusted_proxy" 2>/dev/null | grep -F '"request_uri": "/trusted"' |
    grep -Fq "\"remote_addr\": \"$body_log_ip\""
docker logs "$trusted_proxy" 2>/dev/null | grep -F '"request_uri": "/no-forwarded-header"' |
    grep -Fq "\"remote_addr\": \"$upstream_ip\""

for code in 403 404 429 500 501 502 503 504; do
    status="$(curl -sS -o "$body" -w '%{http_code}' "http://${localhost_ip}:$http_port/s$code")"
    test "$status" = "$code"
    test "$(cat "$body")" = "upstream-$code"
    curl -fsS "http://${localhost_ip}:$http_port/nginx-proxy/$code.shtml" > "$body"
    grep -q 'GOV.UK' "$body"
    grep -q "<h2 class=\"govuk-heading-m\">$code " "$body"
    if grep -q '<!--#' "$body"; then
        echo "Error page $code contains unprocessed SSI directives" >&2
        exit 1
    fi
done

status="$(curl -sS -o "$body" -w '%{http_code}' "http://${localhost_ip}:$http_port/nginx-proxy/missing")"
test "$status" = 404
grep -q '<h1 class="govuk-heading-xl">Page not found</h1>' "$body"

attack='?a=%3Cscript%3Ealert%281%29%3C%2Fscript%3E'
status="$(curl -sS -o "$body" -w '%{http_code}' "http://${localhost_ip}:$http_port/$attack")"
test "$status" = 418
grep -q 'GOV.UK' "$body"
grep -q 'support@example.org' "$body"

docker run -d --name "$enhanced_proxy" --network "$network" -p "$localhost_ip::10080" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e GZIP_ENABLED=TRUE -e VERBOSE_ERROR_PAGES=TRUE \
    "$image" >/dev/null
enhanced_port="$(port_for "$enhanced_proxy" 10080)"
wait_for_proxy "$enhanced_port"
status="$(curl -sS -o "$body" -w '%{http_code}' "http://${localhost_ip}:$enhanced_port/$attack")"
test "$status" = 418
grep -q 'ORIG URL:' "$body"
grep -q 'Generated at' "$body"
curl -sS -H 'Accept-Encoding: gzip' -o /dev/null -D "$body" \
    "http://${localhost_ip}:$enhanced_port/nginx-proxy/404.shtml"
grep -qi '^Content-Encoding: gzip' "$body"
curl -sS -H 'Accept-Encoding: gzip' -o /dev/null -D "$body" \
    "http://${localhost_ip}:$http_port/nginx-proxy/404.shtml"
if grep -qi '^Content-Encoding: gzip' "$body"; then
    echo "Gzip unexpectedly enabled by default" >&2
    exit 1
fi

docker volume create "$rules_volume" >/dev/null
docker run --rm --user 0:0 --entrypoint /bin/sh -v "$rules_volume:/rules" "$image" \
    -c 'printf "%s\n" '"'"'BasicRule wl:0 "mz:$ARGS_VAR:a";'"'"' > /rules/whitelist.rules'
docker run -d --name "$whitelist" --network "$network" -p "$localhost_ip::10080" \
    -v "$rules_volume:/etc/nginx/naxsi.d:ro" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
whitelist_port="$(port_for "$whitelist" 10080)"
wait_for_proxy "$whitelist_port"
test "$(curl -fsS "http://${localhost_ip}:$whitelist_port/$attack")" = proxy-ok

docker run -d --name "$environment_rules" --network "$network" -p "$localhost_ip::10080" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE -e 'EXTRA_NAXSI_RULES=BasicRule wl:0 "mz:$ARGS_VAR:a";' \
    "$image" >/dev/null
environment_port="$(port_for "$environment_rules" 10080)"
wait_for_proxy "$environment_port"
test "$(curl -fsS "http://${localhost_ip}:$environment_port/$attack")" = proxy-ok

docker run --rm --user 0:0 --entrypoint /bin/sh -v "$rules_volume:/rules" "$image" \
    -c 'printf "%s\n" "invalid directive;" > /rules/invalid.rules'
if output="$(docker run --rm --network "$network" \
    -v "$rules_volume:/etc/nginx/naxsi.d:ro" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 "$image" 2>&1)"; then
    echo "Expected startup to fail with invalid mounted rules" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -q 'nginx: \[emerg\]'

docker run -d --name "$redirect" --network "$network" -p "$localhost_ip::10080" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 "$image" >/dev/null
redirect_port="$(port_for "$redirect" 10080)"
wait_for_proxy "$redirect_port"
test "$(curl -sS -o /dev/null -w '%{http_code}' "http://${localhost_ip}:$redirect_port/example")" = 301
test "$(curl -sS -o /dev/null -w '%{redirect_url}' "http://${localhost_ip}:$redirect_port/example")" = "https://${localhost_ip}/example"

docker cp "$proxy:/etc/keys/crt" "$cert"
chmod 644 "$cert"
docker run -d --name "$tls_upstream" --network "$network" -p "$localhost_ip::10080" \
    -v "$cert:/etc/ssl/certs/ca-certificates.crt:ro" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST=https://test -e PROXY_SERVICE_PORT=10443 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
tls_port="$(port_for "$tls_upstream" 10080)"
wait_for_proxy "$tls_port"
test "$(curl -fsS "http://${localhost_ip}:$tls_port/")" = proxy-ok

docker run -d --name "$untrusted_upstream" --network "$network" -p "$localhost_ip::10080" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST=https://test -e PROXY_SERVICE_PORT=10443 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
untrusted_port="$(port_for "$untrusted_upstream" 10080)"
wait_for_proxy "$untrusted_port"
test "$(curl -sS -o "$body" -w '%{http_code}' "http://${localhost_ip}:$untrusted_port/")" = 502
grep -q '<h2 class="govuk-heading-m">502 Bad gateway</h2>' "$body"

docker run -d --name "$mismatched_upstream" --network "$network" -p "$localhost_ip::10080" \
    -v "$cert:/etc/ssl/certs/ca-certificates.crt:ro" \
    -v "$public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="https://$proxy" -e PROXY_SERVICE_PORT=10443 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
mismatched_port="$(port_for "$mismatched_upstream" 10080)"
wait_for_proxy "$mismatched_port"
test "$(curl -sS -o "$body" -w '%{http_code}' "http://${localhost_ip}:$mismatched_port/")" = 502

for setting in ALLOW_COUNTRY_CSV_2=GB DENY_COUNTRY_ON_2=TRUE LOCATIONS_CSV=/ \
    'EXTRA_NAXSI_RULES_2=BasicRule wl:0;' REQS_PER_MIN_PER_IP=0 \
    REQS_PER_MIN_PER_IP=2147483648 RATE_LIMIT_BURST=-1 REQS_PER_MIN_PER_IP_2=10 \
    RATE_LIMIT_ENABLED=invalid ACCESS_LOG_FORMAT=invalid LOG_REQUEST_BODY=invalid \
    GZIP_ENABLED=invalid VERBOSE_ERROR_PAGES=invalid FEEDBACK_EMAIL='bad;value' \
    TRUSTED_PROXY_CIDRS=invalid "TRUSTED_PROXY_CIDRS=$upstream_ip," \
    "TRUSTED_PROXY_CIDRS=$upstream_ip/999" \
    "TRUSTED_PROXY_CIDRS=$upstream_ip;return 200" \
    "TRUSTED_PROXY_CIDRS=$upstream_ip
return 200;" \
    LOG_REQUEST_BODY=TRUE \
    'ADD_NGINX_SERVER_CFG=invalid directive;' \
    'EXTRA_NAXSI_RULES=invalid directive;' \
    PROXY_SERVICE_HOST='bad;host'; do
    if output="$(docker run --rm --network "$network" \
        -v "$public_dir:/public:ro" \
        -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
        -e "$setting" "$image" 2>&1)"; then
        echo "Expected startup to fail with invalid setting $setting" >&2
        exit 1
    fi
    printf '%s\n' "$output" | grep -Eq 'ERROR:|nginx: \[emerg\]'
done

docker run -d --name "$optional_assets_proxy" --network "$network" \
    -p "$localhost_ip::10080" -v "$missing_public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
optional_assets_port="$(port_for "$optional_assets_proxy" 10080)"
wait_for_proxy "$optional_assets_port"
docker rm -f "$optional_assets_proxy" >/dev/null

: > "$missing_public_dir/css/app.css"
: > "$missing_public_dir/images/govuk-logo.svg"
docker run -d --name "$optional_assets_proxy" --network "$network" \
    -p "$localhost_ip::10080" -v "$missing_public_dir:/public:ro" \
    -e PROXY_SERVICE_HOST="$upstream" -e PROXY_SERVICE_PORT=8080 \
    -e HTTPS_REDIRECT=FALSE "$image" >/dev/null
optional_assets_port="$(port_for "$optional_assets_proxy" 10080)"
wait_for_proxy "$optional_assets_port"

docker run --rm --entrypoint /bin/sh "$image" -c \
    'test ! -e /usr/local/bin/geoipupdate && ! apk info -e libmaxminddb-libs >/dev/null'
echo "Smoke tests passed for $image"
