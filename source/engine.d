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
import std.path : buildPath, buildNormalizedPath;
import std.file : mkdirRecurse;
import std.algorithm : canFind, sort, SwapStrategy;
static import core.memory;
static import std.file;
import appstream.Component;

import ag.config;
import ag.logging;
import ag.extractor;
import ag.datacache;
import ag.contentscache;
import ag.result;
import ag.hint;
import ag.reportgenerator;
import ag.utils : copyDir;

import ag.backend.intf;
import ag.backend.dummy;
import ag.backend.debian;
import ag.backend.archlinux;
import ag.backend.rpmmd;

import ag.handlers.iconhandler;


class Engine
{

private:
    Config conf;
    PackageIndex pkgIndex;

    DataCache dcache;
    string exportDir;

    bool m_forced;

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
            case Backend.RpmMd:
                pkgIndex = new RPMPackageIndex (conf.archiveRoot);
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

    @property
    bool forced ()
    {
        return m_forced;
    }

    @property
    void forced (bool v)
    {
        m_forced = v;
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

            // we don't need this package anymore
            pkg.close ();
        }
    }

    /**
     * Populate the contents index with new contents data. While we are at it, we can also mark
     * some uninteresting packages as to-be-ignored, so we don't waste time on them
     * during the following metadata extraction.
     *
     * Returns: True in case we have new interesting packages, false otherwise.
     **/
    private bool seedContentsData (Suite suite, string section, string arch)
    {
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

        // check if the index has changed data, skip the update if there's nothing new
        if ((!pkgIndex.hasChanges (dcache, suite.name, section, arch)) && (!this.forced)) {
            logDebug ("Skipping contents cache update for %s/%s [%s], index has not changed.", suite.name, section, arch);
            return false;
        }

        logInfo ("Scanning new packages for %s/%s [%s]", suite.name, section, arch);

        // open package contents cache
        auto ccache = new ContentsCache ();
        ccache.open (conf);

        // get contents information for packages and add them to the database
        auto interestingFound = false;
        auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);
        if (!suite.baseSuite.empty)
            pkgs ~= pkgIndex.packagesFor (suite.baseSuite, section, arch);
        foreach (ref pkg; parallel (pkgs, 8)) {
            immutable pkid = Package.getId (pkg);

            string[] contents;
            if (ccache.packageExists (pkid)) {
                if (dcache.packageExists (pkid)) {
                    // TODO: Unfortunately, packages can move between suites without changing their ID.
                    // This means as soon as we have an interesting package, even if we already processed it,
                    // we need to regenerate the output metadata.
                    // For that to happen, we set interestingFound to true here. Later, a more elegent solution
                    // would be desirable here, ideally one which doesn't force us to track which package is
                    // in which suite as well.
                    if (!dcache.isIgnored (pkid))
                        interestingFound = true;
                    continue;
                }
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
                // we won't use this anymore
                pkg.close ();
            } else {
                logInfo ("Scanned %s, could be interesting.", pkid);
                interestingFound = true;
            }
        }

        return interestingFound;
    }

    private string getMetadataHead (Suite suite, string section)
    {
        import std.datetime : Clock;
        import core.time : FracSec;

        string head;
        immutable origin = "%s-%s-%s".format (conf.projectName.toLower, suite.name.toLower, section.toLower);

        auto time = Clock.currTime ();
        time.fracSec = FracSec.zero; // we don't want fractional seconds. FIXME: this is "fracSecs" in newer Phobos (must be adjusted on upgrade)
        immutable timeStr = time.toISOString ();

        string mediaPoolUrl = buildPath (conf.mediaBaseUrl, "pool");
        if (conf.featureEnabled (GeneratorFeature.IMMUTABLE_SUITES)) {
            mediaPoolUrl = buildPath (conf.mediaBaseUrl, suite.name);
        }

        if (conf.metadataType == DataType.XML) {
            head = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
            head ~= format ("<components version=\"%s\" origin=\"%s\"", conf.appstreamVersion, origin);
            if (suite.dataPriority != 0)
                head ~= format (" priority=\"%s\"", suite.dataPriority);
            if (!conf.mediaBaseUrl.empty ())
                head ~= format (" media_baseurl=\"%s\"", mediaPoolUrl);
            if (conf.featureEnabled (GeneratorFeature.METADATA_TIMESTAMPS))
                head ~= format (" time=\"%s\"", timeStr);
            head ~= ">";
        } else {
            head = "---\n";
            head ~= format ("File: DEP-11\n"
                           "Version: '%s'\n"
                           "Origin: %s",
                           conf.appstreamVersion,
                           origin);
            if (!conf.mediaBaseUrl.empty ())
                head ~= format ("\nMediaBaseUrl: %s", mediaPoolUrl);
            if (suite.dataPriority != 0)
                head ~= format ("\nPriority: %s", suite.dataPriority);
            if (conf.featureEnabled (GeneratorFeature.METADATA_TIMESTAMPS))
                head ~= format ("\nTime: %s", timeStr);
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
        immutable dataExportDir = buildPath (exportDir, "data", suite.name, section);
        immutable hintsExportDir = buildPath (exportDir, "hints", suite.name, section);

        mkdirRecurse (dataExportDir);
        mkdirRecurse (hintsExportDir);

        // prepare icon-tarball array
        immutable iconTarSizes = ["64", "128"];
        string[][string] iconTarFiles;
        if (withIconTar) {
            foreach (size; iconTarSizes) {
                iconTarFiles[size] = [];
            }
        }

        immutable useImmutableSuites = conf.featureEnabled (GeneratorFeature.IMMUTABLE_SUITES);
        // select the media export target directory
        string mediaExportDir;
        if (useImmutableSuites)
            mediaExportDir = buildNormalizedPath (dcache.mediaExportPoolDir, "..", suite.name);
        else
            mediaExportDir = dcache.mediaExportPoolDir;

        // collect metadata, icons and hints for the given packages
        foreach (ref pkg; parallel (pkgs, 100)) {
            immutable pkid = Package.getId (pkg);
            auto gcids = dcache.getGCIDsForPackage (pkid);
            if (gcids !is null) {
                auto mres = dcache.getMetadataForPackage (conf.metadataType, pkid);
                if (!mres.empty) {
                    synchronized (this) mdataEntries ~= mres;
                }

                // nothing left to do if we don't need to deal with icon tarballs and
                // immutable suites.
                if ((!useImmutableSuites) && (!withIconTar))
                    continue;

                foreach (gcid; gcids) {
                    // Symlink data from the pool to the suite-specific directories
                    if (useImmutableSuites) {
                        immutable gcidMediaPoolPath = buildPath (dcache.mediaExportPoolDir, gcid);
                        immutable gcidMediaSuitePath = buildPath (mediaExportDir, gcid);
                        if ((!std.file.exists (gcidMediaSuitePath)) && (std.file.exists (gcidMediaPoolPath)))
                            copyDir (gcidMediaPoolPath, gcidMediaSuitePath, true);
                    }

                    // compile list of icon-tarball files
                    if (withIconTar) {
                        foreach (size; iconTarSizes) {
                            immutable iconDir = buildPath (mediaExportDir, gcid, "icons", format ("%sx%s", size, size));
                            if (!std.file.exists (iconDir))
                                continue;
                            foreach (path; std.file.dirEntries (iconDir, std.file.SpanMode.shallow, false)) {
                                iconTarFiles[size] ~= path;
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

        // create the icon tarballs
        if (withIconTar) {
            foreach (size; iconTarSizes) {
                auto iconTar = new ArchiveCompressor (ArchiveType.GZIP);
                iconTar.open (buildPath (dataExportDir, format ("icons-%sx%s.tar.gz", size, size)));
                sort!("a < b", SwapStrategy.stable)(iconTarFiles[size]);
                foreach (fname; iconTarFiles[size]) {
                    iconTar.addFile (fname);
                }
                iconTar.close ();
            }
        }

        string dataFname;
        if (conf.metadataType == DataType.XML)
            dataFname = buildPath (dataExportDir, format ("Components-%s.xml", arch));
        else
            dataFname = buildPath (dataExportDir, format ("Components-%s.yml", arch));
        immutable hintsFname = buildPath (hintsExportDir, format ("Hints-%s.json", arch));

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
            immutable pkid = Package.getId (pkg);
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

        if (suite.isImmutable) {
            // we also can't process anything if there are no architectures defined
            logError ("Suite '%s' is marked as immutable. No changes are allowed.", suite.name);
            return;
        }

        if (suite.sections.empty) {
            // if we have no sections, we can't do anything but exit...
            logError ("Suite '%s' has no sections. Can not continue.", suite_name);
            return;
        }

        if (suite.architectures.empty) {
            // we also can't process anything if there are no architectures defined
            logError ("Suite '%s' has no architectures defined. Can not continue.", suite.name);
            return;
        }

        Component[] cpts;
        GeneratorHint[string] hints;
        auto reportgen = new ReportGenerator (dcache);

        auto dataChanged = false;
        foreach (section; suite.sections) {
            Package[] sectionPkgs;
            auto iconTarBuilt = false;
            auto suiteDataChanged = false;
            foreach (arch; suite.architectures) {
                // update package contents information and flag boring packages as ignored
                immutable foundInteresting = seedContentsData (suite, section, arch);

                // check if the suite/section/arch has actually changed
                if (!foundInteresting) {
                    logInfo ("Skipping %s/%s [%s], no interesting new packages last update.", suite.name, section, arch);
                    continue;
                }

                // process new packages
                auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);
                auto iconh = new IconHandler (dcache.mediaExportPoolDir,
                                              getIconCandidatePackages (suite, section, arch),
                                              suite.iconTheme);
                processPackages (pkgs, iconh);

                // export package data
                exportData (suite, section, arch, pkgs, !iconTarBuilt);
                iconTarBuilt = true;
                suiteDataChanged = true;

                // we store the package info over all architectures to generate reports later
                sectionPkgs ~= pkgs;

                // log progress
                logInfo ("Completed processing of %s/%s [%s]", suite.name, section, arch);

                // free memory
                core.memory.GC.collect ();
            }

            // write reports & statistics and render HTML, if that option is selected
            if (suiteDataChanged) {
                reportgen.processFor (suite.name, section, sectionPkgs);
                dataChanged = true;
            }

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
        reportgen.updateIndexPages ();
        if (dataChanged)
            reportgen.exportStatistics ();
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

    void forgetPackage (string identifier)
    {
        auto ccache = new ContentsCache ();
        ccache.open (conf);

        if (identifier.count ("/") == 3) {
            // we have a package-id, so we can do a targeted remove
            auto pkid = identifier;
            logDebug ("Considering %s to be a package-id.", pkid);

            if (ccache.packageExists (pkid))
                ccache.removePackage (pkid);
            if (dcache.packageExists (pkid))
                dcache.removePackage (pkid);
            logInfo ("Removed package with ID: %s", pkid);
        } else {
            auto pkids = dcache.getPkidsMatching (identifier);
            foreach (pkid; pkids) {
                dcache.removePackage (pkid);
                if (ccache.packageExists (pkid))
                    ccache.removePackage (pkid);
                logInfo ("Removed package with ID: %s", pkid);
            }
        }

        // remove orphaned data and media
        dcache.cleanupCruft ();
    }
}
