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
import dyaml.all;

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
        // read the configuration YAML file
        Node root = Loader(fname).load ();

        workspaceDir = dirName (fname);
        if (workspaceDir.empty)
            workspaceDir = getcwd ();

        this.projectName = "Unknown";
        if (root.containsKey("ProjectName"))
            this.projectName = root["ProjectName"].as!string;

        this.archiveRoot = root["ArchiveRoot"].as!string;

        this.mediaBaseUrl = "";
        if (root.containsKey("MediaBaseUrl"))
            this.mediaBaseUrl = root["MediaBaseUrl"].as!string;

        this.htmlBaseUrl = "";
        if (root.containsKey("HtmlBaseUrl"))
            this.htmlBaseUrl = root["HtmlBaseUrl"].as!string;

        this.metadataType = DataType.XML;
        if (root.containsKey("MetadataType"))
            if (root["MetadataType"].as!string.toLower () == "yaml")
                this.metadataType = DataType.YAML;

        this.backend = Backend.Debian;
        if (root.containsKey("Backend")) {
            auto backendName = root["Backend"].as!string.toLower ();
            switch (backendName) {
                case "debian":
                    this.backend = Backend.Debian;
                    break;
                default:
                    break;
            }
        }

        int iterSuites (ref string suiteName, ref Node prop)
        {
            Suite suite;
            suite.name = suiteName;
            if (prop.containsKey("dataPriority"))
                suite.dataPriority = prop["dataPriority"].as!int;
            if (prop.containsKey("baseSuite"))
                suite.baseSuite = prop["baseSuite"].as!string;
            if (prop.containsKey("sections"))
                foreach (string sec; prop["sections"])
                    suite.sections ~= sec;
            if (prop.containsKey("architectures"))
                foreach (string arch; prop["architectures"])
                    suite.architectures ~= arch;

            suites ~= suite;
            // never stop
            return 0;
        }

        root["Suites"].opApply (&iterSuites);
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
