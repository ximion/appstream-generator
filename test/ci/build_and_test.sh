#!/bin/sh
#
# This script is supposed to run inside the AppStream Generator Docker container
# on the CI system.
#
set -e

echo "D compiler: $DC"
set -v
$DC --version
dub --version
meson --version

#
# Build with Meson
#
mkdir -p build && cd build
meson ..
ninja

# Run tests
./asgen_test

# Test (Meson) install
DESTDIR=/tmp/install-ninja ninja install
cd ..

#
# Build with dub
#
dub build --parallel -v --compiler=$DC

# Test getting JS stuff and installing
make js
make install DESTDIR=/tmp/install-tmp
