# Generator Project Configuration

This document describes the options and fields which can be set in an `asgen-config.json` file.

## JSON file example

An example `asgen-config.json` file may look like this:
```JSON
{
"ProjectName": "Tanglu",
"ArchiveRoot": "/srv/archive.tanglu.org/tanglu/",
"MediaBaseUrl": "http://metadata.tanglu.org/appstream/media",
"HtmlBaseUrl": "http://metadata.tanglu.org/appstream/",
"Backend": "debian",
"Features":
  {
    "validateMetainfo": true
  },
"Suites":
  {
    "chromodoris":
      {
        "sections": ["main", "contrib"],
        "architectures": ["amd64", "i386"]
      },
    "chromodoris-updates":
        {
          "dataPriority": 10,
          "baseSuite": "chromodoris",
          "sections": ["main", "contrib"],
          "architectures": ["amd64", "i386"]
        }
  },
 "Icons":
  {
    "64x64":   {"cached": true, "remote": false},
    "128x128": {"cached": false, "remote": true}
  }
}
```

## Description of fields

### Toplevel fields

Key | Comment
------------ | -------------
ProjectName | The name of your project or distribution which ships AppStream metadata.
Backend | The backend that should be used to obtain the raw data. Defaults to `debian` if not set.
MetadataType | The type of the resulting AppStream metadata. Can be one of `YAML` or `XML`. If omitted, the backend's default value is used.
ArchiveRoot | A local URL to the mirror of your archive, containing the dists/ and pool/ directories
MediaBaseUrl | The http or https URL which should be used in the generated metadata to fetch media like screenshots or icons
HtmlBaseUrl | The http or https URL to the web location where the HTML hints will be published. (This setting is optional, but recommended)
Oldsuites | This key exists to support migration from an alternative appstream generator. Given a list of suite names, the output HTML will link to `suitename/index.html`.
Suites | Suites which should be recognized by the generator. Each suite has the components and architectures which should be searched for metadata as children. See below for more information.
Features | Disable or enable selected generator features. For a detailed description see below.
CAInfo | Set the CA certificate bundle file to use for SSL peer verification. If this is not set, the generator will use the system default.
AllowedCustomKeys | Set which keys of the <custom/> tag are allowed to be propagated to the collection metadata output. This key takes a list of custom-key strings as value.
ExportDirs | Set where to export data. The dictionary requires full paths set for the "Media", "Data", "Hints" or "Html" key. In case a value is missing, the default locations are used.
ExtraMetainfoDir | Path to a directory where additional injected metainfo files are located. If not set, the `extra-metainfo` directory in the project workspace is used.
WorkspaceDir | Explicitly set the location of the workspace. Only makes sense if the generator is meant to be used with a lot of configuration files and the configuration is passed to it via the `-c` flag.
Icons | Customize the icon policy. See below for more details.


### Suite fields

The `Suites` field contains a dictionary of the suites which should be processed as value. These suites can contain a selection of properties:

Key | Comment
------------ | -------------
sections | A list of sections the suite possesses. The "sections" are also known as archive components in the Debian world. *(required)*
architectures | A list of architectures which should be processed for this suite. *(required)*
baseSuite | An optional base suite name which should be used in addition to the child suite to resolve icons (only the `main` section of that suite is considered).
dataPriority | An integer value representing the priority the data generated for this suite should have. Metadata with a higher priority will override existing data (think of an `-updates` suite wanting to override data shipped with the base suite). If this is not set, AppStream client tools will assume the priority being `0`.
useIconTheme | Set a specific icon theme name with highest priority for this suite. This is useful if you want a different default icon theme providing icons for generic icon names (by default, the default themes of KDE and GNOME are used).
immutable | If set to `true`, the state of the metadata files and exported data will be frozen, and no more changes to the data for this suite will be allowed. This only works if the `immutableSuites` feature is enabled.


### Enabling and disabling features

Several features of the metadata generator can be toggled to make it work in different scenarios.
The following feature values are recognized, and can be enabled or disabled in the JSON document. If no explicit value is set for a feature, the generator will pick its default value, which is sane in most cases.

Name | Comment
------------ | -------------
validateMetainfo | Validate the AppStream upstream metadata. The validation is slow, but will produce better feedback and issue hints if enabled. *Default: `ON`*
processDesktop | Process .desktop files which do not have a metainfo file. If disabled, all data without metainfo file will be ignored. *Default: `ON`*
noDownloads | Do not attempt any downloads. This will implicitly disable any handling of screenshots and possibly other features. Using this flag is discouraged. *Default: `OFF`*
createScreenshotsStore | Mirror screenshots and create thumbnails of them in `media/`. This will yield the best experience with software-centers, and also allow full control over which screenshots are displayed. Disabling this will make clients pull screenshots from 3rd-party upstream servers. *Default: `ON`*
optimizePNGSize | Use `optipng` to reduce the size of PNG images. Optipng needs to be installed. *Default: `ON`*
metadataTimestamps | Write timestamps into generated metadata files. *Default: `ON`*
immutableSuites | Allow suites to be marked as immutable. This is useful for distributions with fixed releases, but not for rolling release distributions or continuously updated repositories. *Default: `ON`*
processFonts | Include font metadata and render fonts. *Default: `ON`*
allowIconUpscaling | Allows upscaling of small 48x48px icons to 64x64px to make applications show up. Icons are only upscaled as a last resort. *Default: `ON`*
processGStreamer | Synthesise `type=codec` metadata from available GStreamer packages. Requires support in the backend, currently only implemented for Debian. *Default: `ON`*

### Configuring icon policies

The `Icons` field allows to customize the icon policy used for a generator run. It decides which icon sizes are extracted, and whether they are stored as cached icon, remote icons or both.
The field contains a dictionary with icon sizes as keys. Valid icon sizes are `48x48`, `64x64` and `128x128` and their HiDPI variants (e.g. `64x64@2`).
The values for the icon-size keys are dictionaries with two boolean keys, `cached` and `remote`, to select the storage method for the icon size.
Cached means an icon tarball is generated for the icon size that can be made available locally, while remote means the icon can be downloaded on-demand by the software center and no local cache of all icons exists. Icon sizes not mentioned, or with both `cached` and `remote` set to `false` will not be extracted.
The `64x64` icon size must always be present and be cached. If this is not the case, appstream-generator will adjust the configuration internally and emit a warning.
If no `Icons` field is present, appstream-generator will use a default policy for icons (creating cache tarballs for all sizes, and remote links for sizes >= 129x128px).

## Injecting extra metainfo / removing components

Sometimes injecting metainfo files directly into the generation process instead of packaging them makes sense. This can be done for example for `web-application` components, `operating-system` components or for components which are merged into others. It is discouraged to use this feature for any components that are directly tied to a package.
Metainfo XML files can be placed in `%ExtraMetainfoDir%/suite/section/(arch)`, where `%ExtraMetainfoDir%` usually is the `extra-metainfo` directory in the generator's current workspace, unless this default is overriden in the configuration file.
If the `arch` part of the path is omitted, a metainfo file is added to all active architectures. E.g. a XML file placed in `%ExtraMetainfoDir%/buster/main/` will apply to all active architectures for `buster`, while files in `%ExtraMetainfoDir%/buster/main/amd64/` will only apply to the `amd64` architecture.

Additionally to metainfo XML files, a `removed-components.json` file may be placed in the extra-metainfo directories. This JSON file contains a list of component IDs that should be removed from the metadata pool on client machines. By listing IDs in this file, the generator will create a special component that will trigger a component with the same ID to be removed from the metadata pool if its priority is lower.
This feature is useful for overlay suites, for example if the `buster-updates` suite (with priority 10) wants to completely remove a component from the `buster` suite (with priority 0) from the user's eyes. This may be necessary if a component improperly changes its ID, if you are maintaining an overlay distribution and can not control the composition of packages in the base suites, or in case of legal issues where a component has to be removed retroactively from a frozen distribution suite. It may also be useful to hide `web-application` components in a stable distribution in case their service is discontinued before the distribution release is out of support as well.

Internally, injected metainfo data is grouped under a special fake package name, in order to allow the generator to properly record hints for the added components and to associate the data with the right suite(s).

## Minimal configuration file

A minimal configuration file can look like this:
```JSON
{
"ProjectName": "Tanglu",
"ArchiveRoot": "/srv/archive.tanglu.org/tanglu/",
"MediaBaseUrl": "http://metadata.tanglu.org/appstream/media",
"HtmlBaseUrl": "http://metadata.tanglu.org/appstream/",
"Backend": "debian",
"Suites":
  {
    "chromodoris":
      {
        "sections": ["main", "contrib"],
        "architectures": ["amd64", "i386"]
      }
  }
}
```
