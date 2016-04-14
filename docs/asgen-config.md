# Generator Project Configuration

This document describes the options and fields needed to be set in an `asgen-config.json` file.

## JSON file example

An example `asgen-config.json` file may look like this:
```JSON
{
"ProjectName": "Tanglu",
"ArchiveRoot": "/srv/archive.tanglu.org/tanglu/",
"MediaBaseUrl": "http://metadata.tanglu.org/appstream/media",
"HtmlBaseUrl": "http://metadata.tanglu.org/appstream/hints_html/",
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
          "dataPriority": "10",
          "baseSuite": "chromodoris",
          "sections": ["main", "contrib"],
          "architectures": ["amd64", "i386"]
        }
  }
}
```

## Description of fields

Key | Comment
------------ | -------------
ProjectName | The name of your project or distribution which ships AppStream metadata.
Backend | The backend that should be used to obtain the raw data. Defaults to `debian` if not set.
MetadataType | The type of the resulting AppStream metadata. Can be one of `YAML` or `XML`. If omitted, the backend's default value is used.
ArchiveRoot | A local URL to the mirror of your archive, containing the dists/ and pool/ directories
MediaBaseUrl | The http or https URL which should be used in the generated metadata to fetch media like screenshots or icons
HtmlBaseUrl | The http or https URL to the web location where the HTML hints will be published. (This setting is optional, but recommended)
Suites | A list of suites which should be recognized by the generator. Each suite has the components and architectures which should be seached for metadata as children. If `baseSuite` is set, the 'main' component of that suite is also considered for providing icon data for packages in this suite.
Features | Disable or enable selected generator features. For a detailed description see below.

### Enabling and disabling features

Several features of the metadata generator can be toggled to make it work in different scenarios.
The following feature values are recognized, and can be enabled or disabled in the JSON document. If no explicit value is set for a feature, the generator will pick its default value, which is sane in most cases.

Name | Comment
------------ | -------------
validateMetainfo | Validate the AppStream upstream metadata. The validation is slow, but will produce better feedback and issue hints if enabled. *Default: `ON`*
processDesktop | Process .desktop files which do not have a metainfo file. If disabled, all data without metainfo file will be ignored. *Default: `ON`*
handleScreenshots | Download and resize screenshots. If disabled, no screenshots will be available in the resulting metadata *Default: `ON`*
optimizePNGSize | Use `optipng` to reduce the size of PNG images. Optipng needs to be installed. *Default: `ON`*
