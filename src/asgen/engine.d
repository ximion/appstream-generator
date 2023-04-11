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

module asgen.engine;

import std.parallelism : parallel;
import std.string : format, count, toLower, startsWith;
import std.array : Appender, appender, empty;
import std.path : buildPath, buildNormalizedPath;
import std.file : mkdirRecurse, rmdirRecurse;
import std.algorithm : canFind, sort, SwapStrategy;
import std.typecons : scoped, Nullable, Tuple;
import std.conv : to;
static import std.file;
import appstream.Component;

import asgen.config;
import asgen.logging;
import asgen.extractor;
import asgen.datastore;
import asgen.contentsstore;
import asgen.result;
import asgen.hint;
import asgen.reportgenerator;
import asgen.localeunit : LocaleUnit;
import asgen.cptmodifiers : InjectedModifications;
import asgen.utils : copyDir, stringArrayToByteArray, getCidFromGlobalID;
import asgen.defines : HAVE_RPMMD;

import asgen.backends.interfaces;
import asgen.backends.dummy;
import asgen.backends.debian;
import asgen.backends.ubuntu;
import asgen.backends.archlinux;
import asgen.backends.alpinelinux;
static if (HAVE_RPMMD) import asgen.backends.rpmmd;


import asgen.iconhandler : IconHandler;


/**
 * Class orchestrating the whole metadata extraction
 * and publication process.
 */
final class Engine
{

private:
    Config conf;
    PackageIndex pkgIndex;

    DataStore dstore;
    ContentsStore cstore;

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
            case Backend.Ubuntu:
                pkgIndex = new UbuntuPackageIndex (conf.archiveRoot);
                break;
            case Backend.Archlinux:
                pkgIndex = new ArchPackageIndex (conf.archiveRoot);
                break;
            case Backend.RpmMd:
                static if (HAVE_RPMMD) {
                    pkgIndex = new RPMPackageIndex (conf.archiveRoot);
                    break;
                } else {
                    throw new Exception ("This appstream-generator was built without support for RPM-MD!");
                }
            case Backend.Alpinelinux:
                pkgIndex = new AlpinePackageIndex (conf.archiveRoot);
                break;
            default:
                throw new Exception ("No backend specified, can not continue!");
        }

        // load global registry of issue hint templates
        loadHintsRegistry ();

        // create cache in cache directory on workspace
        dstore = new DataStore ();
        dstore.open (conf);

        // open package contents cache
        cstore = new ContentsStore ();
        cstore.open (conf);
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

    private void gcCollect ()
    {
        static import core.memory;
        logDebug ("GC collection cycle triggered explicitly.");
        core.memory.GC.collect ();
    }

    private void logVersionInfo ()
    {
        import asgen.defines : ASGEN_VERSION;
        static import appstream.Utils;
        alias AsUtils = appstream.Utils.Utils;

        string backendInfo = "";
        if (!conf.backendName.empty)
            backendInfo = " [%s]".format (conf.backendName);
        logInfo ("AppStream Generator %s, AS: %s%s", ASGEN_VERSION, AsUtils.appstreamVersion, backendInfo);
    }

    /**
     * Extract metadata from a software container (usually a distro package).
     * The result is automatically stored in the database.
     */
    private void processPackages (ref Package[] pkgs, IconHandler iconh, InjectedModifications injMods)
    {
        import std.range : chunks;
        import glib.Thread : Thread;

        auto localeUnit = new LocaleUnit (cstore, pkgs);

        size_t chunkSize = pkgs.length / Thread.getNumProcessors () / 10;
        if (chunkSize > 100)
            chunkSize = 100;
        if (chunkSize <= 10)
            chunkSize = 10;
        logDebug ("Analyzing %s packages in batches of %s", pkgs.length, chunkSize);

        foreach (pkgsChunk; parallel (pkgs.chunks (chunkSize), 1)) {
            auto mde = new DataExtractor (dstore,
                                          iconh,
                                          localeUnit,
                                          injMods);

            foreach (ref pkg; pkgsChunk) {
                immutable pkid = pkg.id;
                if (dstore.packageExists (pkid))
                    continue;

                auto res = mde.processPackage (pkg);
                synchronized (dstore) {
                    // write resulting data into the database
                    dstore.addGeneratorResult (this.conf.metadataType, res);

                    logInfo ("Processed %s, components: %s, hints: %s",
                            res.pkid, res.componentsCount (), res.hintsCount ());
                }

                // we don't need content data from this package anymore
                pkg.finish ();
            }
        }
    }

    /**
     * Populate the contents index with new contents data. While we are at it, we can also mark
     * some uninteresting packages as to-be-ignored, so we don't waste time on them
     * during the following metadata extraction.
     *
     * Returns: True in case we have new interesting packages, false otherwise.
     **/
    private bool seedContentsData (Suite suite, string section, string arch, Package[] pkgs = [])
    {
        import glib.Thread : Thread;

        bool packageInteresting (Package pkg)
        {
            auto contents = pkg.contents;
            foreach (ref c; contents) {
                if (c.startsWith ("/usr/share/applications/"))
                    return true;
                if (c.startsWith ("/usr/share/metainfo/"))
                    return true;
            }

            if (pkg.gst.isNull)
                return false;
            return pkg.gst.get.isNotEmpty;
        }

        size_t workUnitSize = Thread.getNumProcessors * 2;
        if (workUnitSize >= pkgs.length)
            workUnitSize = 4;
        if (workUnitSize > 30)
            workUnitSize = 30;
        logDebug ("Scanning %s packages, work unit size %s", pkgs.length, workUnitSize);

        // check if the index has changed data, skip the update if there's nothing new
        if ((pkgs.empty) && (!pkgIndex.hasChanges (dstore, suite.name, section, arch)) && (!this.forced)) {
            logDebug ("Skipping contents cache update for %s/%s [%s], index has not changed.", suite.name, section, arch);
            return false;
        }

        logInfo ("Scanning new packages for %s/%s [%s]", suite.name, section, arch);

        if (pkgs.empty)
            pkgs = pkgIndex.packagesFor (suite.name, section, arch);

        // get contents information for packages and add them to the database
        auto interestingFound = false;

        // First get the contents (only) of all packages in the base suite
        if (!suite.baseSuite.empty) {
            logInfo ("Scanning new packages for base suite %s/%s [%s]", suite.baseSuite, section, arch);
            auto baseSuitePkgs = pkgIndex.packagesFor (suite.baseSuite, section, arch);
            foreach (ref pkg; parallel (baseSuitePkgs, workUnitSize)) {
                immutable pkid = pkg.id;

                if (!cstore.packageExists (pkid)) {
                    cstore.addContents (pkid, pkg.contents);
                    logInfo ("Scanned %s for base suite.", pkid);
                }

                // chances are that we might never want to extract data from these packages,
                // so remove their temporary data for now - we can reopen the packages later if we actually need them.
                pkg.cleanupTemp ();
            }
        }

        // And then scan the suite itself - here packages can be 'interesting'
        // in that they might end up in the output.
        foreach (ref pkg; parallel (pkgs, workUnitSize)) {
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
            if (!packageInteresting (pkg)) {
                dstore.setPackageIgnore (pkid);
                logInfo ("Scanned %s, no interesting files found.", pkid);
                // we won't use this anymore
                pkg.finish ();
            } else {
                logInfo ("Scanned %s, could be interesting.", pkid);
                interestingFound = true;
            }
        }

        // ensure the contents store is in a consistent state on disk,
        // since it might be accessed from other threads after this function
        // is run.
        cstore.sync ();

        return interestingFound;
    }

    private string getMetadataHead (Suite suite, string section)
    {
        import std.datetime : Clock;
        import core.time : Duration;

        string head;
        immutable origin = "%s-%s-%s".format (conf.projectName.toLower, suite.name.toLower, section.toLower);

        auto time = Clock.currTime ();
        time.fracSecs = Duration.zero; // we don't want fractional seconds
        immutable timeStr = time.toISOString ();

        string mediaPoolUrl = buildPath (conf.mediaBaseUrl, "pool");
        if (conf.feature.immutableSuites) {
            mediaPoolUrl = buildPath (conf.mediaBaseUrl, suite.name);
        }

        immutable mediaBaseUrlAllowed = !conf.mediaBaseUrl.empty && conf.feature.storeScreenshots;
        if (conf.metadataType == DataType.XML) {
            head = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
            head ~= format ("<components version=\"%s\" origin=\"%s\"", conf.formatVersionStr, origin);
            if (suite.dataPriority != 0)
                head ~= format (" priority=\"%s\"", suite.dataPriority);
            if (mediaBaseUrlAllowed)
                head ~= format (" media_baseurl=\"%s\"", mediaPoolUrl);
            if (conf.feature.metadataTimestamps)
                head ~= format (" time=\"%s\"", timeStr);
            head ~= ">";
        } else {
            head = "---\n";
            head ~= format ("File: DEP-11\n" ~
                            "Version: '%s'\n" ~
                            "Origin: %s",
                            conf.formatVersionStr,
                            origin);
            if (mediaBaseUrlAllowed)
                head ~= format ("\nMediaBaseUrl: %s", mediaPoolUrl);
            if (suite.dataPriority != 0)
                head ~= format ("\nPriority: %s", suite.dataPriority);
            if (conf.feature.metadataTimestamps)
                head ~= format ("\nTime: %s", timeStr);
        }

        return head;
    }

    /**
     * Export metadata and issue hints from the database and store them as files.
     */
    private void exportMetadata (Suite suite, string section, string arch, ref Package[] pkgs)
    {
        import asgen.zarchive : ArchiveType, compressAndSave;

        auto mdataFile = appender!string;
        auto hintsFile = appender!string;

        // reserve some space for our data
        mdataFile.reserve (pkgs.length / 2);
        hintsFile.reserve (512);

        // prepare hints file
        hintsFile ~= "[";

        logInfo ("Exporting data for %s (%s/%s)", suite.name, section, arch);

        // add metadata document header
        mdataFile ~= getMetadataHead (suite, section);
        mdataFile ~= "\n";

        // prepare destination
        immutable dataExportDir = buildPath (conf.dataExportDir, suite.name, section);
        immutable hintsExportDir = buildPath (conf.hintsExportDir, suite.name, section);

        mkdirRecurse (dataExportDir);
        mkdirRecurse (hintsExportDir);

        immutable useImmutableSuites = conf.feature.immutableSuites;
        // select the media export target directory
        string mediaExportDir;
        if (useImmutableSuites)
            mediaExportDir = buildNormalizedPath (dstore.mediaExportPoolDir, "..", suite.name);
        else
            mediaExportDir = dstore.mediaExportPoolDir;

        // collect metadata, icons and hints for the given packages
        string[string] cidGcidMap;
        bool firstHintEntry = true;
        logDebug ("Building final metadata and hints files.");
        foreach (ref pkg; parallel (pkgs)) {
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

                foreach (ref gcid; gcids) {
                    synchronized (this) cidGcidMap[getCidFromGlobalID (gcid)] = gcid;

                    // Symlink data from the pool to the suite-specific directories
                    if (useImmutableSuites) {
                        immutable gcidMediaPoolPath = buildPath (dstore.mediaExportPoolDir, gcid);
                        immutable gcidMediaSuitePath = buildPath (mediaExportDir, gcid);
                        if ((!std.file.exists (gcidMediaSuitePath)) && (std.file.exists (gcidMediaPoolPath)))
                            copyDir (gcidMediaPoolPath, gcidMediaSuitePath, true);
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

        string dataBaseFname;
        if (conf.metadataType == DataType.XML)
            dataBaseFname = buildPath (dataExportDir, format ("Components-%s.xml", arch));
        else
            dataBaseFname = buildPath (dataExportDir, format ("Components-%s.yml", arch));
        immutable cidIndexFname = buildPath (dataExportDir, format ("CID-Index-%s.json", arch));
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

        // component ID index
        import std.json : JSONValue, toJSON;
        auto cidIndexJson = JSONValue (cidGcidMap);
        auto cidIndexData = cast(ubyte[]) cidIndexJson.toJSON (true);
        compressAndSave (cidIndexData, cidIndexFname ~ ".gz", ArchiveType.GZIP);

        // write hints
        logInfo ("Writing hints for %s/%s [%s]", suite.name, section, arch);

        // finalize the JSON hints document
        hintsFile ~= "\n]\n";

        // compress hints
        auto hintsFileBytes = cast(ubyte[]) hintsFile.data;
        compressAndSave (hintsFileBytes, hintsBaseFname ~ ".gz", ArchiveType.GZIP);
        compressAndSave (hintsFileBytes, hintsBaseFname ~ ".xz", ArchiveType.XZ);

        // save a copy of the hints registry to be used by other tools
        // (this allows other apps to just resolve the hint tags to severities and explanations
        // without loading either AppStream or AppStream-Generator code)
        saveHintsRegistryToJsonFile (buildPath (conf.hintsExportDir, suite.name, "hint-definitions.json"));
    }

    /**
     * Export all icons for the given set of packages and publish them in the selected suite/section.
     * Package icon duplicates will be eliminated automatically.
     */
    private void exportIconTarballs (Suite suite, string section, Package[] pkgs)
    {
        import ascompose.IconPolicyIter : IconPolicyIter;
        import ascompose.c.types : IconState;
        import asgen.zarchive;
        import asgen.utils : ImageSize;

        // determine data sources and destinations
        immutable dataExportDir = buildPath (conf.dataExportDir, suite.name, section);
        mkdirRecurse (dataExportDir);
        immutable useImmutableSuites = conf.feature.immutableSuites;
        immutable mediaExportDir = useImmutableSuites
                                    ? buildNormalizedPath (dstore.mediaExportPoolDir, "..", suite.name)
                                    : dstore.mediaExportPoolDir;

        // prepare icon-tarball array
        Appender!(string[])[string] iconTarFiles;

        auto policyIter = new IconPolicyIter;
        policyIter.init (conf.iconPolicy);
        uint iconSizeInt;
        uint iconScale;
        IconState iconState;
        while (policyIter.next (iconSizeInt, iconScale, iconState)) {
            if (iconState == IconState.IGNORED || iconState == IconState.REMOTE_ONLY)
                continue; // we only want to create tarballs for cached icons

            const iconSize = ImageSize (iconSizeInt, iconSizeInt, iconScale);
            auto ia = appender!(string[]);
            ia.reserve (256);
            iconTarFiles[iconSize.toString] = ia;
        }

        logInfo ("Creating icon tarballs for: %s/%s", suite.name, section);
        bool[string] processedDirs;
        foreach (ref pkg; parallel (pkgs)) {
            immutable pkid = pkg.id;
            auto gcids = dstore.getGCIDsForPackage (pkid);
            if (gcids is null)
                continue;

            // new iter for parallel processing
            auto ipIter = new IconPolicyIter;
            foreach (ref gcid; gcids) {
                // compile list of icon-tarball files
                ipIter.init (conf.iconPolicy);
                while (ipIter.next (iconSizeInt, iconScale, iconState)) {
                    if (iconState == IconState.IGNORED || iconState == IconState.REMOTE_ONLY)
                        continue; // only add icon to cache tarball if we want a cache for the particular size

                    const iconSize = ImageSize (iconSizeInt, iconSizeInt, iconScale);
                    immutable iconDir = buildPath (mediaExportDir, gcid, "icons", iconSize.toString);

                    // skip adding icon entries if we've already investigated this directory
                    synchronized {
                        if (iconDir in processedDirs)
                            continue;
                        else
                            processedDirs[iconDir] = true;
                    }

                    if (!std.file.exists (iconDir))
                        continue;
                    foreach (string path; std.file.dirEntries (iconDir, std.file.SpanMode.shallow, false))
                        synchronized (this) iconTarFiles[iconSize.toString] ~= path;

                }
            }
        }

        // create the icon tarballs
        policyIter.init (conf.iconPolicy);
        while (policyIter.next (iconSizeInt, iconScale, iconState)) {
            if (iconState == IconState.IGNORED || iconState == IconState.REMOTE_ONLY)
                continue;

            const iconSize = ImageSize (iconSizeInt, iconSizeInt, iconScale);
            auto iconTar = new ArchiveCompressor (ArchiveType.GZIP);
            iconTar.open (buildPath (dataExportDir, "icons-%s.tar.gz".format (iconSize.toString)));
            auto iconFiles = iconTarFiles[iconSize.toString]
                                .data
                                .sort!("a < b", SwapStrategy.stable);
            foreach (fname; iconFiles) {
                iconTar.addFile (fname);
            }

            iconTar.close ();
        }
        logInfo ("Icon tarballs built for: %s/%s", suite.name, section);
    }

    private Package[string] getIconCandidatePackages (Suite suite, string section, string arch)
    {
        // always load the "main" and "universe" components, which contain most of the icon data
        // on Debian and Ubuntu. Load the "core" and "extra" components for Arch Linux.
        // FIXME: This is a hack, find a sane way to get rid of this, or at least get rid of the
        // distro-specific hardcoding.
        auto pkgs = appender!(Package[]);
        foreach (ref newSection; ["main", "universe", "core", "extra"]) {
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

    /**
     * Read metainfo and auxiliary data injected by the person running the data generator.
     */
    private Package processExtraMetainfoData (Suite suite,
                                              IconHandler iconh,
                                              const string section,
                                              const string arch,
                                              InjectedModifications injMods)
    {
        import asgen.datainjectpkg : DataInjectPackage;
        import asgen.utils : existsAndIsDir;

        if (suite.extraMetainfoDir is null && !injMods.hasRemovedComponents)
            return null;

        immutable extraMIDir = buildNormalizedPath (suite.extraMetainfoDir, section);
        immutable archExtraMIDir = buildNormalizedPath (extraMIDir, arch);

        if (suite.extraMetainfoDir is null)
            logInfo ("Injecting component removal requests for %s/%s/%s", suite.name, section, arch);
        else
            logInfo ("Loading additional metainfo from local directory for %s/%s/%s", suite.name, section, arch);

        // we create a dummy package to hold information for the injected components
        auto diPkg = new DataInjectPackage (EXTRA_METAINFO_FAKE_PKGNAME, arch);
        diPkg.dataLocation = extraMIDir;
        diPkg.archDataLocation = archExtraMIDir;
        diPkg.maintainer = "AppStream Generator Maintainer";

        // ensure we have no leftover hints in the database.
        // since this package never changes its version number, cruft data will not be automatically
        // removed for it.
        dstore.removePackage (diPkg.id);

        // analyze our dummy package just like all other packages
        auto mde = new DataExtractor (dstore, iconh, null, null);
        auto gres = mde.processPackage (diPkg);

        // add removal requests, as we can remove packages from frozen suites via overlays
        injMods.addRemovalRequestsToResult (gres);

        // write resulting data into the database
        dstore.addGeneratorResult (this.conf.metadataType, gres, true);

        return diPkg;
    }

    /**
     * Scan and export data and hints for a specific section in a suite.
     */
    private bool processSuiteSection (Suite suite, const string section, ReportGenerator rgen)
    {
        ReportGenerator reportgen = rgen;
        if (reportgen is null)
            reportgen = new ReportGenerator (dstore);

        // load repo-level modifications
        auto injMods = new InjectedModifications;
        try {
            injMods.loadForSuite (suite);
        } catch (Exception e) {
            throw new Exception (format ("Unable to read modifications.json for suite %s: %s", suite.name, e.msg));
        }

        // process packages by architecture
        auto sectionPkgs = appender!(Package[]);
        auto suiteDataChanged = false;
        foreach (ref arch; suite.architectures) {
            // update package contents information and flag boring packages as ignored
            immutable foundInteresting = seedContentsData (suite, section, arch) || m_forced;

            // check if the suite/section/arch has actually changed
            if (!foundInteresting) {
                logInfo ("Skipping %s/%s [%s], no interesting new packages since last update.", suite.name, section, arch);
                continue;
            }

            // process new packages
            auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);
            auto iconh = new IconHandler (cstore,
                                          dstore.mediaExportPoolDir,
                                          getIconCandidatePackages (suite, section, arch),
                                          suite.iconTheme);
            processPackages (pkgs, iconh, injMods);

            // read injected data and add it to the database as a fake package
            auto fakePkg = processExtraMetainfoData (suite, iconh, section, arch, injMods);
            if (fakePkg !is null)
                pkgs ~= fakePkg;

            // export package data
            exportMetadata (suite, section, arch, pkgs);
            suiteDataChanged = true;

            // we store the package info over all architectures to generate reports later
            sectionPkgs.reserve (sectionPkgs.capacity + pkgs.length);
            sectionPkgs ~= pkgs;

            // log progress
            logInfo ("Completed metadata processing of %s/%s [%s]", suite.name, section, arch);

            // explicit GC collection and minimization run
            gcCollect ();
        }

        // finalize
        if (suiteDataChanged) {
            // export icons for the found packages in this section
            exportIconTarballs (suite, section, sectionPkgs.data);

            // write reports & statistics and render HTML, if that option is selected
            reportgen.processFor (suite.name, section, sectionPkgs.data);
        }

        // do garbage collection run now.
        // we might have allocated very big chunks of memory during this iteration,
        // that we can (mostly) free now - on some machines, the GC runs too late,
        // making the system run out of memory, which ultimately gets us OOM-killed.
        // we don't like that, and give the GC a hint to do the right thing.
        pkgIndex.release ();
        gcCollect ();

        return suiteDataChanged;
    }

    /**
     * Fetch a suite definition from a suite name and test whether we can process it.
     */
    private auto checkSuiteUsable (string suiteName)
    {
        Tuple!(Suite, "suite", bool, "suiteUsable") res;
        res.suiteUsable = false;

        bool suiteFound = false;
        foreach (ref s; conf.suites) {
            if (s.name == suiteName) {
                res.suite = s;
                suiteFound = true;
                break;
            }
        }

        if (!suiteFound) {
            logError ("Suite '%s' was not found.", suiteName);
            return res;
        }

        if (res.suite.isImmutable) {
            // we also can't process anything if there are no architectures defined
            logError ("Suite '%s' is marked as immutable. No changes are allowed.", res.suite.name);
            return res;
        }

        if (res.suite.sections.empty) {
            // if we have no sections, we can't do anything but exit...
            logError ("Suite '%s' has no sections. Can not continue.", res.suite.name);
            return res;
        }

        if (res.suite.architectures.empty) {
            // we also can't process anything if there are no architectures defined
            logError ("Suite '%s' has no architectures defined. Can not continue.", res.suite.name);
            return res;
        }

        // if we are here, we can process this suite
        res.suiteUsable = true;
        return res;
    }

    bool processFile (string suiteName, string sectionName, string[] files)
    {
        // fetch suite and exit in case we can't write to it.
        auto suiteTuple = checkSuiteUsable (suiteName);
        if (!suiteTuple.suiteUsable)
            return false;
        auto suite = suiteTuple.suite;

        bool sectionValid = false;
        foreach (ref section; suite.sections)
            if (section == sectionName)
                sectionValid = true;
        if (!sectionValid) {
            logError ("Section '%s' does not exist in suite '%s'. Can not continue.".format (sectionName, suite.name));
            return false;
        }

        Appender!(Package[])[string] pkgByArch;
        foreach (fname; files) {
            auto pkg = pkgIndex.packageForFile (fname, suiteName, sectionName);
            if (pkg is null) {
                logError ("Could not get package representation for file '%s' from backend '%s': The backend might not support this feature.", fname, conf.backend.to!string);
                return false;
            }
            auto pkgsP = pkg.arch in pkgByArch;
            if (pkgsP is null) {
                pkgByArch[pkg.arch] = appender!(Package[]);
                pkgsP = pkg.arch in pkgByArch;
            }
            (*pkgsP) ~= pkg;
        }

        foreach (arch; pkgByArch.byKey) {
            auto pkgs = pkgByArch[arch];

            // update package contents information and flag boring packages as ignored
            immutable foundInteresting = seedContentsData (suite, sectionName, arch, pkgs.data);

            // skip if the new package files have no interesting data
            if (!foundInteresting) {
                logInfo ("Skipping %s/%s [%s], no interesting new packages.", suite.name, sectionName, arch);
                continue;
            }

            // process new packages
            auto iconh = new IconHandler (cstore,
                                          dstore.mediaExportPoolDir,
                                          getIconCandidatePackages (suite, sectionName, arch),
                                          suite.iconTheme);
            auto pkgsList = pkgs.data;
            processPackages (pkgsList, iconh, null);
        }

        return true;
    }

    /**
     * Run the metadata extractor on a suite and all of its sections.
     */
    void run (string suiteName)
    {
        // fetch suite and exit in case we can't write to it.
        // the `checkSuiteUsable` method will print an error
        // message in case the suite isn't usable.
        auto suiteTuple = checkSuiteUsable (suiteName);
        if (!suiteTuple.suiteUsable)
            return;
        auto suite = suiteTuple.suite;

        logVersionInfo ();

        auto reportgen = new ReportGenerator (dstore);

        auto dataChanged = false;
        foreach (ref section; suite.sections) {
            immutable ret = processSuiteSection (suite, section, reportgen);
            if (ret)
                dataChanged = true;
        }

        // render index pages & statistics
        reportgen.updateIndexPages ();
        if (dataChanged)
            reportgen.exportStatistics ();
    }

    /**
     * Run the metadata extractor on a single section of a suite.
     */
    void run (string suiteName, string sectionName)
    {
        // fetch suite and exit in case we can't write to it.
        // the `checkSuiteUsable` method will print an error
        // message in case the suite isn't usable.
        auto suiteTuple = checkSuiteUsable (suiteName);
        if (!suiteTuple.suiteUsable)
            return;
        auto suite = suiteTuple.suite;

        logVersionInfo ();

        bool sectionValid = false;
        foreach (ref section; suite.sections)
            if (section == sectionName)
                sectionValid = true;
        if (!sectionValid) {
            logError ("Section '%s' does not exist in suite '%s'. Can not continue.".format (sectionName, suite.name));
            return;
        }

        auto reportgen = new ReportGenerator (dstore);
        auto dataChanged = processSuiteSection (suite, sectionName, reportgen);

        // render index pages & statistics
        reportgen.updateIndexPages ();
        if (dataChanged)
            reportgen.exportStatistics ();
    }

    /**
     * Export data and hints for a specific section in a suite.
     */
    private void publishMetadataForSuiteSection (Suite suite, const string section, ReportGenerator rgen)
    {
        ReportGenerator reportgen = rgen;
        if (reportgen is null)
            reportgen = new ReportGenerator (dstore);

        auto sectionPkgs = appender!(Package[]);
        foreach (ref arch; suite.architectures) {
            // process new packages
            auto pkgs = pkgIndex.packagesFor (suite.name, section, arch);

            // export package data
            exportMetadata (suite, section, arch, pkgs);

            // we store the package info over all architectures to generate reports later
            sectionPkgs.reserve (sectionPkgs.capacity + pkgs.length);
            sectionPkgs ~= pkgs;

            // log progress
            logInfo ("Completed publishing of data for %s/%s [%s]", suite.name, section, arch);
        }

        // export icons for the found packages in this section
        exportIconTarballs (suite, section, sectionPkgs.data);

        // write reports & statistics and render HTML, if that option is selected
        reportgen.processFor (suite.name, section, sectionPkgs.data);

        // do garbage collection run now.
        // we might have allocated very big chunks of memory during this iteration,
        // that we can (mostly) free now - on some machines, the GC runs too late,
        // making the system run out of memory, which ultimately gets us OOM-killed.
        // we don't like that, and give the GC a hint to do the right thing.
        pkgIndex.release ();
        gcCollect ();
    }

    /**
     * Run the metadata publishing step only, for a suite and all of its sections.
     */
    void publish (string suiteName)
    {
        // fetch suite and exit in case we can't write to it.
        auto suiteTuple = checkSuiteUsable (suiteName);
        if (!suiteTuple.suiteUsable)
            return;
        auto suite = suiteTuple.suite;

        logVersionInfo ();

        auto reportgen = new ReportGenerator (dstore);
        foreach (ref section; suite.sections)
            publishMetadataForSuiteSection (suite, section, reportgen);

        // render index pages & statistics
        reportgen.updateIndexPages ();
        reportgen.exportStatistics ();
    }

    /**
     * Run the metadata publishing step only, on a single section of a suite.
     */
    void publish (string suiteName, string sectionName)
    {
        // fetch suite an exit in case we can't write to it.
        auto suiteTuple = checkSuiteUsable (suiteName);
        if (!suiteTuple.suiteUsable)
            return;
        auto suite = suiteTuple.suite;

        logVersionInfo ();

        bool sectionValid = false;
        foreach (ref section; suite.sections)
            if (section == sectionName)
                sectionValid = true;
        if (!sectionValid) {
            logError ("Section '%s' does not exist in suite '%s'. Can not continue.".format (sectionName, suite.name));
            return;
        }

        auto reportgen = new ReportGenerator (dstore);
        publishMetadataForSuiteSection (suite, sectionName, reportgen);

        // render index pages & statistics
        reportgen.updateIndexPages ();
        reportgen.exportStatistics ();
    }

    private void cleanupStatistics ()
    {
        import std.json;
        import std.algorithm : sort;

        auto allStats = dstore.getStatistics ();
        sort!("a.time < b.time") (allStats);
        string[string] lastJData;
        size_t[string] lastTime;
        foreach (ref entry; allStats) {
            if (entry.data.type == JSONType.array) {
                // we don't clean up combined statistics entries, and therefore need to reset
                // the last-data hashmaps as soon as we encounter one to not loose data.
                lastJData = null;
                lastTime = null;
                continue;
            }

            immutable ssid = format ("%s-%s", entry.data["suite"].str, entry.data["section"].str);
            if (ssid !in lastJData) {
                lastJData[ssid] = entry.data.toString;
                lastTime[ssid]  = entry.time;
                continue;
            }

            auto jdata = entry.data.toString;
            if (lastJData[ssid] == jdata) {
                logInfo ("Removing superfluous statistics entry: %s", lastTime[ssid]);
                dstore.removeStatistics (lastTime[ssid]);
            }

            lastTime[ssid] = entry.time;
            lastJData[ssid] = jdata;
        }
    }

    void runCleanup ()
    {
        logVersionInfo ();

        logInfo ("Cleaning up left over temporary data.");
        immutable tmpDir = buildPath (conf.cacheRootDir, "tmp");
        if (std.file.exists (tmpDir))
            rmdirRecurse (tmpDir);

        logInfo ("Collecting information.");

        // get sets of all packages registered in the database
        bool[immutable string] pkidsContents;
        bool[immutable string] pkidsData;
        foreach (i; parallel ([1, 2])) {
            if (i == 1)
                pkidsContents = cstore.getPackageIdSet ();
            else if (i == 2)
                pkidsData     = dstore.getPackageIdSet ();
        }

        logInfo ("We have data on a total of %s packages (content lists on %s)",
                 pkidsData.length, pkidsContents.length);

        // build a set of all valid packages
        foreach (ref suite; conf.suites) {
            if (suite.isImmutable)
                continue; // data from immutable suites is ignored

            foreach (ref section; suite.sections) {
                foreach (ref arch; suite.architectures) {
                    // fetch current packages without long descriptions, we really only are interested in the pkgid
                    auto pkgs = pkgIndex.packagesFor (suite.name, section, arch, false);
                    if (!suite.baseSuite.empty)
                        pkgs ~= pkgIndex.packagesFor (suite.baseSuite, section, arch, false);

                    synchronized (this) {
                        foreach (ref pkg; pkgs) {
                            // remove packages from the sets that are still active
                            pkidsContents.remove (pkg.id);
                            pkidsData.remove (pkg.id);
                        }

                        // free some memory
                        pkgIndex.release ();
                    }
                }

                // trigger a GC collection cycle, to ensure we free memory
                gcCollect ();
            }

        }

        // release index resources
        pkgIndex.release ();

        logInfo ("Cleaning up superseded data (%s hints/data, %s content lists).",
                 pkidsData.length, pkidsContents.length);

        // remove packages from the caches which are no longer in the archive
        foreach (i; parallel ([1, 2])) {
            if (i == 1)
                cstore.removePackages (pkidsContents);
            else if (i == 2)
                dstore.removePackages (pkidsData);
        }

        // enforce another GC cycle to free memory
        gcCollect ();

        // remove orphaned data and media
        logInfo ("Cleaning up obsolete media.");
        dstore.cleanupCruft ();

        // cleanup duplicate statistical entries
        logInfo ("Cleaning up excess statistical data.");
        cleanupStatistics ();
    }

    /**
     * Drop all packages which contain valid components or hints
     * from the database.
     * This is useful when big generator changes have been done, which
     * require reprocessing of all components.
     */
    void removeHintsComponents (string suite_name)
    {
        auto st = checkSuiteUsable (suite_name);
        if (!st.suiteUsable)
            return;
        auto suite = st.suite;

        logVersionInfo ();

        foreach (ref section; suite.sections) {
            foreach (ref arch; parallel (suite.architectures)) {
                auto pkgs = pkgIndex.packagesFor (suite.name, section, arch, false);

                foreach (ref pkg; pkgs) {
                    immutable pkid = pkg.id;

                    if (!dstore.packageExists (pkid))
                        continue;
                    if (dstore.isIgnored (pkid))
                        continue;

                    dstore.removePackage (pkid);
                }
            }

            pkgIndex.release ();
        }

        dstore.cleanupCruft ();
        pkgIndex.release ();
    }

    void forgetPackage (string identifier)
    {
        if (identifier.count ("/") == 2) {
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

    /**
     * Print all information we have on a package to stdout.
     */
    bool printPackageInfo (string identifier)
    {
        import std.stdio : writeln;

        if (identifier.count ("/") != 2) {
            writeln ("Please enter a package-id in the format <name>/<version>/<arch>");
            return false;
        }
        immutable pkid = identifier;

        writeln ("== ", pkid, " ==");
        writeln ("Contents:");
        auto pkgContents = cstore.getContents (pkid);
        if (pkgContents.empty) {
            writeln ("~ No contents found.");
        } else {
            foreach (ref s; pkgContents)
                writeln (" ", s);
        }
        writeln ();

        writeln ("Icons:");
        auto pkgIcons = cstore.getIcons (pkid);
        if (pkgIcons.empty) {
            writeln ("~ No icons found.");
        } else {
            foreach (ref s; pkgIcons)
                writeln (" ", s);
        }
        writeln ();

        if (dstore.isIgnored (pkid)) {
            writeln ("Ignored: yes");
            writeln ();
        } else {
            writeln ("Global Component IDs:");
            foreach (ref s; dstore.getGCIDsForPackage (pkid))
                writeln ("- ", s);
            writeln ();

            writeln ("Generated Data:");
            foreach (ref s; dstore.getMetadataForPackage (conf.metadataType, pkid))
                writeln (s);
            writeln ();
        }


        if (dstore.hasHints (pkid)) {
            writeln ("Hints:");
            writeln (dstore.getHints (pkid));
        } else {
            writeln ("Hints: None");
        }

        writeln ();

        return true;
    }

} // End of Engine class
