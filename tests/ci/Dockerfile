#
# Docker file for AppStream Generator CI tests
#
FROM debian:testing

# prepare
RUN apt-get update -qq

# install build essentials
RUN apt-get install -yq eatmydata git gcc gdc ldc

# install dependencies used by both appstream and appstream-generator
RUN eatmydata apt-get install -yq --no-install-recommends \
    meson \
    gettext \
    gobject-introspection \
    xsltproc \
    docbook-xsl \
    libgirepository1.0-dev \
    libglib2.0-dev \
    libstemmer-dev \
    libxml2-dev \
    libyaml-dev \
    libsoup2.4-dev \
    gperf

# install dependencies only for appstream-generator
RUN eatmydata apt-get install -yq --no-install-recommends \
    gir-to-d \
    libglibd-2.0-dev \
    libsoup2.4-dev \
    liblmdb-dev \
    libarchive-dev \
    libgdk-pixbuf2.0-dev \
    librsvg2-dev \
    libfontconfig1-dev \
    libpango1.0-dev

# Misc
RUN apt-get install -yq --no-install-recommends \
    curl \
    gnupg \
    ffmpeg \
    yarnpkg

# Install dscanner
RUN mkdir -p /usr/local/bin/
RUN curl -L https://github.com/dlang-community/D-Scanner/releases/download/v0.5.11/dscanner-v0.5.11-linux-x86_64.tar.gz -o /tmp/dscanner.tar.gz
RUN tar -xzf /tmp/dscanner.tar.gz -C /usr/local/bin/
RUN rm /tmp/dscanner.tar.gz
RUN dscanner --version

# build & install the current Git snapshot of AppStream
RUN mkdir /build-tmp

RUN cd /build-tmp && \
    git clone --depth=20 https://github.com/ximion/appstream.git
RUN mkdir /build-tmp/appstream/build
RUN cd /build-tmp/appstream/build && \
    meson --prefix=/usr \
        -Dmaintainer=true \
        -Dapt-support=true \
        -Dcompose=true \
        -Dapidocs=false \
        ..
RUN cd /build-tmp/appstream/build && \
    ninja && ninja install

RUN rm -rf /build-tmp

# finish
RUN mkdir /build
WORKDIR /build
