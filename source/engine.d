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

module ag.engine;

import std.stdio;
import std.string;
import std.parallelism;
import std.path : buildPath;
import std.file : mkdirRecurse;

import ag.config;
import ag.logging;
import ag.extractor;
import ag.datacache;
import ag.result;
import ag.hint;
import ag.backend.intf;
import ag.backend.debian.pkgindex;
import ag.handlers.iconhandler;
import appstream.Component;


class Engine
{

private:
    Config conf;
    PackagesIndex pkgIndex;
    ContentsIndex contentsIndex;
    DataCache dcache;

    string exportDir;

public:

    this ()
    {
        this.conf = Config.get ();

        switch (conf.backend) {
            case Backend.Debian:
                pkgIndex = new DebianPackagesIndex ();
                break;
            default:
                throw new Exception ("No backend specified, can not continue!");
        }

        // where the final metadata gets stored
        exportDir = buildPath (conf.workspaceDir, "export");

        // create cache in cache directory on workspace
        dcache = new DataCache ();
        dcache.open (buildPath (conf.workspaceDir, "cache"), buildPath (exportDir, "media"));
    }

    /**
     * Extract metadata from a software container (usually a distro package).
     * The result is automatically stored in the database.
     */
    private void processPackages (Package[] pkgs, IconHandler iconh)
    {
        GeneratorResult[] results;

        auto mde = new DataExtractor (dcache, iconh);
        foreach (Package pkg; parallel (pkgs)) {
            auto pkid = Package.getId (pkg);
            if (dcache.packageExists (pkid))
                continue;

            auto res = mde.processPackage (pkg);
            synchronized (this) {
                // write resulting data into the database
                dcache.addGeneratorResult (this.conf.metadataType, res);

                info ("Processed %s, components: %s, hints: %s", res.pkid, res.componentsCount (), res.hintsCount ());
            }
        }
    }

    /**
     * Export metadata and issue hints from the database and store them as files.
     */
    private void exportData (string suiteName, string section, string arch, Package[] pkgs)
    {
        string[] mdataEntries;
        string[] hintEntries;

        foreach (pkg; parallel (pkgs)) {
            auto pkid = Package.getId (pkg);
            auto mres = dcache.getMetadataForPackage (conf.metadataType, pkid);
            if (!mres.empty) {
                synchronized (this) {
                    mdataEntries ~= mres;
                }
            }

            auto hres = dcache.getHints (pkid);
            if (!hres.empty)
                hintEntries ~= hres;
        }

        auto dataExportDir = buildPath (exportDir, "data", suiteName, section);
        auto hintsExportDir = buildPath (exportDir, "hints", suiteName, section);

        mkdirRecurse (dataExportDir);
        mkdirRecurse (hintsExportDir);

        string dataFname;
        if (conf.metadataType == DataType.XML)
            dataFname = buildPath (dataExportDir, format ("Components-%s.xml", arch));
        else
            dataFname = buildPath (dataExportDir, format ("Components-%s.yml", arch));
        string hintsFname = buildPath (hintsExportDir, format ("Hints-%s.json", arch));

        // write metadata
        info ("Writing metadata for %s/%s [%s]", suiteName, section, arch);
        auto mf = File (dataFname, "w");
        foreach (entry; mdataEntries) {
            mf.writeln (entry);
        }
        mf.flush ();
        mf.close ();

        // write hints
        info ("Writing hints for %s/%s [%s]", suiteName, section, arch);
        auto hf = File (hintsFname, "w");
        hf.writeln ("[");
        foreach (entry; hintEntries) {
            hf.writeln (entry);
        }
        hf.writeln ("]");
        hf.flush ();
        hf.close ();
    }

    void generateMetadata (string suite_name)
    {
        Suite suite;
        foreach (Suite s; conf.suites)
            if (s.name == suite_name)
                suite = s;

        Component[] cpts;
        GeneratorHint[string] hints;

        foreach (string section; suite.sections) {
            foreach (string arch; suite.architectures) {
                pkgIndex.open (conf.archiveRoot, suite.name, section, arch);
                scope (exit) pkgIndex.close ();

                // process new packages
                auto pkgs = pkgIndex.getPackages ();
                auto iconh = new IconHandler (dcache.mediaExportDir, null);
                processPackages (pkgs, iconh);

                // export package data
                exportData (suite.name, section, arch, pkgs);
            }
        }
    }
}
