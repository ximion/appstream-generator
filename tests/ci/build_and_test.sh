#!/bin/sh
#
# This script is supposed to run inside the AppStream Generator Docker container
# on the CI system.
#
set -e
export LANG=C.UTF-8

# prefer GDC 10 over the default for now
if [ "$DC" = "gdc" ];
then
  export DC="gdc-10"
fi

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
ninja test -v

# Test install
DESTDIR=/tmp/install-ninja ninja install
cd ..

#
# Other checks
#

# run D-Scanner
./tests/ci/run-dscanner.py . tests/dscanner.ini
