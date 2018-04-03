#
# Docker file for AppStream Generator CI tests
#
FROM debian:buster

# prepare
RUN apt-get update -qq

# install build essentials
RUN apt-get install -yq git gcc gdc ldc

# install dependencies used by both appstream and appstream-generator
RUN apt-get install -yq --no-install-recommends \
    meson \
    gettext \
    gobject-introspection \
    gtk-doc-tools \
    libgirepository1.0-dev \
    libglib2.0-dev \
    libstemmer-dev \
    libxml2-dev \
    libyaml-dev

# install dependencies only for appstream-generator
RUN apt-get install -yq --no-install-recommends \
    gir-to-d \
    libmustache-d-dev \
    libcurl4-gnutls-dev \
    liblmdb-dev \
    libarchive-dev \
    libgdk-pixbuf2.0-dev \
    librsvg2-dev \
    libfontconfig1-dev \
    libpango1.0-dev

# JavaScript stuff
RUN apt-get install -yq --no-install-recommends nodejs
RUN git clone --depth=1 https://github.com/npm/npm.git
RUN cd npm && make install
RUN rm -rf npm
RUN npm install -g bower

# build & install the current Git snapshot of AppStream
RUN mkdir /build-tmp

RUN cd /build-tmp && \
    git clone --depth=20 https://github.com/ximion/appstream.git
RUN mkdir /build-tmp/appstream/build
RUN cd /build-tmp/appstream/build && \
    meson --prefix=/usr -Dmaintainer=true -Dapt-support=true ..
RUN cd /build-tmp/appstream/build && \
    ninja && ninja install

RUN rm -rf /build-tmp

# finish
RUN mkdir /build
WORKDIR /build
