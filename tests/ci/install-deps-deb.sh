#!/bin/sh
#
# Install AppStream Generator build dependencies
#
set -e
set -x

export DEBIAN_FRONTEND=noninteractive

# update caches
apt-get update -qq

# install build essentials
apt-get install -yq \
    eatmydata \
    build-essential \
    gdb \
    gcc \
    g++ \
    git

# install dependencies
eatmydata apt-get install -yq --no-install-recommends \
    meson \
    gettext \
    gobject-introspection \
    gtk-doc-tools \
    xsltproc \
    docbook-xsl \
    docbook-xml \
    libgirepository1.0-dev \
    libglib2.0-dev \
    libstemmer-dev \
    libxml2-dev \
    libfyaml-dev \
    libxmlb-dev \
    libcurl4-gnutls-dev \
    libsystemd-dev \
    gperf \
    itstool

. /etc/os-release
if [ "$ID" = "ubuntu" ]; then
    catch2_dep="catch2"
    eatmydata apt-get install -yq --no-install-recommends g++-14 gcc-14
else
    catch2_dep="libcatch2-dev"
fi;

eatmydata apt-get install -yq --no-install-recommends \
    liblmdb-dev \
    libarchive-dev \
    libpango1.0-dev \
    libtbb-dev \
    libbackward-cpp-dev \
    libunwind-dev \
    $catch2_dep
eatmydata apt-get install -yq libglibd-2.0-dev || true

eatmydata apt-get install -yq --no-install-recommends \
    libgdk-pixbuf-2.0-dev \
    librsvg2-dev \
    libcairo2-dev \
    libfontconfig1-dev \
    libpango1.0-dev

# install misc stuff
eatmydata apt-get install -yq --no-install-recommends \
    curl \
    gnupg \
    ffmpeg \
    npm
