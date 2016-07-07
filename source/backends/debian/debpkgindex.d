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

module ag.backend.debian.pkgindex;

import std.stdio;
import std.path;
import std.string;
import std.algorithm : remove;

import ag.logging;
import ag.backend.intf;
import ag.backend.debian.tagfile;
import ag.backend.debian.debpkg;


class DebianPackageIndex : PackageIndex
{

private:
    string rootDir;
    Package[][string] pkgCache;
    bool[string] indexChanged;

public:

    this (string dir)
    {
        this.rootDir = dir;
        if (!std.file.exists (dir))
            throw new Exception ("Directory '%s' does not exist.".format (dir));
    }

    void release ()
    {
        pkgCache = null;
        indexChanged = null;
    }

    private void loadPackageLongDescs (Package[string] pkgs, string suite, string section)
    {
        auto enDescFname = buildPath (rootDir, "dists", suite, section, "i18n", "Translation-en.bz2");
        if (!std.file.exists (enDescFname)) {
            logDebug ("No long descriptions for %s/%s", suite, section);
            return;
        }

        auto tagf = new TagFile ();
        try {
            tagf.open (enDescFname);
        } catch (Exception e) {
            throw e;
        }

        logDebug ("Opened: %s", enDescFname);
        do {
            auto pkgname = tagf.readField ("Package");
            auto rawDesc  = tagf.readField ("Description-en");
            if (!pkgname)
                continue;
            if (!rawDesc)
                continue;

            auto pkgP = (pkgname in pkgs);
            if (pkgP is null)
                continue;

            auto split = rawDesc.split ("\n");
            if (split.length < 2)
                continue;

            // NOTE: .remove() removes the element, but does not alter the length of the array. Bug?
            // (this is why we slice the array here)
            split = split[1..$];

            // TODO: We actually need a Markdown-ish parser here if we want to support
            // listings in package descriptions properly.
            auto description = appender!string;
            description.put ("<p>");
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

                description ~= ag.utils.escapeXml (l);
            }
            description ~= "</p>";

            (*pkgP).setDescription (description.data, "C");
        } while (tagf.nextSection ());
    }

    private string getIndexFile (string suite, string section, string arch)
    {
        auto binDistsPath = buildPath (rootDir, "dists", suite, section, "binary-%s".format (arch));
        auto indexFname = buildPath (binDistsPath, "Packages.gz");
        if (!std.file.exists (indexFname))
            indexFname = buildPath (binDistsPath, "Packages.xz");
        return indexFname;
    }

    private Package[] loadPackages (string suite, string section, string arch)
    {
        auto indexFname = getIndexFile (suite, section, arch);
        if (!std.file.exists (indexFname)) {
            logWarning ("Archive package index file '%s' does not exist.", indexFname);
            return [];
        }

        auto tagf = new TagFile ();
        try {
            tagf.open (indexFname);
        } catch (Exception e) {
            throw e;
        }

        logDebug ("Opened: %s", indexFname);

        Package[string] pkgs;
        do {
            auto name = tagf.readField ("Package");
            auto ver  = tagf.readField ("Version");
            auto fname  = tagf.readField ("Filename");
            if (!name)
                continue;

            auto pkg = new DebPackage (name, ver, arch);
            pkg.filename = buildPath (rootDir, fname);
            pkg.maintainer = tagf.readField ("Maintainer");

            if (!pkg.isValid ()) {
                logWarning ("Found invalid package (%s)! Skipping it.", pkg.toString ());
                continue;
            }

            pkgs[name] = pkg;
        } while (tagf.nextSection ());

        // load long descriptions
        loadPackageLongDescs (pkgs, suite, section);

        return pkgs.values ();
    }

    Package[] packagesFor (string suite, string section, string arch)
    {
        string id = suite ~ "/" ~ section ~ "/" ~ arch;
        if (id !in pkgCache) {
            auto pkgs = loadPackages (suite, section, arch);
            synchronized (this) pkgCache[id] = pkgs;
        }

        return pkgCache[id];
    }

    bool hasChanges (DataCache dcache, string suite, string section, string arch)
    {
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

        auto repoInfo = dcache.getRepoInfo (suite, section, arch);
        scope (exit) {
            repoInfo.object["mtime"] = std.json.JSONValue (currentTime);
            dcache.setRepoInfo (suite, section, arch, repoInfo);
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
