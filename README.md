# AppStream Generator

AppStream is an effort to provide additional metadata and unique IDs for all software available in a Linux system.
This repository contains the server-side of the AppStream infrastructure, a tool to generate metadata from distribution packages. You can find out more about AppStream distro metadata at [Freedesktop](http://www.freedesktop.org/software/appstream/docs/chap-DistroData.html#sect-AppStream-ASXML).

The AppStream generator is currently primarily used by Debian, but is written in a distribution agnostic way. Backends only need to implement [two interfaces](source/backends/interfaces.d) to to be ready.

If you are looking for the AppStream client-tools, the [AppStream repository](https://github.com/ximion/appstream) is where you want to go.

![AppStream Generator Logo](docs/asgen.png "AppStream Generator")


## Development
[![Build Status](https://travis-ci.org/ximion/appstream-generator.svg?branch=master)](https://travis-ci.org/ximion/appstream-generator)

### Build dependencies

 * gdc / ldc
 * dub [1]
 * glib2 (>= 2.46)
 * AppStream [2]
 * libarchive [3]
 * LMDB [4]
 * Cairo
 * GdkPixbuf 2.0
 * RSvg 2.0

[1]: https://code.dlang.org/download
[2]: https://github.com/ximion/appstream
[3]: http://www.libarchive.org/
[4]: http://symas.com/mdb/

### Build instructions

Just run `dub build` - if all dependencies are set up correctly, the binary will be built and stored as `build/appstream-generator`.
You might need to update the Git submodules first, run `git submodule update` for that.

On Debian systems, all build requirements can be installed using the following command:
```ShellSession
sudo apt install dub libappstream-dev libgdk-pixbuf2.0-dev libarchive-dev \
    librsvg2-dev liblmdb-dev libglib2.0-dev libcairo2-dev
```

## Usage

Take a look at the `docs/` directory in the source tree for information on how to use the generator. Right now, only the YAML output format is tested properly.
