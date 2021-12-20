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
    gdc \
    ldc \
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
    libyaml-dev \
    libxmlb-dev \
    libcurl4-gnutls-dev \
    gperf

eatmydata apt-get install -yq --no-install-recommends \
    gir-to-d \
    libglibd-2.0-dev \
    liblmdb-dev \
    libarchive-dev \
    libpango1.0-dev

. /etc/os-release
if [ "$ID" = "ubuntu" ]; then
    gdk_pixbuf_dep="libgdk-pixbuf2.0-dev"
else
    gdk_pixbuf_dep="libgdk-pixbuf-2.0-dev"
fi;

yarnpkg_dep="yarnpkg"
if dpkg -s yarn >/dev/null 2>&1; then
  # if the conflicting "yarn" package was already installed,
  # don't try to install yarnpkg
  yarnpkg_dep=""
fi
eatmydata apt-get install -yq --no-install-recommends \
    $gdk_pixbuf_dep \
    librsvg2-dev \
    libcairo2-dev \
    libfontconfig1-dev \
    libpango1.0-dev

# install misc stuff
eatmydata apt-get install -yq --no-install-recommends \
    curl \
    gnupg \
    ffmpeg \
    $yarnpkg_dep
