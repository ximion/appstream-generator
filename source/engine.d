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
import std.algorithm : canFind;
import appstream.Component;

import ag.config;
import ag.logging;
import ag.extractor;
import ag.datacache;
import ag.contentscache;
import ag.result;
import ag.hint;
import ag.reportgenerator;

import ag.backend.intf;
import ag.backend.dummy;
import ag.backend.debian;
import ag.backend.archlinux;

import ag.handlers.iconhandler;


class Engine
{

private:
    Config conf;
    PackageIndex pkgIndex;

    DataCache dcache;
    string exportDir;

public:

    this ()
    {
        this.conf = Config.get ();

        switch (conf.backend) {
            case Backend.Dummy:
                pkgIndex = new DummyPackageIndex (conf.archiveRoot);
                break;
            case Backend.Debian:
                pkgIndex = new DebianPackageIndex (conf.archiveRoot);
                break;
            case Backend.Archlinux:
                pkgIndex = new ArchPackageIndex (conf.archiveRoot);
                break;
            default:
                throw new Exception ("No backend specified, can not continue!");
        }

        // where the final metadata gets stored
        exportDir = buildPath (conf.workspaceDir, "export");

        // create cache in cache directory on workspace
        dcache = new DataCache ();
        dcache.open (conf);
    }

    /**
     * Extract metadata from a software container (usually a distro package).
     * The result is automatically stored in the database.
     */
    private void processPackages (Package[] pkgs, IconHandler iconh)
    {
        GeneratorResult[] results;

        auto mde = new DataExtractor (dcache, iconh);
        foreach (ref pkg; parallel (pkgs, 4)) {
            auto pkid = Package.getId (pkg);
            if (dcache.packageExists (pkid))
                continue;

            auto res = mde.processPackage (pkg);
            synchronized (this) {
                // write resulting data into the database
                dcache.addGeneratorResult (this.conf.metadataType, res);

                logInfo ("Processed %s, components: %s, hints: %s", res.pkid, res.componentsCount (), res.hintsCount ());
            }
        }
    }

    /**
     * Populate the contents index with new contents data. While we are at it, we can also mark
     * some uninteresting packages as to-be-ignored, so we don't waste time on them
     * during the following metadata extraction.
     **/
    private void seedContentsData (Suite suite)
    {
        logInfo ("Scanning new packages.");

        // open package contents cache
        auto ccache = new ContentsCache ();
        ccache.open (conf);

        bool packageInteresting (string[] contents)
        {
            foreach (ref c; contents) {
                if (c.startsWith ("/usr/share/applications/"))
                    return true;
                if (c.startsWith ("/usr/share/metainfo/"))
                    return true;
                if (c.startsWith ("/usr/share/appdata/"))
                    return true;
            }

            return false;
        }

        foreach (section; suite.sections) {
            foreach (arch; suite.architectures) {
                auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);
                if (!suite.baseSuite.empty)
                    pkgs ~= pkgIndex.packagesFor (suite.baseSuite, section, arch);
                foreach (ref pkg; parallel (pkgs, 8)) {
                    auto pkid = Package.getId (pkg);

                    string[] contents;
                    if (ccache.packageExists (pkid)) {
                        if (dcache.packageExists (pkid))
                            continue;
                        // we will complement the main database with ignore data, in case it
                        // went missing.
                        contents = ccache.getContents (pkid);
                    } else {
                        // add contents to the index
                        contents = pkg.contents;
                        ccache.addContents (pkid, contents);
                    }

                    // check if we can already mark this package as ignored, and print some log messages
                    if (!packageInteresting (contents)) {
                        dcache.setPackageIgnore (pkid);
                        logInfo ("Scanned %s, no interesting files found.", pkid);
                    } else {
                        logInfo ("Scanned %s, could be interesting.", pkid);
                    }

                    pkg.close ();
                }

                // do garbage collection run now to immediately free some space after these
                // memory-intensive operations.
                core.memory.GC.collect ();
            }
        }
    }

    private string getMetadataHead (Suite suite, string section)
    {
        string head;
        auto origin = format ("%s-%s-%s", conf.projectName.toLower, suite.name.toLower, section.toLower);

        if (conf.metadataType == DataType.XML) {
            head = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
            head ~= format ("<components version=\"%s\" origin=\"%s\"", conf.appstreamVersion, origin);
            if (suite.dataPriority != 0)
                head ~= format (" priority=\"%s\"", suite.dataPriority);
            if (!conf.mediaBaseUrl.empty ())
                head ~= format (" media_baseurl=\"%s\"", conf.mediaBaseUrl);
            head ~= ">";
        } else {
            head = "---\n";
            head ~= format ("File: DEP-11\n"
                           "Version: '%s'\n"
                           "Origin: %s",
                           conf.appstreamVersion,
                           origin);
            if (!conf.mediaBaseUrl.empty ())
                head ~= format ("\nMediaBaseUrl: %s", conf.mediaBaseUrl);
            if (suite.dataPriority != 0)
                head ~= format ("\nPriority: %s", suite.dataPriority);
        }

        return head;
    }

    /**
     * Export metadata and issue hints from the database and store them as files.
     */
    private void exportData (Suite suite, string section, string arch, Package[] pkgs, bool withIconTar = false)
    {
        import ag.archive;
        string[] mdataEntries;
        string[] hintEntries;

        logInfo ("Exporting data for %s (%s/%s)", suite.name, section, arch);

        // add metadata document header
        mdataEntries ~= getMetadataHead (suite, section);

        // prepare destination
        auto dataExportDir = buildPath (exportDir, "data", suite.name, section);
        auto hintsExportDir = buildPath (exportDir, "hints", suite.name, section);

        mkdirRecurse (dataExportDir);
        mkdirRecurse (hintsExportDir);

        // prepare icon tarball
        immutable iconTarSizes = ["64", "128"];
        ArchiveCompressor[string] iconTar;
        if (withIconTar) {
            foreach (size; iconTarSizes) {
                iconTar[size] = new ArchiveCompressor (ArchiveType.GZIP);
                iconTar[size].open (buildPath (dataExportDir, format ("icons-%sx%s.tar", size, size)));
            }
        }

        // collect metadata, icons and hints for the given packages
        foreach (ref pkg; parallel (pkgs, 100)) {
            auto pkid = Package.getId (pkg);
            auto gcids = dcache.getGCIDsForPackage (pkid);
            if (gcids !is null) {
                auto mres = dcache.getMetadataForPackage (conf.metadataType, pkid);
                if (!mres.empty) {
                    synchronized (this) mdataEntries ~= mres;
                }

                if (withIconTar) {
                    foreach (gcid; gcids) {
                        foreach (size; iconTarSizes) {
                            auto iconDir = buildPath (dcache.mediaExportDir, gcid, "icons", format ("%sx%s", size, size));
                            if (!std.file.exists (iconDir))
                                continue;
                            foreach (path; std.file.dirEntries (iconDir, std.file.SpanMode.shallow, false)) {
                                iconTar[size].addFile (path);
                            }
                        }
                    }
                }
            }

            auto hres = dcache.getHints (pkid);
            if (!hres.empty) {
                synchronized (this) hintEntries ~= hres;
            }
        }

        // finalize icon tarballs
        if (withIconTar) {
            foreach (size; iconTarSizes)
                iconTar[size].close ();
        }

        string dataFname;
        if (conf.metadataType == DataType.XML)
            dataFname = buildPath (dataExportDir, format ("Components-%s.xml", arch));
        else
            dataFname = buildPath (dataExportDir, format ("Components-%s.yml", arch));
        string hintsFname = buildPath (hintsExportDir, format ("Hints-%s.json", arch));

        // write metadata
        logInfo ("Writing metadata for %s/%s [%s]", suite.name, section, arch);
        auto mf = File (dataFname, "w");
        foreach (ref entry; mdataEntries) {
            mf.writeln (entry);
        }
        // add the closing XML tag for XML metadata
        if (conf.metadataType == DataType.XML)
            mf.writeln ("</components>");
        mf.flush ();
        mf.close ();

        // compress metadata
        saveCompressed (dataFname, ArchiveType.GZIP);
        saveCompressed (dataFname, ArchiveType.XZ);
        std.file.remove (dataFname);

        // write hints
        logInfo ("Writing hints for %s/%s [%s]", suite.name, section, arch);
        auto hf = File (hintsFname, "w");
        hf.writeln ("[");
        bool firstLine = true;
        foreach (ref entry; hintEntries) {
            if (firstLine) {
                firstLine = false;
                hf.write (entry);
            } else {
                hf.write (",\n" ~ entry);
            }
        }
        hf.writeln ("\n]");
        hf.flush ();
        hf.close ();

        // compress hints
        saveCompressed (hintsFname, ArchiveType.GZIP);
        saveCompressed (hintsFname, ArchiveType.XZ);
        std.file.remove (hintsFname);
    }

    private Package[string] getIconCandidatePackages (Suite suite, string section, string arch)
    {
        // always load the "main" and "universe" components, which contain most of the icon data
        // on Debian and Ubuntu.
        // FIXME: This is a hack, find a sane way to get rid of this, or at least get rid of the
        // distro-specific hardcoding.
        Package[] pkgs;
        foreach (newSection; ["main", "universe"]) {
            if ((section != newSection) && (suite.sections.canFind (newSection))) {
                pkgs ~= pkgIndex.packagesFor (suite.name, newSection, arch);
                if (!suite.baseSuite.empty)
                    pkgs ~= pkgIndex.packagesFor (suite.baseSuite, newSection, arch);
            }
        }
        if (!suite.baseSuite.empty)
            pkgs ~= pkgIndex.packagesFor (suite.baseSuite, section, arch);
        pkgs ~= pkgIndex.packagesFor (suite.name, section, arch);

        Package[string] pkgMap;
        foreach (ref pkg; pkgs) {
            auto pkid = Package.getId (pkg);
            pkgMap[pkid] = pkg;
        }

        return pkgMap;
    }

    void run (string suite_name)
    {
        Suite suite;
        foreach (s; conf.suites)
            if (s.name == suite_name)
                suite = s;

        Component[] cpts;
        GeneratorHint[string] hints;
        auto reportgen = new ReportGenerator (dcache);

        // update package contents information and flag boring packages as ignored
        seedContentsData (suite);

        foreach (section; suite.sections) {
            Package[] sectionPkgs;
            auto iconTarBuilt = false;
            foreach (arch; suite.architectures) {
                // process new packages
                auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);
                auto iconh = new IconHandler (dcache.mediaExportDir,
                                              getIconCandidatePackages (suite, section, arch),
                                              suite.iconTheme);
                processPackages (pkgs, iconh);

                // export package data
                exportData (suite, section, arch, pkgs, !iconTarBuilt);
                iconTarBuilt = true;

                // we store the package info over all architectures to generate reports later
                sectionPkgs ~= pkgs;

                // log progress
                logInfo ("Completed processing of %s/%s [%s]", suite.name, section, arch);

                // free memory
                core.memory.GC.collect ();
            }

            // write reports & statistics and render HTML, if that option is selected
            reportgen.processFor (suite.name, section, sectionPkgs);

            // do garbage collection run now.
            // we might have allocated very big chunks of memory during this iteration,
            // that we can (mostly) free now - on some machines, the GC runs too late,
            // making the system run out of memory, which ultimately gets us OOM-killed.
            // we don't like that, and give the GC a hint to do the right thing.
            core.memory.GC.collect ();
        }

        // free some memory
        pkgIndex.release ();

        // render index pages & statistics
        reportgen.exportStatistics ();
        reportgen.updateIndexPages ();
    }

    void runCleanup ()
    {
        bool[string] pkgSet;

        logInfo ("Cleaning up superseded data.");
        // build a set of all valid packages
        foreach (ref suite; conf.suites) {
            foreach (string section; suite.sections) {
                foreach (string arch; parallel (suite.architectures)) {
                    auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);
                    synchronized (this) {
                        foreach (ref pkg; pkgs) {
                            auto pkid = Package.getId (pkg);
                            pkgSet[pkid] = true;
                        }
                    }
                }
            }
        }

        // open package contents cache
        auto ccache = new ContentsCache ();
        ccache.open (conf);

        // remove packages from the caches which are no longer in the archive
        ccache.removePackagesNotInSet (pkgSet);
        dcache.removePackagesNotInSet (pkgSet);

        // remove orphaned data and media
        dcache.cleanupCruft ();
    }

    /**
     * Drop all packages which contain valid components or hints
     * from the database.
     * This is useful when big generator changes have been done, which
     * require reprocessing of all components.
     */
    void removeHintsComponents (string suite_name)
    {
        Suite suite;
        foreach (s; conf.suites)
            if (s.name == suite_name)
                suite = s;

        foreach (string section; suite.sections) {
            foreach (string arch; parallel (suite.architectures)) {
                auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);

                foreach (ref pkg; pkgs) {
                    auto pkid = Package.getId (pkg);

                    if (!dcache.packageExists (pkid))
                        continue;
                    if (dcache.isIgnored (pkid))
                        continue;

                    dcache.removePackage (pkid);
                }
            }
        }

        dcache.cleanupCruft ();
    }

}
