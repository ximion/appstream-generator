#
# Docker file for AppStream Generator CI tests
#
FROM debian:sid

# prepare
RUN apt-get update -qq

# install build essentials
RUN apt-get install -yq git gcc gdc ldc

# install dependencies used by both appstream and appstream-generator
RUN apt-get install -yq --no-install-recommends \
    cmake \
    gettext \
    itstool \
    libglib2.0-dev \
    libxml2-dev \
    libgirepository1.0-dev \
    libyaml-dev \
    libstemmer-dev \
    xmlto \
    gobject-introspection

# install dependencies only for appstream-generator
RUN apt-get install -yq --no-install-recommends \
    meson \
    libmustache-d-dev \
    libcurl4-gnutls-dev \
    liblmdb-dev \
    libarchive-dev \
    libgdk-pixbuf2.0-dev \
    librsvg2-dev \
    libfontconfig1-dev \
    libpango1.0-dev

# JavaScript stuff
RUN apt-get install -yq --no-install-recommends \
    npm \
    nodejs
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

# build & install GirToD
RUN cd /build-tmp && \
    git clone https://github.com/gtkd-developers/gir-to-d
RUN mkdir /build-tmp/gir-to-d/build
RUN cd /build-tmp/gir-to-d/build && \
    meson ..
RUN cd /build-tmp/gir-to-d/build && \
    ninja && ninja install

RUN rm -rf /build-tmp

# finish
RUN mkdir /build
WORKDIR /build
