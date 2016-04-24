# AppStream Generator Usage

## How to use

### Generating distro metadata
To generate AppStream distribution metadata for your repository, create a local
mirror of the repository first.
Then create a new folder, and write a `asgen-config.json` configuration file for the
metadata generator. Details on the file and an example can be found in [the asgen-config docs](asgen-config.md).

After the config file has been written, you can generate the metadata as follows:
```Bash
cd /srv/asgen/workspace # path where the asgen-config.json file is located
appstream-generator process chromodoris # replace "chromodoris" with the name of the suite you want to analyze
```
The generator is assuming you have enough memory and disk space on your machine to cache stuff.
Resulting metadata will be placed in `export/data/`, machine-readable issue-hints can be found in `export/hints/` and the processed screenshots and icons are located in `export/media/`.

In order to drop old packages and cruft from the databases, you should run
```Bash
appstream-generator cleanup
```
every once in a while. This will drop all superseded packages and data from the caches.

If you do not want to `cd` into the workspace directory, you can also use the `--workspace|-w` flag to define a workspace.

### Validating metadata
You can validate the resulting metadata using the AppStream client tools.
Use `appstreamcli validate <metadata>.xml.gz` for XML metadata, and `dep11-validate <dep11file>.yml.gz` for YAML. This will check the files for mistakes and compliance with the specification.

Keep in mind that the generator will always generate spec-compliant metadata, but might - depending on the input - produce data which has smaller flaws (e.g. formatting issues in the long descriptions). In these cases, issue-hints will have been emitted, so the package maintainers can address the metadata issues.

## Troubleshooting

### Memory Usage
The `appstream-generator` will not hesitate to use RAM, and also decide to use lots of it if enough is available. This is especially true when scanning new packages for their contents and storing the information in the LMDB database.
Ideally make sure that you are running a 64bit system with at least 4GB of RAM if you want to use the generator properly.
For the generator, speed matters more than RAM usage. You can use cgroups to limit the amount of memory the generator uses.

### Profiling
TODO
