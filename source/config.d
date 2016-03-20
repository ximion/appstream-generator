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

import ag.utils;


struct Suite
{
    string name;
    int dataPriority = 0;
    string baseSuite;
    string[] sections;
    string[] architectures;
}

enum DataType
{
    XML,
    YAML
}

enum Backend
{
    Unknown,
    Debian
}

class Config
{
    string projectName;
    string archiveRoot;
    string mediaBaseUrl;
    string htmlBaseUrl;
    Backend backend;
    Suite[] suites;
    DataType metadataType;

    string workspaceDir;

    private string tmpDir;

    // Thread local
    private static bool instantiated_;

    // Thread global
    private __gshared Config instance_;

    static Config get()
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

    private this () { }

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

        // we default to the Debian backend for now
        auto backendName = "debian";
        if ("Backend" in root)
            backendName = root["Backend"].str.toLower ();
        switch (backendName) {
            case "debian":
                this.backend = Backend.Debian;
                this.metadataType = DataType.YAML;
                break;
            default:
                break;
        }

        foreach (suiteName; root["Suites"].object.byKey ()) {
            Suite suite;
            suite.name = suiteName;
            auto sn = root["Suites"][suiteName];
            if ("dataPriority" in sn)
                suite.dataPriority = to!int (sn["dataPriority"].integer);
            if ("baseSuite" in sn)
                suite.baseSuite = sn["baseSuite"].str;
            if ("sections" in sn)
                foreach (sec; sn["sections"].array)
                    suite.sections ~= sec.str;
            if ("architectures" in sn)
                foreach (arch; sn["architectures"].array)
                    suite.architectures ~= arch.str;

            suites ~= suite;
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
