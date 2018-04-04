#!/bin/sh
set -e

dscanner --styleCheck src/ \
	--config test/dscanner.ini \
	-I ./build/girepo \
	-I /usr/lib/ldc/x86_64-linux-gnu/include/d/ \
	-I ./src/ \
	-I /usr/lib/ldc/x86_64-linux-gnu/include/d/ldc/ \
	-I ./build/src/ \
	-I ./contrib/subprojects/dcontainers/src/ \
	-I ./contrib/subprojects/stdx-allocator/source/ \
	-I /usr/include/d/mustache-d/
