/*
 * Copyright (C) 2016-2022 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

module asgen.config;

import std.stdio;
import std.array;
import std.string : format, toLower;
import std.path : dirName, buildPath, buildNormalizedPath, isAbsolute, absolutePath;
import std.conv : to;
import std.json;
import std.typecons;
import std.file : getcwd, thisExePath, exists;

import ascompose.Globals : Globals;
import ascompose.IconPolicy : IconPolicy;
public import appstream.c.types : FormatVersion;

import asgen.utils : existsAndIsDir, randomString, ImageSize;
import asgen.logging;
import asgen.defines : DATADIR;

/**
 * Describes a suite in a software repository.
 **/
struct Suite {
    string name;
    int dataPriority = 0;
    string baseSuite;
    string iconTheme;
    string[] sections;
    string[] architectures;
    string extraMetainfoDir;
    bool isImmutable;
}

/**
 * The AppStream metadata type we want to generate.
 **/
enum DataType {
    XML,
    YAML
}

/**
 * Distribution-specific backends.
 **/
enum Backend {
    Unknown,
    Dummy,
    Debian,
    Ubuntu,
    Archlinux,
    RpmMd,
    Alpinelinux,
    FreeBSD
}

/**
 * Generator features that can be toggled by the user.
 */
struct GeneratorFeatures {
    bool processDesktop;
    bool validate;
    bool noDownloads;
    bool storeScreenshots;
    bool optipng;
    bool metadataTimestamps;
    bool immutableSuites;
    bool processFonts;
    bool allowIconUpscale;
    bool processGStreamer;
    bool processLocale;
    bool screenshotVideos;
    bool propagateMetaInfoArtifacts;
}

/// Fake package name AppStream Generator uses internally to inject additional metainfo on users' request
public immutable EXTRA_METAINFO_FAKE_PKGNAME = "+extra-metainfo";

/// A list of valid icon sizes that we recognize in AppStream
public immutable allowedIconSizes = [
    ImageSize(48), ImageSize(48, 48, 2),
    ImageSize(64), ImageSize(64, 64, 2),
    ImageSize(128), ImageSize(128, 128, 2)
];

/**
 * The global configuration for the metadata generator.
 */
final class Config {
private:
    string workspaceDir;
    string exportDir;

    string tmpDir;

    IconPolicy m_iconPolicy;

    // thread local
    static bool instantiated_;

    // thread global
    __gshared Config instance_;

    this ()
    {
        import glib.Util : Util;

        // our default export format version
        formatVersion = FormatVersion.V0_16;

        // find all the external binaries we (may) need
        // we search for them unconditionally, because the unittests may rely on their absolute
        // paths being set even if a particular feature flag that requires them isn't.
        optipngBinary = Globals.optipngBinary;
        ffprobeBinary = Util.findProgramInPath("ffprobe");

        // new default icon policy instance
        m_iconPolicy = new IconPolicy;
    }

public:
    FormatVersion formatVersion;
    string projectName;
    string archiveRoot;
    string mediaBaseUrl;
    string htmlBaseUrl;

    string backendName;
    Backend backend;
    Suite[] suites;
    string[] oldsuites;
    DataType metadataType;
    GeneratorFeatures feature; /// Set which features are enabled or disabled

    string optipngBinary;
    string ffprobeBinary;

    bool[string] allowedCustomKeys; // set of allowed keys in <custom/> tags

    string dataExportDir;
    string hintsExportDir;
    string mediaExportDir;
    string htmlExportDir;

    long maxScrFileSize;

    string caInfo;

    static Config get ()
    {
        if (!instantiated_) {
            synchronized (Config.classinfo) {
                if (!instance_)
                    instance_ = new Config;

                instantiated_ = true;
            }
        }

        return instance_;
    }

    @property
    string formatVersionStr ()
    {
        static import appstream.Utils;

        alias AsUtils = appstream.Utils.Utils;
        return AsUtils.formatVersionToString(formatVersion);
    }

    @property
    string databaseDir () const
    {
        return buildPath(workspaceDir, "db");
    }

    @property
    string cacheRootDir () const
    {
        return buildPath(workspaceDir, "cache");
    }

    @property
    string templateDir ()
    {
        // find a suitable template directory
        // first check the workspace
        auto tdir = buildPath(workspaceDir, "templates");
        tdir = getVendorTemplateDir(tdir, true);

        if (tdir.empty) {
            immutable exeDir = dirName(thisExePath());
            tdir = buildNormalizedPath(exeDir, "..", "..", "..", "data", "templates");
            tdir = getVendorTemplateDir(tdir);

            if (tdir.empty) {
                tdir = getVendorTemplateDir(buildPath(DATADIR, "templates"));

                if (tdir.empty) {
                    tdir = buildNormalizedPath(exeDir, "..", "data", "templates");
                    tdir = getVendorTemplateDir(tdir);
                }
            }
        }

        return tdir;
    }

    @property
    IconPolicy iconPolicy ()
    {
        return m_iconPolicy;
    }

    /**
     * Helper function to determine a vendor template directory.
     */
    private string getVendorTemplateDir (const string dir, bool allowRoot = false) @safe
    {
        string tdir;
        if (!projectName.empty) {
            tdir = buildPath(dir, projectName.toLower);
            if (existsAndIsDir(tdir))
                return tdir;
        }
        tdir = buildPath(dir, "default");
        if (existsAndIsDir(tdir))
            return tdir;
        if (allowRoot) {
            if (existsAndIsDir(dir))
                return dir;
        }

        return null;
    }

    void loadFromFile (string fname, string enforcedWorkspaceDir = null, string enforcedExportDir = null)
    {
        // read the configuration JSON file
        auto f = File(fname, "r");
        string jsonData;
        string line;
        while ((line = f.readln()) !is null)
            jsonData ~= line;

        JSONValue root = parseJSON(jsonData);

        if ("WorkspaceDir" in root) {
            workspaceDir = root["WorkspaceDir"].str;
        } else {
            workspaceDir = dirName(fname);
            if (workspaceDir.empty)
                workspaceDir = getcwd();
        }

        // allow overriding the workspace location
        if (!enforcedWorkspaceDir.empty)
            workspaceDir = enforcedWorkspaceDir;
        if (!workspaceDir.isAbsolute)
            workspaceDir = workspaceDir.absolutePath;

        this.projectName = "Unknown";
        if ("ProjectName" in root)
            this.projectName = root["ProjectName"].str;

        this.archiveRoot = root["ArchiveRoot"].str;

        this.mediaBaseUrl = "";
        if ("MediaBaseUrl" in root)
            this.mediaBaseUrl = root["MediaBaseUrl"].str;

        this.htmlBaseUrl = "";
        if ("HtmlBaseUrl" in root)
            this.htmlBaseUrl = root["HtmlBaseUrl"].str;

        // set root export directory
        if (enforcedExportDir.empty) {
            exportDir = buildPath(workspaceDir, "export");
        } else {
            exportDir = enforcedExportDir;
            logInfo("Using data export directory root from the command-line: %s", exportDir);
        }
        if (!exportDir.isAbsolute)
            exportDir = exportDir.absolutePath;

        // set the default export directory locations, allow people to override them in the config
        // (we convert the relative to absolute paths later)
        mediaExportDir = "media";
        dataExportDir = "data";
        hintsExportDir = "hints";
        htmlExportDir = "html";

        if ("ExportDirs" in root) {
            auto edirs = root["ExportDirs"].object;
            foreach (dirId; edirs.byKeyValue) {
                switch (dirId.key) {
                    case "Media":
                        mediaExportDir = dirId.value.str;
                        break;
                    case "Data":
                        dataExportDir = dirId.value.str;
                        break;
                    case "Hints":
                        hintsExportDir = dirId.value.str;
                        break;
                    case "Html":
                        htmlExportDir = dirId.value.str;
                        break;
                    default:
                        logWarning("Unknown export directory specifier in config: %s", dirId.key);
                }
            }
        }

        // convert export directory paths to absolute paths if necessary
        mediaExportDir = mediaExportDir.isAbsolute ? mediaExportDir : buildNormalizedPath(exportDir, mediaExportDir);
        dataExportDir = dataExportDir.isAbsolute ? dataExportDir : buildNormalizedPath(exportDir, dataExportDir);
        hintsExportDir = hintsExportDir.isAbsolute ? hintsExportDir : buildNormalizedPath(exportDir, hintsExportDir);
        htmlExportDir = htmlExportDir.isAbsolute ? htmlExportDir : buildNormalizedPath(exportDir, htmlExportDir);

        // a place where external metainfo data can be injected
        auto extraMetainfoDir = buildPath(workspaceDir, "extra-metainfo");
        if ("ExtraMetainfoDir" in root)
            extraMetainfoDir = root["ExtraMetainfoDir"].str;

        if ("CAInfo" in root)
            this.caInfo = root["CAInfo"].str;

        // allow specifying the AppStream format version we build data for.
        if ("FormatVersion" in root) {
            immutable versionStr = root["FormatVersion"].str;

            switch (versionStr) {
                case "0.8":
                    formatVersion = FormatVersion.V0_8;
                    break;
                case "0.9":
                    formatVersion = FormatVersion.V0_9;
                    break;
                case "0.10":
                    formatVersion = FormatVersion.V0_10;
                    break;
                case "0.11":
                    formatVersion = FormatVersion.V0_11;
                    break;
                case "0.12":
                    formatVersion = FormatVersion.V0_12;
                    break;
                default:
                    logWarning("Configuration tried to set unknown AppStream format version '%s'. Falling back to default version.", versionStr);
                    break;
            }
        }

        // we default to the Debian backend for now
        this.metadataType = DataType.XML;
        auto backendId = "debian";
        if ("Backend" in root)
            backendId = root["Backend"].str.toLower;
        switch (backendId) {
            case "dummy":
                this.backendName = "Dummy";
                this.backend = Backend.Dummy;
                this.metadataType = DataType.YAML;
                break;
            case "debian":
                this.backendName = "Debian";
                this.backend = Backend.Debian;
                this.metadataType = DataType.YAML;
                break;
            case "ubuntu":
                this.backendName = "Ubuntu";
                this.backend = Backend.Ubuntu;
                this.metadataType = DataType.YAML;
                break;
            case "arch":
            case "archlinux":
                this.backendName = "Arch Linux";
                this.backend = Backend.Archlinux;
                this.metadataType = DataType.XML;
                break;
            case "mageia":
            case "rpmmd":
                this.backendName = "RpmMd";
                this.backend = Backend.RpmMd;
                this.metadataType = DataType.XML;
                break;
            case "alpinelinux":
                this.backendName = "Alpine Linux";
                this.backend = Backend.Alpinelinux;
                this.metadataType = DataType.XML;
                break;
            case "freebsd":
                this.backendName = "FreeBSD";
                this.backend = Backend.FreeBSD;
                this.metadataType = DataType.XML;
                break;
            default:
                break;
        }

        // override the backend's default metadata type if requested by user
        if ("MetadataType" in root) {
            immutable mdataTypeStr = root["MetadataType"].str.toLower;
            if (mdataTypeStr == "yaml")
                this.metadataType = DataType.YAML;
            else if (mdataTypeStr == "xml")
                this.metadataType = DataType.XML;
            else
                logError("Invalid value '%s' for MetadataType setting.", mdataTypeStr);
        }

        // suite selections
        auto hasImmutableSuites = false;
        foreach (suiteName; root["Suites"].object.byKey) {
            Suite suite;
            suite.name = suiteName;

            // having a suite named "pool" will result in the media pool being copied on
            // itself if immutableSuites is used. Since 'pool' is a bad suite name anyway,
            // we error out early on this.
            if (suiteName == "pool")
                throw new Exception("The name 'pool' is forbidden for a suite.");

            auto sn = root["Suites"][suiteName];
            if ("dataPriority" in sn)
                suite.dataPriority = to!int(sn["dataPriority"].integer);
            if ("baseSuite" in sn)
                suite.baseSuite = sn["baseSuite"].str;
            if ("useIconTheme" in sn)
                suite.iconTheme = sn["useIconTheme"].str;
            if ("sections" in sn)
                foreach (sec; sn["sections"].array)
                    suite.sections ~= sec.str;
            if ("architectures" in sn)
                foreach (arch; sn["architectures"].array)
                    suite.architectures ~= arch.str;
            if ("immutable" in sn) {
                suite.isImmutable = sn["immutable"].type == JSONType.true_;
                if (suite.isImmutable)
                    hasImmutableSuites = true;
            }

            const suiteExtraMIDir = buildNormalizedPath(extraMetainfoDir, suite.name);
            if (suiteExtraMIDir.existsAndIsDir)
                suite.extraMetainfoDir = suiteExtraMIDir;

            suites ~= suite;
        }

        if ("Oldsuites" in root.object) {
            import std.algorithm.iteration : map;

            oldsuites = map!"a.str"(root["Oldsuites"].array).array;
        }

        // icon policy
        if ("Icons" in root.object) {
            import std.algorithm : canFind;
            import ascompose.c.types : IconState;

            auto iconsObj = root["Icons"].object;
            foreach (iconString; iconsObj.byKey) {
                auto iconObj = iconsObj[iconString];

                immutable iconSize = ImageSize(iconString);
                if (!allowedIconSizes.canFind(iconSize)) {
                    logError("Invalid icon size '%s' selected in configuration, icon policy has been ignored.", iconString);
                    continue;
                }
                if (iconSize.width < 0) {
                    logError("Malformed icon size '%s' found in configuration, icon policy has been ignored.", iconString);
                    continue;
                }

                bool storeRemote = false;
                bool storeCached = false;
                if ("remote" in iconObj)
                    storeRemote = iconObj["remote"].type == JSONType.true_;
                if ("cached" in iconObj)
                    storeCached = iconObj["cached"].type == JSONType.true_;

                IconState istate = IconState.IGNORED;
                if (storeRemote && storeCached)
                    istate = IconState.CACHED_REMOTE;
                else if (storeRemote)
                    istate = IconState.REMOTE_ONLY;
                else if (storeCached)
                    istate = IconState.CACHED_ONLY;

                // sanity check
                if (iconSize == ImageSize(64)) {
                    if (!storeCached) {
                        logError("The icon size 64x64 must always be present and be allowed to be cached. Ignored user configuration.");
                        continue;
                    }
                }

                // set new policy, overriding existing one
                iconPolicy.setPolicy(iconSize.width, iconSize.scale, istate);
            }
        }

        this.maxScrFileSize = 14; // 14MiB is the default maximum size
        if ("MaxScreenshotFileSize" in root)
            this.maxScrFileSize = root["MaxScreenshotFileSize"].integer;

        if ("AllowedCustomKeys" in root.object)
            foreach (ref key; root["AllowedCustomKeys"].array)
                allowedCustomKeys[key.str] = true;

        // Enable features which are default-enabled
        feature.processDesktop = true;
        feature.validate = true;
        feature.storeScreenshots = true;
        feature.optipng = true;
        feature.metadataTimestamps = true;
        feature.immutableSuites = true;
        feature.processFonts = true;
        feature.allowIconUpscale = true;
        feature.processGStreamer = true;
        feature.processLocale = true;
        feature.screenshotVideos = true;

        // apply vendor feature settings
        if ("Features" in root.object) {
            auto featuresObj = root["Features"].object;
            foreach (featureId; featuresObj.byKey()) {
                switch (featureId) {
                    case "validateMetainfo":
                        feature.validate = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "processDesktop":
                        feature.processDesktop = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "noDownloads":
                        feature.noDownloads = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "createScreenshotsStore":
                        feature.storeScreenshots = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "optimizePNGSize":
                        feature.optipng = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "metadataTimestamps":
                        feature.metadataTimestamps = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "immutableSuites":
                        feature.immutableSuites = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "processFonts":
                        feature.processFonts = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "allowIconUpscaling":
                        feature.allowIconUpscale = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "processGStreamer":
                        feature.processGStreamer = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "processLocale":
                        feature.processLocale = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "screenshotVideos":
                        feature.screenshotVideos = featuresObj[featureId].type == JSONType.true_;
                        break;
                    case "propagateMetaInfoArtifacts":
                        feature.propagateMetaInfoArtifacts = featuresObj[featureId].type == JSONType.true_;
                        break;
                    default:
                        break;
                }
            }
        }

        // check if we need to disable features because some prerequisites are not met
        if (feature.optipng) {
            if (optipngBinary.empty) {
                feature.optipng = false;
                logError("Disabled feature `optimizePNGSize`: The `optipng` binary was not found.");
            } else {
                logDebug("Using `optipng`: %s", optipngBinary);
            }
        }
        Globals.setUseOptipng(feature.optipng);
        if (feature.screenshotVideos) {
            if (ffprobeBinary.empty) {
                feature.screenshotVideos = false;
                logError("Disabled feature `screenshotVideos`: The `ffprobe` binary was not found.");
            } else {
                logDebug("Using `ffprobe`: %s", ffprobeBinary);
            }
        }

        if (feature.noDownloads) {
            // since disallowing network access might have quite a lot of sideeffects, we print
            // a message to the logs to make debugging easier.
            // in general, running with noDownloads is discouraged.
            logWarning("Configuration does not permit downloading files. Several features will not be available.");
        }

        if (!feature.immutableSuites) {
            // Immutable suites won't work if the feature is disabled - log this error
            if (hasImmutableSuites)
                logError ("Suites are defined as immutable, but the `immutableSuites` feature is disabled. Immutability will not work!");
        }

        if (!feature.validate)
            logWarning ("MetaInfo validation has been disabled in configuration.");

        // sanity check to warn if our GdkPixbuf does not support the minimum amount
        // of image formats we need
        import ascompose.Image : Image;
        import std.string : toStringz;

        auto pbFormatNames = Image.supportedFormatNames();
        if (!pbFormatNames.contains(cast(char*) "png".toStringz) ||
                !pbFormatNames.contains(cast(char*) "svg".toStringz) ||
                !pbFormatNames.contains(cast(char*) "jpeg".toStringz)) {
            logError("The currently used GdkPixbuf does not seem to support all image formats we require to run normally (png/svg/jpeg). " ~
                    "This may be a problem with your installation of appstream-generator or gdk-pixbuf.");
        }
    }

    bool isValid ()
    {
        return this.projectName != null;
    }

    /**
     * Get unique temporary directory to use during one generator run.
     */
    string getTmpDir ()
    {
        synchronized (this) {
            if (tmpDir.empty) {
                string root;
                if (cacheRootDir.empty)
                    root = "/tmp/";
                else
                    root = cacheRootDir;

                tmpDir = buildPath(root, "tmp", format("asgen-%s", randomString(8)));

                // make appstream-compose internal functions aware of the new temp dir
                Globals.setTmpDir(tmpDir);
            }
        }
        return tmpDir;
    }
}
