#!/bin/sh
#
# This script is supposed to run inside the AppStream Generator Docker container
# on the CI system.
#
set -e
export LANG=C.UTF-8

echo "D compiler: $DC"
set -v
$DC --version
meson --version

#
# Build & Test
#
mkdir -p build && cd build
meson -Ddownload-js=true ..
ninja

# Run tests
./asgen_test

# Test install
DESTDIR=/tmp/install-ninja ninja install
cd ..
