IMAGE := golang:1.26-bookworm@sha256:a688600ca24f8a4d3ca77f95b0dd40704a9fc787c826660eb7ba0b641b8b175d
GO_VERSION := 1.26.8
# SHA-256 of https://go.dev/dl/go$(GO_VERSION).src.tar.gz, the source of the patched darwin_amd64 toolchain.
GO_SRC_SHA256 := 4e39b98e42f946fa05ac8bc5b71877df97dbdb7cbb1a777b541667ad7117fd2e
CPA_VERSION := 7.3.15
PLUGIN := quota-reset-router
VERSION := $(shell sed -n 's/^const pluginVersion = "\(.*\)"/\1/p' config.go)
TARGETS := linux_amd64 linux_arm64 darwin_amd64 darwin_arm64 windows_amd64

TARGET ?= linux_amd64
TARGET_OS := $(word 1,$(subst _, ,$(TARGET)))
TARGET_ARCH := $(word 2,$(subst _, ,$(TARGET)))
EXT := $(if $(filter windows,$(TARGET_OS)),dll,$(if $(filter darwin,$(TARGET_OS)),dylib,so))
LIB := dist/$(TARGET)/$(PLUGIN).$(EXT)
ZIP := dist/release/$(PLUGIN)_$(VERSION)_$(TARGET).zip
CPA_ARCH := $(if $(filter arm64,$(TARGET_ARCH)),aarch64,$(TARGET_ARCH))
CPA_ASSET := CLIProxyAPI_$(CPA_VERSION)_$(TARGET_OS)_$(CPA_ARCH).$(if $(filter windows,$(TARGET_OS)),zip,tar.gz)
CPA_URL := https://github.com/router-for-me/CLIProxyAPI/releases/download/v$(CPA_VERSION)
# Stock Go on darwin/amd64 keeps g in TSD slot 6, which CLIProxyAPI's own runtime already uses, so darwin_amd64 is built and tested with scripts/go-tls-slot.patch. The _ prefix keeps the toolchain's Go sources out of ./... patterns.
TLS_GO := dist/_go-tls/go/bin/go
ifeq ($(TARGET),darwin_amd64)
TOOLCHAIN := $(TLS_GO)
GO := GOTOOLCHAIN=local $(CURDIR)/$(TLS_GO)
DARWIN_GO := $(GO)
else
GO := go
DARWIN_GO := GOTOOLCHAIN=go$(GO_VERSION) go
endif
# -buildvcs=false: output depends only on the sources, and git in the build container rejects the mounted checkout's owner.
GO_BUILD := -trimpath -buildvcs=false -buildmode=c-shared -ldflags="-s -w"
CHECKS := test -z "$$(gofmt -l $$(find . -path ./dist -prune -o -name "*.go" -print) | tee /dev/stderr)" && $(GO) vet ./... && $(GO) test -race -count=1 ./...
# THIRD_PARTY_NOTICES.md names this runtime version, so the Windows build fails if the image installs another.
MINGW_VERSION := 10.0.0-3
# macOS 12 is the oldest release Go 1.26 supports. Passed as CGO flags because the Go build cache ignores MACOSX_DEPLOYMENT_TARGET.
MACOS_MIN := -mmacosx-version-min=12.0

docker = docker run --rm --platform linux/$(1) -v "$(CURDIR):/src" -v $(PLUGIN)-go-mod:/go/pkg/mod -v $(PLUGIN)-go-build-$(1):/root/.cache/go-build -w /src
ISOLATED := --network none --add-host api.anthropic.com:127.0.0.1 --add-host chatgpt.com:127.0.0.1 -e PLUGIN_ISOLATED_TEST=1
LINUX_ONLY = $(if $(filter linux,$(TARGET_OS)),,$(error $@ loads the plugin in a Linux container; set TARGET to linux_amd64 or linux_arm64))

ifeq ($(filter $(TARGET),$(TARGETS)),)
$(error TARGET must be one of: $(TARGETS))
endif

.PHONY: test linux-test build zip checksums release-assets native-test host-test load-test cpa version clean

test: $(TOOLCHAIN)
	$(CHECKS)

linux-test:
	$(call docker,$(TARGET_ARCH)) $(IMAGE) sh -c '$(CHECKS)'

# Linux and Windows builds run in the pinned image; macOS builds need a macOS host.
build: $(TOOLCHAIN)
	mkdir -p dist/$(TARGET)
ifeq ($(TARGET_OS),linux)
	$(call docker,$(TARGET_ARCH)) $(IMAGE) sh -c 'CGO_ENABLED=1 go build $(GO_BUILD) -o $(LIB) .'
else ifeq ($(TARGET_OS),windows)
	$(call docker,amd64) $(IMAGE) sh -c '\
		apt-get update -qq && \
		apt-get install -y -qq --no-install-recommends gcc-mingw-w64-x86-64-win32 >/dev/null && \
		test "$$(dpkg-query -W mingw-w64-x86-64-dev | cut -f2)" = $(MINGW_VERSION) && \
		CC=x86_64-w64-mingw32-gcc-win32 CGO_ENABLED=1 GOOS=windows GOARCH=amd64 go build $(GO_BUILD) -o $(LIB) .'
else
	CGO_ENABLED=1 GOOS=darwin GOARCH=$(TARGET_ARCH) CGO_CFLAGS="-O2 -g $(MACOS_MIN)" CGO_LDFLAGS="$(MACOS_MIN)" \
		$(DARWIN_GO) build $(GO_BUILD) -o $(LIB) .
endif
ifeq ($(TARGET),darwin_amd64)
# A stock-toolchain library would crash CLIProxyAPI, so fail unless every g access uses slot 11 (%gs:0x58).
	otool -tv $(LIB) | awk '/%gs:0x30/ {stock++} /%gs:0x58/ {patched++} \
		END {printf "g accesses: slot 11 x%d, slot 6 x%d\n", patched, stock; exit !(patched && !stock)}'
endif

# Go $(GO_VERSION) from checksum-verified source plus scripts/go-tls-slot.patch, bootstrapped by stock Go $(GO_VERSION).
$(TLS_GO): scripts/go-tls-slot.patch
	rm -rf dist/_go-tls
	mkdir -p dist/_go-tls
	curl -fsSL -o dist/_go-tls/src.tar.gz https://go.dev/dl/go$(GO_VERSION).src.tar.gz
	echo "$(GO_SRC_SHA256)  dist/_go-tls/src.tar.gz" | shasum -a 256 -c -
	tar -xzf dist/_go-tls/src.tar.gz -C dist/_go-tls
	patch -d dist/_go-tls/go -p1 < scripts/go-tls-slot.patch
	cd dist/_go-tls/go/src && GOROOT_BOOTSTRAP="$$(GOTOOLCHAIN=go$(GO_VERSION) go env GOROOT)" ./make.bash

zip:
	python3 scripts/package_release.py zip $(VERSION) $(TARGET)

checksums:
	python3 scripts/package_release.py checksums $(VERSION)

# Builds every target; needs a macOS host with Docker.
release-assets:
	for target in $(TARGETS); do $(MAKE) build zip TARGET=$$target || exit 1; done
	$(MAKE) checksums

native-test:
	$(LINUX_ONLY)
	$(call docker,$(TARGET_ARCH)) $(ISOLATED) -e SSL_CERT_FILE=/tmp/quota-router-fixture.pem $(IMAGE) python3 tests/native_smoke.py $(LIB)

# On macOS this runs on the host, so it needs the fixture setup from .github/workflows/ci.yml; TARGET must match the machine.
host-test: cpa
ifeq ($(TARGET_OS),darwin)
	python3 tests/host_smoke.py dist/cpa/$(CPA_ASSET) dist/cpa/checksums.txt $(LIB)
else ifeq ($(TARGET_OS),linux)
	$(call docker,$(TARGET_ARCH)) --cpus 1 --memory 384m --memory-swap 384m $(ISOLATED) $(IMAGE) python3 tests/host_smoke.py dist/cpa/$(CPA_ASSET) dist/cpa/checksums.txt $(LIB)
else
	$(error host-test needs a linux or darwin TARGET)
endif

# Runs on this machine, so TARGET must match it.
load-test: cpa
	python3 tests/load_smoke.py dist/cpa/$(CPA_ASSET) dist/cpa/checksums.txt $(ZIP)

cpa:
	mkdir -p dist/cpa
	test -f dist/cpa/checksums.txt || curl -fsSL -o dist/cpa/checksums.txt $(CPA_URL)/checksums.txt
	test -f dist/cpa/$(CPA_ASSET) || curl -fsSL -o dist/cpa/$(CPA_ASSET) $(CPA_URL)/$(CPA_ASSET)

version:
	@echo $(VERSION)

clean:
	rm -rf dist coverage.out
