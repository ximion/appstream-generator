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
    bool[string] indexChanged;

protected:
    string tmpDir;

public:

    this (string dir)
    {
        pkgCache = HashMap!(string, Package[]) (128);
        this.rootDir = dir;
        if (!dir.isRemote && !std.file.exists (dir))
            throw new Exception ("Directory '%s' does not exist.".format (dir));

        auto conf = Config.get ();
        tmpDir = buildPath (conf.getTmpDir, dir.baseName);
    }

    final void release ()
    {
        pkgCache = HashMap!(string, Package[]) (16);
        indexChanged = null;
    }

    private final immutable(string[]) findTranslations (const string suite, const string section)
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

    private final void loadPackageLongDescs (ref HashMap!(string, DebPackage) pkgs, string suite, string section)
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

            auto tagf = new TagFile ();
            tagf.open (fname);

            do {
                auto pkgname = tagf.readField ("Package");
                auto rawDesc  = tagf.readField ("Description-%s".format (lang));
                if (!pkgname)
                    continue;
                if (!rawDesc)
                    continue;

                auto pkg = pkgs.get (pkgname, null);
                if (pkg is null)
                    continue;

                auto split = rawDesc.split ("\n");
                if (split.length < 2)
                    continue;


                if (lang == "en")
                    pkg.setSummary (split[0], "C");

                pkg.setSummary (split[0], lang);

                // NOTE: .remove() removes the element, but does not alter the
                // length of the array. Bug?  (this is why we slice the array
                // here)
                split = split[1..$];

                // TODO: We actually need a Markdown-ish parser here if we want
                // to support listings in package descriptions properly.
                auto description = appender!string;
                description.reserve (80);
                description ~= "<p>";
                bool first = true;
                foreach (l; split) {
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

                if (lang == "en")
                    pkg.setDescription (description.data, "C");

                pkg.setDescription (description.data, lang);
            } while (tagf.nextSection ());
        }
    }

    private final string getIndexFile (string suite, string section, string arch)
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

    private final DebPackage[] loadPackages (string suite, string section, string arch)
    {
        auto indexFname = getIndexFile (suite, section, arch);
        if (!std.file.exists (indexFname)) {
            logWarning ("Archive package index file '%s' does not exist.", indexFname);
            return [];
        }

        auto tagf = new TagFile ();
        tagf.open (indexFname);
        logDebug ("Opened: %s", indexFname);

        auto pkgs = HashMap!(string, DebPackage) (128);
        do {
            import std.algorithm : map;
            import std.array : array;

            auto name  = tagf.readField ("Package");
            auto ver   = tagf.readField ("Version");
            auto fname = tagf.readField ("Filename");
            if (!name)
                continue;

            auto pkg = newPackage (name, ver, arch);
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

            pkg.gst = new GStreamer(decoders, encoders, elements, uri_sinks, uri_sources);

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
        loadPackageLongDescs (pkgs, suite, section);

        return pkgs.values;
    }

    Package[] packagesFor (string suite, string section, string arch)
    {
        immutable id = "%s/%s/%s".format (suite, section, arch);
        if (id !in pkgCache) {
            auto pkgs = loadPackages (suite, section, arch);
            synchronized (this) pkgCache[id] = to!(Package[]) (pkgs);
        }

        return pkgCache[id];
    }

    Package packageForFile (string fname, string suite = null, string section = null)
    {
        return null; // FIXME: not implemented
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
