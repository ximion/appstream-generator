#!/bin/sh
set -e

echo "D compiler: $DC"
set -x
dub --version

#
# This script is supposed to run inside the AppStream Generator Docker container
# on the CI system.
#

# Build with dub
dub build --parallel -v

# Build with Meson
mkdir -p build && cd build
meson ..
ninja

# Run tests
./asgen_test

# Test (Meson) install
DESTDIR=/tmp/install-ninja ninja install
cd ..

# Test getting JS stuff and installing (dub)
make js
make install DESTDIR=/tmp/install-tmp
