.DEFAULT_GOAL := help

IMAGE ?= hof-nginx:local
HTTP_PORT ?= 10080
HTTPS_PORT ?= 10443
HTTPS_REDIRECT ?= FALSE

export IMAGE HTTP_PORT HTTPS_PORT HTTPS_REDIRECT PROXY_SERVICE_HOST PROXY_SERVICE_PORT

.PHONY: help build test run scan

help:
	@printf '%s\n' \
	  'make build  Build the local image' \
	  'make test   Build and run the smoke tests' \
	  'make run    Build and run against PROXY_SERVICE_HOST and PROXY_SERVICE_PORT' \
	  'make scan   Build and scan with local Trivy'

build:
	docker build -t "$$IMAGE" .

test: build
	bash tests/smoke.sh "$$IMAGE"

run: build
	@: "$${PROXY_SERVICE_HOST:?Set PROXY_SERVICE_HOST to the upstream host}"
	@: "$${PROXY_SERVICE_PORT:?Set PROXY_SERVICE_PORT to the upstream port}"
	docker run --rm \
	  -p "127.0.0.1:$$HTTP_PORT:10080" -p "127.0.0.1:$$HTTPS_PORT:10443" \
	  -e PROXY_SERVICE_HOST -e PROXY_SERVICE_PORT -e HTTPS_REDIRECT \
	  -e "HTTPS_REDIRECT_PORT=$$HTTPS_PORT" "$$IMAGE"

scan: build
	trivy image --scanners vuln --pkg-types os,library --dependency-tree \
	  --severity MEDIUM,HIGH,CRITICAL --ignorefile /dev/null \
	  --exit-code 1 "$$IMAGE"
