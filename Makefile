SHELL := /bin/bash
SCRIPT := safe-upgrade.sh
IMAGES ?= debian:12 debian:13 ubuntu:22.04 ubuntu:24.04 ubuntu:26.04

.PHONY: help lint test integration check

help:
	@echo "make lint         bash -n + shellcheck"
	@echo "make test         bats unit + CLI tests (needs bats)"
	@echo "make integration  end-to-end tests in Docker (IMAGES='$(IMAGES)')"
	@echo "make check        lint + test"
	@echo "Offline integration run: make integration SKIP_REAL_APT=1"

lint:
	bash -n $(SCRIPT)
	shellcheck --severity=warning $(SCRIPT) \
	  tests/integration/container-test.sh \
	  tests/integration/systemd-test.sh \
	  contrib/hooks/pre-upgrade-snapshot.sh

test:
	bats --print-output-on-failure tests/unit.bats tests/cli.bats tests/hooks.bats

integration:
	for image in $(IMAGES); do \
	  echo "=== $$image ==="; \
	  docker run --rm -e SKIP_REAL_APT -v "$$PWD:/src:ro" "$$image" bash -c \
	    'printf "#!/bin/sh\nexit 101\n" > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d && \
	     apt-get update -qq && apt-get install -y -qq ca-certificates util-linux >/dev/null && \
	     bash /src/tests/integration/container-test.sh' || exit 1; \
	done

check: lint test
