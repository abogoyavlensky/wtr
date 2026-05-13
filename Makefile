.PHONY: help test

LG ?= /Users/andrew/Projects/let-go/lg
LGX ?= LGX_LG=$(LG) lgx

TEST_FILES := $(wildcard test/wtr/*_test.lg)

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  %-12s %s\n", $$1, $$2}'

test:  ## Run all test suites
	@for f in $(TEST_FILES); do \
	  echo "==> $$f"; \
	  $(LGX) run $$f || exit 1; \
	done
