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
 * Meson (>= 0.34) [2]
 * glib2 (>= 2.46)
 * AppStream [3]
 * libarchive (>= 3.2) [4]
 * LMDB [5]
 * Cairo
 * GdkPixbuf 2.0
 * RSvg 2.0
 * FreeType
 * Fontconfig
 * Pango
 * libmustache-d
 * Bower (optional) [6]

[1]: https://github.com/ldc-developers/ldc/releases
[2]: http://mesonbuild.com/
[3]: https://github.com/ximion/appstream
[4]: http://www.libarchive.org/
[5]: http://symas.com/mdb/
[6]: http://bower.io/

On Debian and derivatives of it, all build requirements can be installed using the following command:
```ShellSession
sudo apt install meson ldc libappstream-dev libgdk-pixbuf2.0-dev libarchive-dev \
    librsvg2-dev liblmdb-dev libglib2.0-dev libcairo2-dev libcurl4-gnutls-dev \
    libfreetype6-dev libfontconfig1-dev libpango1.0-dev libmustache-d-dev
```

### Build instructions

Ensure you have initialized the Git submodules. Run `make update-submodule` to run a fake-target which initializes and updates the submodule.

To build the tool with Meson, create a `build` subdirectory, change into it and run `meson .. && ninja` to build.
In summary:

```ShellSession
$ make update-submodule
$ mkdir build && cd build
$ meson -Ddownload_js=true ..
$ ninja
$ sudo ninja install
```

We support several options to be set to influence the build. Change into the build directory and run `mesonconf` to see them all.

## Usage

Take a look at the `docs/` directory in the source tree for information on how to use the generator. Right now, only the YAML output format is tested properly.

## Hacking

Pull-requests and patches are very welcome! If you are new to D, it is highly recommended to take a few minutes to look at the D tour to get a feeling of what the language can do: http://tour.dlang.org/
