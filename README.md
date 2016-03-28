# AppStream Generator

A new AppStream generator written in D, being much faster and more versatile than the old one.
This software is in early development, and is still very incomplete.

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
```bash
sudo apt install dub libappstream-dev libgdk-pixbuf2.0-dev libarchive-dev \
    librsvg2-dev liblmdb-dev libglib2.0-dev libcairo2-dev
```

## Usage

This project is work-in-progress, so you can not use it in production yet.
