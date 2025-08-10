#!/bin/sh
#
# This script is supposed to run inside the AppStream Generator Docker container
# on the CI system.
#
set -e
export LANG=C.UTF-8

ROOT_DIR=$(pwd)

echo "C compiler: $CC"
echo "C++ compiler: $CXX"
set -v
$CXX --version
meson --version

#
# Build & Test
#
mkdir -p build && cd build
meson setup -Ddownload-js=true ..
ninja -j8

# Run tests
meson test -v --print-errorlogs

# Test install
DESTDIR=/tmp/install-ninja ninja install
cd $ROOT_DIR
