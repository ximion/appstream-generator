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
cd /tmp/build

. /etc/os-release
if [ "$VERSION_CODENAME" = "trixie" ] || [ "$VERSION_CODENAME" = "noble" ] || [ "$ID" = "fedora" ]; then
    # upgrade libfyaml on Debian Stable and Ubuntu LTS
    git clone --depth=1 --branch=v0.9.4 https://github.com/pantoniou/libfyaml.git
    cd libfyaml
    mkdir b && cd b
    cmake -GNinja -DCMAKE_INSTALL_PREFIX=/usr \
        -DENABLE_LIBCLANG=OFF \
        -DBUILD_TESTING=OFF \
        ..
    ninja && ninja install
    cd ../..
fi;

# the Blake3 C library was not built on older distros
blake3_support=true
if { [ "$ID" = "ubuntu" ] && [ "$VERSION_ID" = "24.04" ]; } ||
   { [ "$ID" = "debian" ] && [ "$VERSION_ID" = "13" ]; }; then
    blake3_support=false
fi;

# build & install the current Git snapshot of AppStream
git clone --depth=1 https://github.com/ximion/appstream.git
cd appstream
mkdir build && cd build
meson setup --prefix=/usr \
        -Dmaintainer=true \
        -Dapt-support=true \
        -Dcompose=true \
        -Dbash-completion=false \
        -Dapidocs=false \
        -Dgir=false \
        -Dblake3-support=$blake3_support \
        ..
ninja && ninja install
cd ../..

# cleanup
rm -rf /tmp/build
