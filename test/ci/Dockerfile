#
# Docker file for AppStream Generator CI tests
#
FROM ubuntu:xenial

# prepare
RUN apt-get update -qq

# install build essentials
RUN apt-get install -yq git gcc gdc

# install dependencies used by both appstream and appstream-generator
RUN apt-get install -yq --no-install-recommends \
    cmake \
    intltool \
    libglib2.0-dev \
    libxml2-dev \
    libgirepository1.0-dev \
    libxapian-dev \
    libyaml-dev \
    xmlto \
    gobject-introspection \
    libprotobuf-dev \
    protobuf-compiler

# install dependencies only for appstream-generator
RUN apt-get install -yq --no-install-recommends \
    dub \
    libcurl4-gnutls-dev \
    liblmdb-dev \
    libarchive-dev \
    libgdk-pixbuf2.0-dev \
    librsvg2-dev

# JavaScript stuff
RUN apt-get install -yq --no-install-recommends \
    npm \
    nodejs-legacy
RUN npm install -g bower

# build & install the current Git snapshot of AppStream
RUN mkdir /build-tmp
RUN cd /build-tmp && \
    git clone --depth=20 https://github.com/ximion/appstream.git
RUN mkdir /build-tmp/appstream/build
RUN cd /build-tmp/appstream/build && \
    cmake -DMAINTAINER=ON -DAPT_SUPPORT=ON ..
RUN cd /build-tmp/appstream/build && \
    make && make install
RUN rm -rf /build-tmp

# finish
RUN mkdir /build
WORKDIR /build
