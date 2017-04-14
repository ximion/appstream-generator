#!/bin/sh

if [ -z ${MESON_BUILD_ROOT+x} ]; then
    echo "This script should only be run by the Meson build system."
    exit 1
fi

find $MESON_BUILD_ROOT/girepo -name "*.d" | sort
