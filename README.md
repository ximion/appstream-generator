# AppStream Generator

A new AppStream generator written in D, being much faster and more versatile than the old one.
This software is in early development, and is still very incomplete.

## Development

### Build dependencies

 * gdc / ldc
 * dub [1]
 * glib2 (>= 2.46)
 * AppStream [2]
 * libarchive [3]
 * LMDB [4]

[1]: https://code.dlang.org/download
[2]: https://github.com/ximion/appstream
[3]: http://www.libarchive.org/
[4]: http://symas.com/mdb/

### Build instructions

Just run `dub build` - if all dependencies are set up correctly, the binary will be built and stored as `build/appstream-generator`.
You might need to update the Git submodules first, run `git submodule update` for that.

## Usage

This project is work-in-progress, so you can not use it in production yet.
