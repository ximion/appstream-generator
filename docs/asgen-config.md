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
Suites | Suites which should be recognized by the generator. Each suite has the components and architectures which should be searched for metadata as children. See below for more information.
Features | Disable or enable selected generator features. For a detailed description see below.
CAInfo | Set the CA certificate bundle file to use for SSL peer verification. If this is not set, the generator will use the system default.


### Suite fields

The `Suites` field contains a dictionary of the suites which should be processed as value. These suites can contain a selection of properties:

Key | Comment
------------ | -------------
sections | A list of sections the suite possesses. The "sections" are also known as archive components in the Debian world. *(required)*
architectures | A list of architectures which should be processed for this suite. *(required)*
baseSuite | An optional base suite name which should be used in addition to the child suite to resolve icons (only the `main` section of that suite is considered).
dataPriority | An integer value representing the priority the data generated for this suite should have. Metadata with a higher priority will override existing data (think of an `-updates` suite wanting to override data shipped with the base suite). If this is not set, AppStream client tools will assume the priority being `0`.
useIconTheme | Set a specific icon theme name with highest priority for this suite. This is useful if you want a different default icon theme providing icons for generic icon names (by default, the default themes of KDE and GNOME are used).


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
