# AppStream Generator

AppStream is an effort to provide additional metadata and unique IDs for all software available in a Linux system.
This repository contains the server-side of the AppStream infrastructure, a tool to generate metadata from distribution packages. You can find out more about AppStream distro metadata at [Freedesktop](http://www.freedesktop.org/software/appstream/docs/chap-DistroData.html#sect-AppStream-ASXML).

The AppStream generator is currently primarily used by Debian, but is written in a distribution agnostic way. Backends only need to implement [two interfaces](source/backends/interfaces.d) to to be ready.

If you are looking for the AppStream client-tools, the [AppStream repository](https://github.com/ximion/appstream) is where you want to go.

![AppStream Generator Logo](data/templates/default/static/img/asgen.png "AppStream Generator")


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
 * Bower (optional) [5]

[1]: https://code.dlang.org/download
[2]: https://github.com/ximion/appstream
[3]: http://www.libarchive.org/
[4]: http://symas.com/mdb/
[5]: http://bower.io/

On Debian and derivatives of it, all build requirements can be installed using the following command:
```ShellSession
sudo apt install dub libappstream-dev libgdk-pixbuf2.0-dev libarchive-dev \
    librsvg2-dev liblmdb-dev libglib2.0-dev libcairo2-dev libcurl4-gnutls-dev
```

### Build instructions

Ensure you have initialized the Git submodules. Run `make update-submodule` to run a fake-target which initializes and updates the submodule.
Then run `dub build` or `make` to build the software - if all dependencies are set up correctly, the binary will be built and stored as `build/appstream-generator`,
and can be used directly from there.

If you want to use the HTML reports, you need to install Bower, then run `make js` to download the JavaScript bits and store them in the right directory.
If you want, you can also install the generator system-wide using `make install`. In summary:
```ShellSession
$ make update-submodule
$ dub build --parallel
$ make js
$ sudo make install
```

## Usage

Take a look at the `docs/` directory in the source tree for information on how to use the generator. Right now, only the YAML output format is tested properly.

## Hacking

Pull-requests and patches are very welcome! If you are new to D, it is highly recommended to take a few minutes to look at the D tour to get a feeling of what the language can do: http://tour.dlang.org/
