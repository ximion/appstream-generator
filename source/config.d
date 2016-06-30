/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
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

module ag.config;

import std.stdio;
import std.array;
import std.string : format, toLower;
import std.path : dirName, getcwd;
import std.json;
import std.typecons;

import ag.utils;
import ag.logging;


public immutable generatorVersion = "0.4";

/**
 * Describes a suite in a software repository.
 **/
struct Suite
{
    string name;
    int dataPriority = 0;
    string baseSuite;
    string iconTheme;
    string[] sections;
    string[] architectures;
}

/**
 * The AppStream metadata type we want to generate.
 **/
enum DataType
{
    XML,
    YAML
}

/**
 * Distribution-specific backends.
 **/
enum Backend
{
    Unknown,
    Dummy,
    Debian,
    Archlinux
}

enum GeneratorFeature
{
    NONE = 0,
    PROCESS_DESKTOP     = 1 << 0,
    VALIDATE            = 1 << 1,
    NO_DOWNLOADS        = 1 << 2,
    STORE_SCREENSHOTS   = 1 << 3,
    OPTIPNG             = 1 << 4,
    METADATA_TIMESTAMPS = 1 << 5,
    IMMUTABLE_SUITES    = 1 << 6
}

class Config
{
    immutable string appstreamVersion;
    string projectName;
    string archiveRoot;
    string mediaBaseUrl;
    string htmlBaseUrl;

    Backend backend;
    Suite[] suites;
    DataType metadataType;
    uint enabledFeatures; // bitfield

    string workspaceDir;

    string caInfo;
    private string tmpDir;

    // Thread local
    private static bool instantiated_;

    // Thread global
    private __gshared Config instance_;

    static Config get ()
    {
        if (!instantiated_) {
            synchronized (Config.classinfo) {
                if (!instance_)
                    instance_ = new Config ();

                instantiated_ = true;
            }
        }

        return instance_;
    }

    private this () {
        appstreamVersion = "0.8";
    }

    private void setFeature (GeneratorFeature feature, bool enabled)
    {
        if (enabled)
            enabledFeatures |= feature;
        else
            disableFeature (feature);
    }

    private void disableFeature (GeneratorFeature feature)
    {
        enabledFeatures &= ~feature;
    }

    bool featureEnabled (GeneratorFeature feature)
    {
        return (enabledFeatures & feature) > 0;
    }

    void loadFromFile (string fname)
    {
        // read the configuration JSON file
        auto f = File (fname, "r");
        string jsonData;
        string line;
        while ((line = f.readln ()) !is null)
            jsonData ~= line;

        JSONValue root = parseJSON (jsonData);

        workspaceDir = dirName (fname);
        if (workspaceDir.empty)
            workspaceDir = getcwd ();

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

        this.metadataType = DataType.XML;
        if ("MetadataType" in root)
            if (root["MetadataType"].str.toLower () == "yaml")
                this.metadataType = DataType.YAML;

        if ("CAInfo" in root)
            this.caInfo = root["CAInfo"].str;

        // we default to the Debian backend for now
        auto backendName = "debian";
        if ("Backend" in root)
            backendName = root["Backend"].str.toLower ();
        switch (backendName) {
            case "dummy":
                this.backend = Backend.Dummy;
                this.metadataType = DataType.YAML;
                break;
            case "debian":
                this.backend = Backend.Debian;
                this.metadataType = DataType.YAML;
                break;
            case "arch":
            case "archlinux":
                this.backend = Backend.Archlinux;
                this.metadataType = DataType.XML;
                break;
            default:
                break;
        }

        foreach (suiteName; root["Suites"].object.byKey ()) {
            Suite suite;
            suite.name = suiteName;

            // having a suite named "pool" will result in the media pool being copied on
            // itself if immutableSuites is used. Since 'pool' is a bad suite name anyway,
            // we error out early on this.
            if (suiteName == "pool")
                throw new Exception ("The name 'pool' is forbidden for a suite.");

            auto sn = root["Suites"][suiteName];
            if ("dataPriority" in sn)
                suite.dataPriority = to!int (sn["dataPriority"].integer);
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

            suites ~= suite;
        }

        // Enable features which are default-enabled
        setFeature (GeneratorFeature.PROCESS_DESKTOP, true);
        setFeature (GeneratorFeature.VALIDATE, true);
        setFeature (GeneratorFeature.STORE_SCREENSHOTS, true);
        setFeature (GeneratorFeature.OPTIPNG, true);
        setFeature (GeneratorFeature.METADATA_TIMESTAMPS, true);
        setFeature (GeneratorFeature.IMMUTABLE_SUITES, true);

        // apply vendor feature settings
        if ("Features" in root.object) {
            auto featuresObj = root["Features"].object;
            foreach (featureId; featuresObj.byKey ()) {
                switch (featureId) {
                    case "validateMetainfo":
                        setFeature (GeneratorFeature.VALIDATE, featuresObj[featureId].type == JSON_TYPE.TRUE);
                        break;
                    case "processDesktop":
                        setFeature (GeneratorFeature.PROCESS_DESKTOP, featuresObj[featureId].type == JSON_TYPE.TRUE);
                        break;
                    case "noDownloads":
                            setFeature (GeneratorFeature.NO_DOWNLOADS, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "createScreenshotsStore":
                            setFeature (GeneratorFeature.STORE_SCREENSHOTS, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "optimizePNGSize":
                            setFeature (GeneratorFeature.OPTIPNG, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "metadataTimestamps":
                            setFeature (GeneratorFeature.METADATA_TIMESTAMPS, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "immutableSuites":
                            setFeature (GeneratorFeature.METADATA_TIMESTAMPS, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    default:
                        break;
                }
            }
        }

        // check if we need to disable features because some prerequisites are not met
        if (featureEnabled (GeneratorFeature.OPTIPNG)) {
            if (!std.file.exists ("/usr/bin/optipng")) {
                setFeature (GeneratorFeature.OPTIPNG, false);
                logError ("Disabled feature 'optimizePNGSize': The `optipng` binary was not found.");
            }
        }

        if (featureEnabled (GeneratorFeature.NO_DOWNLOADS)) {
            // since disallowing network access might have quite a lot of sideeffects, we print
            // a message to the logs to make debugging easier.
            // in general, running with noDownloads is discouraged.
            logWarning ("Configuration does not permit downloading files. Several features will not be available.");
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
        import std.file;
        import std.path;

        if (tmpDir.empty) {
            synchronized (this) {
                tmpDir = buildPath (tempDir (), format ("asgen-%s", randomString (8)));
            }
        }

        return tmpDir;
    }
}
