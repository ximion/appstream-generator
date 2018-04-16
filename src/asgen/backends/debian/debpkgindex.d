/*
 * Copyright (C) 2016-2018 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.backends.debian.debpkgindex;

import std.stdio;
import std.path;
import std.string;
import std.algorithm : remove;
import std.array : appender, array;
import std.conv : to;
import std.typecons : scoped;
import containers : HashMap, HashSet;
static import std.file;

import asgen.logging;
import asgen.backends.interfaces;
import asgen.backends.debian.tagfile;
import asgen.backends.debian.debpkg;
import asgen.backends.debian.debutils;
import asgen.config;
import asgen.utils : escapeXml, getFileContents, isRemote;


class DebianPackageIndex : PackageIndex
{

private:
    string rootDir;
    HashMap!(string, Package[]) pkgCache;
    HashMap!(string, DebPackageLocaleTexts) l10nTextIndex;
    bool[string] indexChanged;

protected:
    string tmpDir;

public:

    this (string dir)
    {
        pkgCache = HashMap!(string, Package[]) (4);
        this.rootDir = dir;
        if (!dir.isRemote && !std.file.exists (dir))
            throw new Exception ("Directory '%s' does not exist.".format (dir));

        auto conf = Config.get ();
        tmpDir = buildPath (conf.getTmpDir, dir.baseName);

        // index of localized text for a specific package name
        l10nTextIndex = HashMap!(string, DebPackageLocaleTexts) (64);
    }

    final void release ()
    {
        pkgCache = HashMap!(string, Package[]) (4);
        l10nTextIndex = HashMap!(string, DebPackageLocaleTexts) (64);
        indexChanged = null;
    }

    private immutable(string[]) findTranslations (const string suite, const string section)
    {
        import std.regex : matchFirst, regex;

        immutable inRelease = buildPath (rootDir, "dists", suite, "InRelease");
        auto translationregex = r"%s/i18n/Translation-(\w+)$".format (section).regex;
        auto ret = HashSet!string (32);

        try {
            synchronized (this) {
                const inReleaseContents = getFileContents (inRelease);

                foreach (const ref entry; inReleaseContents) {
                    auto match = entry.matchFirst (translationregex);

                    if (match.empty)
                        continue;

                    ret.put (match[1]);
                }
            }
        } catch (Exception ex) {
            logWarning ("Could not get %s, will assume 'en' is available.", inRelease);
            return ["en"];
        }

        return cast(immutable) array (ret[]);
    }

    /**
     * Convert a Debian package description to a description
     * that looks nice-ish in AppStream clients.
     */
    private string packageDescToAppStreamDesc (string[] lines)
    {
        // TODO: We actually need a Markdown-ish parser here if we want
        // to support listings in package descriptions properly.
        auto description = appender!string;
        description.reserve (80);
        description ~= "<p>";
        bool first = true;
        foreach (l; lines) {
            if (l.strip () == ".") {
                description ~= "</p>\n<p>";
                first = true;
                continue;
            }

            if (first)
                first = false;
            else
                description ~= " ";

            description ~= escapeXml (l);
        }
        description ~= "</p>";

        return description.data;
    }

    private void loadPackageLongDescs (ref HashMap!(string, DebPackage) pkgs, string suite, string section)
    {
        immutable langs = findTranslations (suite, section);

        logDebug ("Found translations for: %s", langs.join(", "));

        foreach (const ref lang; langs) {
            string fname;

            immutable fullPath = buildPath ("dists",
                                            suite,
                                            section,
                                            "i18n",
                                            /* here we explicitly substitute a
                                             * "%s", because
                                             * downloadIfNecessary will put the
                                             * file extension there */
                                            "Translation-%s.%s".format(lang, "%s"));

            try {
                synchronized (this) {
                    fname = downloadIfNecessary (rootDir, tmpDir, fullPath);
                }
            } catch (Exception ex) {
                logDebug ("No translations for %s in %s/%s", lang, suite, section);
                continue;
            }

            auto tagf = scoped!TagFile ();
            tagf.open (fname);

            do {
                immutable pkgname = tagf.readField ("Package");
                immutable rawDesc = tagf.readField ("Description-%s".format (lang));
                if (!pkgname)
                    continue;
                if (!rawDesc)
                    continue;

                auto pkg = pkgs.get (pkgname, null);
                if (pkg is null)
                    continue;

                immutable textPkgId = "%s/%s".format (pkg.name, pkg.ver);

                DebPackageLocaleTexts l10nTexts;
                synchronized (this)
                    l10nTexts = l10nTextIndex.get (textPkgId, null);
                if (l10nTexts !is null) {
                    // we already fetched this information
                    pkg.setLocalizedTexts (l10nTexts);
                }

                // read new localizations
                l10nTexts = pkg.localizedTexts;
                synchronized (this)
                    l10nTextIndex[textPkgId] = l10nTexts;

                auto split = rawDesc.split ("\n");
                if (split.length < 2)
                    continue;


                if (lang == "en")
                    l10nTexts.setSummary (split[0], "C");
                l10nTexts.setSummary (split[0], lang);

                // NOTE: .remove() removes the element, but does not alter the
                // length of the array. Bug?  (this is why we slice the array
                // here)
                split = split[1..$];
                immutable description = packageDescToAppStreamDesc (split);

                if (lang == "en")
                    l10nTexts.setDescription (description, "C");
                l10nTexts.setDescription (description, lang);

                pkg.setLocalizedTexts (l10nTexts);
            } while (tagf.nextSection ());
        }
    }

    private string getIndexFile (string suite, string section, string arch)
    {
        immutable path = buildPath ("dists", suite, section, "binary-%s".format (arch));

        synchronized (this) {
            return downloadIfNecessary (rootDir, tmpDir, buildPath (path, "Packages.%s"));
        }
    }

    protected DebPackage newPackage (string name, string ver, string arch)
    {
        return new DebPackage (name, ver, arch);
    }

    private DebPackage[] loadPackages (string suite, string section, string arch, bool withLongDescs = true)
    {
        auto indexFname = getIndexFile (suite, section, arch);
        if (!std.file.exists (indexFname)) {
            logWarning ("Archive package index file '%s' does not exist.", indexFname);
            return [];
        }

        auto tagf = scoped!TagFile ();
        tagf.open (indexFname);
        logDebug ("Opened: %s", indexFname);

        auto pkgs = HashMap!(string, DebPackage) (128);
        do {
            import std.algorithm : map;
            import std.array : array;

            auto name  = tagf.readField ("Package");
            auto ver   = tagf.readField ("Version");
            auto fname = tagf.readField ("Filename");
            auto pkgArch = tagf.readField ("Architecture");
            if (!name)
                continue;

            // sanity check: We only allow arch:all mixed in with packages from other architectures
            if (pkgArch != "all")
                pkgArch = arch;

            auto pkg = newPackage (name, ver, pkgArch);
            pkg.filename = buildPath (rootDir, fname);
            pkg.maintainer = tagf.readField ("Maintainer");

            immutable decoders = tagf.readField("Gstreamer-Decoders")
                .split(";")
                .map!strip.array;

            immutable encoders = tagf.readField("Gstreamer-Encoders")
                .split(";")
                .map!strip.array;

            immutable elements = tagf.readField("Gstreamer-Elements")
                .split(";")
                .map!strip.array;

            immutable uri_sinks = tagf.readField("Gstreamer-Uri-Sinks")
                .split(";")
                .map!strip.array;

            immutable uri_sources = tagf.readField("Gstreamer-Uri-Sources")
                .split(";")
                .map!strip.array;

            auto gst = new GStreamer (decoders, encoders, elements, uri_sinks, uri_sources);
            if (gst.isNotEmpty)
                pkg.gst = gst;

            if (!pkg.isValid ()) {
                logWarning ("Found invalid package (%s)! Skipping it.", pkg.toString ());
                continue;
            }

            // filter out the most recent package version in the packages list
            auto epkg = pkgs.get (name, null);
            if (epkg !is null) {
                if (compareVersions (epkg.ver, pkg.ver) > 0)
                    continue;
            }

            pkgs[name] = pkg;
        } while (tagf.nextSection ());

        // load long descriptions
        if (withLongDescs)
            loadPackageLongDescs (pkgs, suite, section);

        return pkgs.values;
    }

    Package[] packagesFor (string suite, string section, string arch, bool withLongDescs = true)
    {
        immutable id = "%s/%s/%s".format (suite, section, arch);
        if (id !in pkgCache) {
            auto pkgs = loadPackages (suite, section, arch, withLongDescs);
            synchronized (this) pkgCache[id] = to!(Package[]) (pkgs);
        }

        return pkgCache[id];
    }

    Package packageForFile (string fname, string suite = null, string section = null)
    {
        auto pkg = newPackage ("", "", "");
        pkg.filename = fname;

        auto tf = pkg.readControlInformation ();
        if (tf is null)
            throw new Exception ("Unable to read control information for package %s".format (fname));

        pkg.name = tf.readField ("Package");
        pkg.ver  = tf.readField ("Version");
        pkg.arch = tf.readField ("Architecture");

        if (pkg.name is null || pkg.ver is null || pkg.arch is null)
            throw new Exception ("Unable to get control data for package %s".format (fname));

        immutable rawDesc = tf.readField ("Description");
        auto dSplit = rawDesc.split ("\n");
        if (dSplit.length >= 2) {
            pkg.setSummary (dSplit[0], "C");

            dSplit = dSplit[1..$];
            immutable description = packageDescToAppStreamDesc (dSplit);
            pkg.setDescription (description, "C");
        }

        // ensure we have a meaningful temporary directory name
        pkg.updateTmpDirPath ();

        return pkg.to!Package;
    }

    final bool hasChanges (DataStore dstore, string suite, string section, string arch)
    {
        import std.json;

        auto indexFname = getIndexFile (suite, section, arch);
        // if the file doesn't exit, we will emit a warning later anyway, so we just ignore this here
        if (!std.file.exists (indexFname))
            return true;

        // check our cache on whether the index had changed
        if (indexFname in indexChanged)
            return indexChanged[indexFname];

        std.datetime.SysTime mtime;
        std.datetime.SysTime atime;
        std.file.getTimes (indexFname, atime, mtime);
        auto currentTime = mtime.toUnixTime ();

        auto repoInfo = dstore.getRepoInfo (suite, section, arch);
        scope (exit) {
            repoInfo.object["mtime"] = JSONValue (currentTime);
            dstore.setRepoInfo (suite, section, arch, repoInfo);
        }

        if ("mtime" !in repoInfo.object) {
            indexChanged[indexFname] = true;
            return true;
        }

        auto pastTime = repoInfo["mtime"].integer;
        if (pastTime != currentTime) {
            indexChanged[indexFname] = true;
            return true;
        }

        indexChanged[indexFname] = false;
        return false;
    }
}

unittest {
    import std.algorithm.sorting : sort;
    import asgen.utils : getTestSamplesDir;

    writeln ("TEST: ", "DebianPackageIndex");

    auto pi = new DebianPackageIndex (buildPath (getTestSamplesDir (), "debian"));
    assert (sort(pi.findTranslations ("sid", "main").dup) ==
            sort(["en", "ca", "cs", "da", "de", "de_DE", "el", "eo", "es",
                   "eu", "fi", "fr", "hr", "hu", "id", "it", "ja", "km", "ko",
                   "ml", "nb", "nl", "pl", "pt", "pt_BR", "ro", "ru", "sk",
                   "sr", "sv", "tr", "uk", "vi", "zh", "zh_CN", "zh_TW"]));
}
