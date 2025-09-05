#!/bin/sh
#
# This script is supposed to run inside the AppStream Generator container
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

build_type=debugoptimized
if [ "$1" = "codeql" ]; then
    build_type=debug
fi;

#
# Build Project
#
mkdir -p build && cd build
meson setup --buildtype=$build_type \
    -Ddownload-js=true \
    ..
ninja
