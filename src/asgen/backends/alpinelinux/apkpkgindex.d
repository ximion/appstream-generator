/*
 * Copyright (C) 2020 Rasmus Thomsen <oss@cogitri.dev>
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

module asgen.backends.alpinelinux.apkpkgindex;

import std.algorithm : canFind, filter, endsWith, remove;
import std.array : appender, join, split;
import std.conv : to;
import std.exception : enforce;
import std.file : dirEntries, exists, SpanMode;
import std.format : format;
import std.path : baseName, buildPath;
import std.range : empty;
import std.string : splitLines, startsWith, strip;
import std.utf : UTFException, validate;

import asgen.logging;
import asgen.zarchive;
import asgen.utils : escapeXml;
import asgen.backends.interfaces;
import asgen.backends.alpinelinux.apkpkg;

final class AlpinePackageIndex : PackageIndex
{

private:
    string rootDir;
    Package[][string] pkgCache;

public:

    this (string dir)
    {
        enforce (exists (dir), format ("Directory '%s' does not exist.", dir));
        this.rootDir = dir;
    }

    override void release ()
    {
        pkgCache = null;
    }

    private void setPkgDescription (AlpinePackage pkg, string pkgDesc)
    {
        if (pkgDesc is null)
            return;

        auto desc = "<p>%s</p>".format (pkgDesc.escapeXml);
        pkg.setDescription (desc, "C");
    }

    private void setPkgValues (ref AlpinePackage pkg, string[] keyValueString)
    {
        immutable key = keyValueString[0].strip;
        immutable value = keyValueString[1].strip;

        switch (key) {
        case "pkgname":
            pkg.name = value;
            break;
        case "pkgver":
            pkg.ver = value;
            break;
        case "arch":
            pkg.arch = value;
            break;
        case "maintainer":
            pkg.maintainer = value;
            break;
        case "pkgdesc":
            setPkgDescription(pkg, value);
            break;
        default:
            // We don't care about other entries
            break;
        }
    }

    private Package[] loadPackages (string suite, string section, string arch)
    {
        auto apkRootPath = buildPath (rootDir, suite, section, arch);
        ArchiveDecompressor ad;
        AlpinePackage[string] pkgsMap;

        foreach (packageArchivePath; dirEntries (apkRootPath, SpanMode.shallow).filter!(
                f => f.name.endsWith (".apk"))) {
            auto fileName = packageArchivePath.baseName ();
            AlpinePackage pkg;
            if (fileName in pkgsMap) {
                pkg = pkgsMap[fileName];
            } else {
                pkg = new AlpinePackage ();
                pkgsMap[fileName] = pkg;
            }

            ad.open (packageArchivePath);
            auto pkgInfoData = cast(string) ad.readData (".PKGINFO");

            try {
                validate (pkgInfoData);
            } catch (UTFException e) {
                logError ("PKGINFO file in archive %s contained invalid UTF-8, skipping!",
                        packageArchivePath);
                continue;
            }

            pkg.filename = packageArchivePath;
            auto lines = pkgInfoData.splitLines ();
            // If the current line doesn't contain a = it's meant to extend the previous line
            string[] completePair;
            foreach (currentLine; lines) {
                if (currentLine.canFind ("=")) {
                    if (completePair.empty) {
                        completePair = [currentLine];
                        continue;
                    }

                    this.setPkgValues (pkg, completePair.join (" ").split ("="));
                    completePair = [currentLine];
                } else if (!currentLine.startsWith ("#")) {
                    completePair ~= currentLine.strip.split ("#")[0];
                }
            }
            // We didn't process the last line yet
            this.setPkgValues (pkg, completePair.join (" ").split ("="));
            pkg.contents = ad.readContents ().remove!("a == \".PKGINFO\" || a.startsWith (\".SIGN\")");
        }

        // perform a sanity check, so we will never emit invalid packages
        auto pkgs = appender!(Package[]);
        if (pkgsMap.length > 20)
            pkgs.reserve ((pkgsMap.length.to!long - 10).to!size_t);
        foreach (ref pkg; pkgsMap.byValue ())
            if (pkg.isValid)
                pkgs ~= pkg;
            else
                logError ("Found an invalid package (name, architecture or version is missing). This is a bug.");

        return pkgs.data;
    }

    override Package[] packagesFor (string suite, string section, string arch, bool withLongDescs = true)
    {
        immutable id = "%s-%s-%s".format (suite, section, arch);
        if (id !in pkgCache) {
            auto pkgs = loadPackages (suite, section, arch);
            synchronized (this)
                pkgCache[id] = pkgs;
        }

        return pkgCache[id];
    }

    Package packageForFile (string fname, string suite = null, string section = null)
    {
        // Alpine currently doesn't have a way other than querying a web API
        // to tell what package owns a file, unless that packages is installed
        // on the system.
        return null;
    }

    bool hasChanges (DataStore dstore, string suite, string section, string arch)
    {
        return true;
    }
}
