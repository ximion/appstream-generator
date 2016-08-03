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
import std.parallelism;
import std.string : format, count, toLower, startsWith;
import std.array : Appender, appender, empty;
import std.path : buildPath, buildNormalizedPath;
import std.file : mkdirRecurse, rmdirRecurse;
import std.algorithm : canFind, sort, SwapStrategy;
static import core.memory;
static import std.file;
import appstream.Component;

import ag.config;
import ag.logging;
import ag.extractor;
import ag.datastore;
import ag.contentsstore;
import ag.result;
import ag.hint;
import ag.reportgenerator;
import ag.utils : copyDir, stringArrayToByteArray;

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

    DataStore dstore;
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
        exportDir = conf.exportDir;

        // create cache in cache directory on workspace
        dstore = new DataStore ();
        dstore.open (conf);
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
        auto mde = new DataExtractor (dstore, iconh);
        foreach (ref pkg; parallel (pkgs)) {
            immutable pkid = pkg.id;
            if (dstore.packageExists (pkid))
                continue;

            auto res = mde.processPackage (pkg);
            synchronized (this) {
                // write resulting data into the database
                dstore.addGeneratorResult (this.conf.metadataType, res);

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
        bool packageInteresting (const string[] contents)
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
        if ((!pkgIndex.hasChanges (dstore, suite.name, section, arch)) && (!this.forced)) {
            logDebug ("Skipping contents cache update for %s/%s [%s], index has not changed.", suite.name, section, arch);
            return false;
        }

        logInfo ("Scanning new packages for %s/%s [%s]", suite.name, section, arch);

        // open package contents cache
        auto cstore = new ContentsStore ();
        cstore.open (conf);

        // get contents information for packages and add them to the database
        auto interestingFound = false;
        auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);
        if (!suite.baseSuite.empty)
            pkgs ~= pkgIndex.packagesFor (suite.baseSuite, section, arch);
        foreach (ref pkg; parallel (pkgs, 8)) {
            immutable pkid = pkg.id;

            string[] contents;
            if (cstore.packageExists (pkid)) {
                if (dstore.packageExists (pkid)) {
                    // TODO: Unfortunately, packages can move between suites without changing their ID.
                    // This means as soon as we have an interesting package, even if we already processed it,
                    // we need to regenerate the output metadata.
                    // For that to happen, we set interestingFound to true here. Later, a more elegent solution
                    // would be desirable here, ideally one which doesn't force us to track which package is
                    // in which suite as well.
                    if (!dstore.isIgnored (pkid))
                        interestingFound = true;
                    continue;
                }
                // we will complement the main database with ignore data, in case it
                // went missing.
                contents = cstore.getContents (pkid);
            } else {
                // add contents to the index
                contents = pkg.contents;
                cstore.addContents (pkid, contents);
            }

            // check if we can already mark this package as ignored, and print some log messages
            if (!packageInteresting (contents)) {
                dstore.setPackageIgnore (pkid);
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
        version (GNU)
            import core.time : FracSec;
        else
            import core.time : Duration;

        string head;
        immutable origin = "%s-%s-%s".format (conf.projectName.toLower, suite.name.toLower, section.toLower);

        auto time = Clock.currTime ();
        version (GNU)
            time.fracSec = FracSec.zero; // we don't want fractional seconds.
        else
            time.fracSecs = Duration.zero; // for newer Phobos
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
        auto mdataFile = appender!string;
        auto hintsFile = appender!string;

        // reserve some space for our data
        mdataFile.reserve (pkgs.length / 2);
        hintsFile.reserve (240);

        // prepare hints file
        hintsFile ~= "[";

        logInfo ("Exporting data for %s (%s/%s)", suite.name, section, arch);

        // add metadata document header
        mdataFile ~= getMetadataHead (suite, section);
        mdataFile ~= "\n";

        // prepare destination
        immutable dataExportDir = buildPath (exportDir, "data", suite.name, section);
        immutable hintsExportDir = buildPath (exportDir, "hints", suite.name, section);

        mkdirRecurse (dataExportDir);
        mkdirRecurse (hintsExportDir);

        // prepare icon-tarball array
        immutable iconTarSizes = ["64", "128"];
        Appender!(string[])[string] iconTarFiles;
        if (withIconTar) {
            foreach (size; iconTarSizes) {
                iconTarFiles[size] = appender!(string[]);
            }
        }

        immutable useImmutableSuites = conf.featureEnabled (GeneratorFeature.IMMUTABLE_SUITES);
        // select the media export target directory
        string mediaExportDir;
        if (useImmutableSuites)
            mediaExportDir = buildNormalizedPath (dstore.mediaExportPoolDir, "..", suite.name);
        else
            mediaExportDir = dstore.mediaExportPoolDir;

        // collect metadata, icons and hints for the given packages
        bool firstHintEntry = true;
        logDebug ("Building final metadata and hints files.");
        foreach (ref pkg; parallel (pkgs, 100)) {
            immutable pkid = pkg.id;
            auto gcids = dstore.getGCIDsForPackage (pkid);
            if (gcids !is null) {
                auto mres = dstore.getMetadataForPackage (conf.metadataType, pkid);
                if (!mres.empty) {
                    synchronized (this) {
                        foreach (ref md; mres)
                            mdataFile ~= "%s\n".format (md);
                    }
                }

                // nothing left to do if we don't need to deal with icon tarballs and
                // immutable suites.
                if ((!useImmutableSuites) && (!withIconTar))
                    continue;

                foreach (ref gcid; gcids) {
                    // Symlink data from the pool to the suite-specific directories
                    if (useImmutableSuites) {
                        immutable gcidMediaPoolPath = buildPath (dstore.mediaExportPoolDir, gcid);
                        immutable gcidMediaSuitePath = buildPath (mediaExportDir, gcid);
                        if ((!std.file.exists (gcidMediaSuitePath)) && (std.file.exists (gcidMediaPoolPath)))
                            copyDir (gcidMediaPoolPath, gcidMediaSuitePath, true);
                    }

                    // compile list of icon-tarball files
                    if (withIconTar) {
                        foreach (ref size; iconTarSizes) {
                            immutable iconDir = buildPath (mediaExportDir, gcid, "icons", "%sx%s".format (size, size));
                            if (!std.file.exists (iconDir))
                                continue;
                            foreach (path; std.file.dirEntries (iconDir, std.file.SpanMode.shallow, false)) {
                                iconTarFiles[size] ~= path;
                            }
                        }
                    }
                }
            }

            immutable hres = dstore.getHints (pkid);
            if (!hres.empty) {
                synchronized (this) {
                    if (firstHintEntry) {
                        firstHintEntry = false;
                        hintsFile ~= hres;
                    } else {
                        hintsFile ~= ",\n";
                        hintsFile ~= hres;
                    }
                }
            }
        }

        // create the icon tarballs
        if (withIconTar) {
            logDebug ("Creating icon tarball.");
            foreach (size; iconTarSizes) {
                auto iconTar = new ArchiveCompressor (ArchiveType.GZIP);
                iconTar.open (buildPath (dataExportDir, format ("icons-%sx%s.tar.gz", size, size)));
                auto iconFiles = iconTarFiles[size].data;
                sort!("a < b", SwapStrategy.stable)(iconFiles);
                foreach (fname; iconFiles) {
                    iconTar.addFile (fname);
                }
                iconTar.close ();
            }
        }

        string dataBaseFname;
        if (conf.metadataType == DataType.XML)
            dataBaseFname = buildPath (dataExportDir, format ("Components-%s.xml", arch));
        else
            dataBaseFname = buildPath (dataExportDir, format ("Components-%s.yml", arch));
        immutable hintsBaseFname = buildPath (hintsExportDir, format ("Hints-%s.json", arch));

        // write metadata
        logInfo ("Writing metadata for %s/%s [%s]", suite.name, section, arch);

        // add the closing XML tag for XML metadata
        if (conf.metadataType == DataType.XML)
            mdataFile ~= "</components>\n";

        // compress metadata and save it to disk
        auto mdataFileBytes = cast(ubyte[]) mdataFile.data;
        compressAndSave (mdataFileBytes, dataBaseFname ~ ".gz", ArchiveType.GZIP);
        compressAndSave (mdataFileBytes, dataBaseFname ~ ".xz", ArchiveType.XZ);

        // write hints
        logInfo ("Writing hints for %s/%s [%s]", suite.name, section, arch);

        // finalize the JSON hints document
        hintsFile ~= "\n]\n";

        // compress hints
        auto hintsFileBytes = cast(ubyte[]) hintsFile.data;
        compressAndSave (hintsFileBytes, hintsBaseFname ~ ".gz", ArchiveType.GZIP);
        compressAndSave (hintsFileBytes, hintsBaseFname ~ ".xz", ArchiveType.XZ);
    }

    private Package[string] getIconCandidatePackages (Suite suite, string section, string arch)
    {
        // always load the "main" and "universe" components, which contain most of the icon data
        // on Debian and Ubuntu.
        // FIXME: This is a hack, find a sane way to get rid of this, or at least get rid of the
        // distro-specific hardcoding.
        auto pkgs = appender!(Package[]);
        foreach (ref newSection; ["main", "universe"]) {
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
        foreach (ref pkg; pkgs.data) {
            immutable pkid = pkg.id;
            pkgMap[pkid] = pkg;
        }

        return pkgMap;
    }

    void run (string suite_name)
    {
        Suite suite;
        foreach (ref s; conf.suites)
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

        GeneratorHint[string] hints;
        auto reportgen = new ReportGenerator (dstore);

        auto dataChanged = false;
        foreach (ref section; suite.sections) {
            auto sectionPkgs = appender!(Package[]);
            auto iconTarBuilt = false;
            auto suiteDataChanged = false;
            foreach (ref arch; suite.architectures) {
                // update package contents information and flag boring packages as ignored
                immutable foundInteresting = seedContentsData (suite, section, arch);

                // check if the suite/section/arch has actually changed
                if (!foundInteresting) {
                    logInfo ("Skipping %s/%s [%s], no interesting new packages since last update.", suite.name, section, arch);
                    continue;
                }

                // process new packages
                auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);
                auto iconh = new IconHandler (dstore.mediaExportPoolDir,
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
                reportgen.processFor (suite.name, section, sectionPkgs.data);
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

        logInfo ("Cleaning up temporary data.");
        immutable tmpDir = buildPath (conf.cacheRootDir, "tmp");
        if (std.file.exists (tmpDir))
            rmdirRecurse (tmpDir);

        logInfo ("Cleaning up superseded data.");
        // build a set of all valid packages
        foreach (ref suite; conf.suites) {
            foreach (ref section; suite.sections) {
                foreach (ref arch; parallel (suite.architectures)) {
                    auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);
                    synchronized (this) {
                        foreach (ref pkg; pkgs) {
                            pkgSet[pkg.id] = true;
                        }
                    }
                }
            }
        }

        // open package contents cache
        auto cstore = new ContentsStore ();
        cstore.open (conf);

        // remove packages from the caches which are no longer in the archive
        cstore.removePackagesNotInSet (pkgSet);
        dstore.removePackagesNotInSet (pkgSet);

        // remove orphaned data and media
        logInfo ("Cleaning up obsolete media.");
        dstore.cleanupCruft ();

        // cleanup duplicate statistical entries
        auto allStats = dstore.getStatistics ();
        string lastJData;
        size_t lastTime;
        foreach (timestamp; allStats.byKey ()) {
            if (lastTime > timestamp)
                continue;
            auto jdata = allStats[timestamp];
            if (lastJData == jdata) {
                logDebug ("Removing superfluous statistical entry: %s", timestamp);
                dstore.removeStatistics (timestamp);
            }

            lastTime = timestamp;
            lastJData = jdata;
        }
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
        foreach (ref s; conf.suites)
            if (s.name == suite_name)
                suite = s;

        foreach (ref section; suite.sections) {
            foreach (ref arch; parallel (suite.architectures)) {
                auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);

                foreach (ref pkg; pkgs) {
                    auto pkid = pkg.id;

                    if (!dstore.packageExists (pkid))
                        continue;
                    if (dstore.isIgnored (pkid))
                        continue;

                    dstore.removePackage (pkid);
                }
            }
        }

        dstore.cleanupCruft ();
    }

    void forgetPackage (string identifier)
    {
        auto cstore = new ContentsStore ();
        cstore.open (conf);

        if (identifier.count ("/") == 3) {
            // we have a package-id, so we can do a targeted remove
            immutable pkid = identifier;
            logDebug ("Considering %s to be a package-id.", pkid);

            if (cstore.packageExists (pkid))
                cstore.removePackage (pkid);
            if (dstore.packageExists (pkid))
                dstore.removePackage (pkid);
            logInfo ("Removed package with ID: %s", pkid);
        } else {
            auto pkids = dstore.getPkidsMatching (identifier);
            foreach (ref pkid; pkids) {
                dstore.removePackage (pkid);
                if (cstore.packageExists (pkid))
                    cstore.removePackage (pkid);
                logInfo ("Removed package with ID: %s", pkid);
            }
        }

        // remove orphaned data and media
        dstore.cleanupCruft ();
    }
}
