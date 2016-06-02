#!/bin/sh
set -e

echo "D compiler: $DC"
set -x
dub --version

#
# This script is supposed to run inside the AppStream Generator Docker container
# on the CI system.
#

dub build --parallel -v
dub test

make js
make install DESTDIR=/tmp/install-tmp
