#!/bin/sh
#
# Build & install AppStream Generator dependencies
#
set -e
set -x

# Install dscanner
mkdir -p /usr/local/bin/
curl -L https://github.com/dlang-community/D-Scanner/releases/download/v0.11.0/dscanner-v0.11.0-linux-x86_64.tar.gz -o /tmp/dscanner.tar.gz
tar -xzf /tmp/dscanner.tar.gz -C /usr/local/bin/
rm /tmp/dscanner.tar.gz
dscanner --version

# build & install the current Git snapshot of AppStream
mkdir /tmp/build

cd /tmp/build && \
    git clone --depth=20 https://github.com/ximion/appstream.git
mkdir /tmp/build/appstream/build
cd /tmp/build/appstream/build && \
    meson --prefix=/usr \
        -Dmaintainer=true \
        -Dapt-support=true \
        -Dcompose=true \
        -Dapidocs=false \
        ..
cd /tmp/build/appstream/build && \
    ninja && ninja install

rm -rf /tmp/build
