#!/bin/sh
#
# Build & install AppStream Generator dependencies
#
set -e
set -x

#
# This script is *only* intended to be run in a CI container.
#

mkdir /tmp/build

# build & install the current Git snapshot of AppStream
cd /tmp/build && \
    git clone --depth=1 https://github.com/ximion/appstream.git
mkdir /tmp/build/appstream/build
cd /tmp/build/appstream/build && \
    meson setup --prefix=/usr \
        -Dmaintainer=true \
        -Dapt-support=true \
        -Dcompose=true \
        -Dbash-completion=false \
        -Dapidocs=false \
        ..
cd /tmp/build/appstream/build && \
    ninja && ninja install

# cleanup
rm -rf /tmp/build
