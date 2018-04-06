#!/bin/sh
set +e

#
# This script is supposed to be used on the appstream-generator CI, and makes
# assumptions about the build environment.
# If you want to run dscanner locally, you will want to adapt this script.
# (at some point in future, we need DScanner to be run by a Meson module)
#

echo "==========================="
echo "=       D-Scanner         ="
echo "==========================="

dscanner --styleCheck src/ \
	--config tests/dscanner.ini \
	-I ./build/girepo \
	-I /usr/lib/ldc/x86_64-linux-gnu/include/d/ \
	-I ./src/ \
	-I /usr/lib/ldc/x86_64-linux-gnu/include/d/ldc/ \
	-I ./build/src/ \
	-I ./contrib/subprojects/dcontainers/src/ \
	-I ./contrib/subprojects/stdx-allocator/source/ \
	-I /usr/include/d/mustache-d/

if [ $? -eq 0 ]; then
  printf '\e[0;32m:) Success \033[0m\n'
  exit 0
else
  printf '\e[0;31m:( D-Scanner found issues \033[0m\n'
  exit 1
fi
