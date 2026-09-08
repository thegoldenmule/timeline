#!/bin/sh
set -eu
cd "$(dirname "$0")"
make lint
make test
