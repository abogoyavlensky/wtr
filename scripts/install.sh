#!/usr/bin/env bash

VERSION=0.1.0
OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # linux | darwin
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -sSL -o wtr.tar.gz \
  "https://github.com/abogoyavlensky/wtr/releases/download/v${VERSION}/wtr_${VERSION}_${OS}_${ARCH}.tar.gz"
tar -xzf wtr.tar.gz
mv wtr ~/.local/bin/
