#!/bin/sh
#
# This script is supposed to run inside the AppStream Generator container
# on the CI system.
#
set -e
export LANG=C.UTF-8

ROOT_DIR=$(pwd)

set -v


#
# Test already built project
#
cd build

# Run tests
meson test -v --print-errorlogs

# Test install
DESTDIR=/tmp/install-ninja ninja install

cd $ROOT_DIR
