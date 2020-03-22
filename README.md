# AppStream Generator

AppStream is an effort to provide additional metadata and unique IDs for all software available in a Linux system.
This repository contains the server-side of the AppStream infrastructure, a tool to generate metadata from distribution packages. You can find out more about AppStream collection metadata at [Freedesktop](https://www.freedesktop.org/software/appstream/docs/chap-CollectionData.html).

The AppStream generator is currently primarily used by Debian, but is written in a distribution agnostic way. Backends only need to implement [two interfaces](src/asgen/backends/interfaces.d) to to be ready.

If you are looking for the AppStream client-tools, the [AppStream repository](https://github.com/ximion/appstream) is where you want to go.

![AppStream Generator Logo](data/templates/default/static/img/asgen.png "AppStream Generator")


## Development
[![Build Status](https://travis-ci.org/ximion/appstream-generator.svg?branch=master)](https://travis-ci.org/ximion/appstream-generator)

### Build dependencies

 * LDC[1]
 * Meson (>= 0.46) [2]
 * GLibD [3]
 * AppStream [4]
 * libarchive (>= 3.2) [5]
 * LMDB [6]
 * GirToD [7]
 * Cairo
 * GdkPixbuf 2.0
 * RSvg 2.0
 * FreeType
 * Fontconfig
 * Pango
 * Yarn (optional) [8]

[1]: https://github.com/ldc-developers/ldc/releases
[2]: http://mesonbuild.com/
[3]: https://github.com/gtkd-developers/GlibD
[4]: https://github.com/ximion/appstream
[5]: https://libarchive.org/
[6]: https://symas.com/lmdb/
[7]: https://github.com/gtkd-developers/gir-to-d
[8]: https://yarnpkg.com/

On Debian and derivatives of it, all build requirements can be installed using the following command:
```ShellSession
sudo apt install meson ldc gir-to-d libappstream-dev libsoup2.4-dev libarchive-dev \
    libgdk-pixbuf2.0-dev librsvg2-dev libcairo2-dev libfreetype6-dev libfontconfig1-dev \
    libpango1.0-dev liblmdb-dev libglibd-2.0-dev
```

### Build instructions

To build the tool with Meson, create a `build` subdirectory, change into it and run `meson .. && ninja` to build.
In summary:

```ShellSession
$ mkdir build && cd build
$ meson -Ddownload-js=true ..
$ ninja
$ sudo ninja install
```

We support several options to be set to influence the build. Change into the build directory and run `mesonconf` to see them all.

You might want to perform an optimized debug build by passing `--buildtype=debugoptimized` to `meson` or just do a release build straight
away with `--buildtype=release` in case you want to use the resulting binaries productively. By default, the build happens without optimizations
which slows down the generator.

## Usage

Take a look at the `docs/` directory in the source tree for information on how to use the generator and write configuration files for it.

## Hacking

Pull-requests and patches are very welcome! If you are new to D, it is highly recommended to take a few minutes to look at the D tour to get a feeling of what the language can do: https://tour.dlang.org/
