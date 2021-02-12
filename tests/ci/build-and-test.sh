#!/bin/sh
#
# This script is supposed to run inside the AppStream Generator Docker container
# on the CI system.
#
set -e
export LANG=C.UTF-8

if [ "$DC" = "ldc" ];
then
  export DC=ldc2
fi
ROOT_DIR=$(pwd)

echo "D compiler: $DC"
set -v
$DC --version
meson --version

#
# Build & Test
#
mkdir -p build && cd build
meson -Ddownload-js=true ..
ninja -j8

# Run tests
meson test -v --print-errorlogs

# Test install
DESTDIR=/tmp/install-ninja ninja install
cd $ROOT_DIR

#
# Other checks
#

# run D-Scanner
./tests/ci/run-dscanner.py . tests/dscanner.ini
