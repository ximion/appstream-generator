/*
 * Copyright (C) 2023 Serenity Cyber Security, LLC
 * Author: Gleb Popov <arrowd@FreeBSD.org>
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

module asgen.backends.freebsd.fbsdpkgindex;

import std.json;
import std.stdio;
import std.path;
import std.string;
import std.conv : to;
import std.array : appender;
import std.algorithm : remove;
static import std.file;

import asgen.logging;
import asgen.zarchive;
import asgen.backends.interfaces;
import asgen.backends.freebsd.fbsdpkg;


final class FreeBSDPackageIndex : PackageIndex
{

private:
    string rootDir;
    Package[][string] pkgCache;

public:

    this (string dir)
    {
        this.rootDir = dir;
        if (!std.file.exists (dir))
            throw new Exception ("Directory '%s' does not exist.", dir);
    }

    void release ()
    {
        pkgCache = null;
    }

    private Package[] loadPackages (string suite, string section, string arch)
    {
        auto pkgRoot = buildPath (rootDir, suite);
        auto metaFname = buildPath (pkgRoot, "meta.conf");
        string manifestFname, manifestArchive;

        if (!std.file.exists (metaFname)) {
            logError ("Metadata file '%s' does not exist.", metaFname);
            return [];
        }

        foreach(line; std.file.slurp!(string)(metaFname, "%s")) {
            if (line.startsWith("manifests_archive")) {
                // manifests_archive = "packagesite";
                auto splitResult = line.split("\"");
                if (splitResult.length == 3)
                    manifestArchive = splitResult[1];
            }
            else if (line.startsWith("manifests")) {
                // manifests = "packagesite.yaml";
                auto splitResult = line.split("\"");
                if (splitResult.length == 3)
                    manifestFname = splitResult[1];
            }
        }

        auto listsTarFname = buildPath (pkgRoot, manifestArchive ~ ".pkg");
        if (!std.file.exists (listsTarFname)) {
            logError ("Package lists file '%s' does not exist.", listsTarFname);
            return [];
        }

        ArchiveDecompressor ad;
        ad.open (listsTarFname);
        logDebug ("Opened: %s", listsTarFname);

        auto d = ad.readData(manifestFname);
        auto pkgs = appender!(Package[]);

        foreach(entry; d.split('\n')) {
            auto j = parseJSON(assumeUTF(entry));
            if (j.type == JSONType.object)
                pkgs ~= to!Package(new FreeBSDPackage(pkgRoot, j.object));
        }

        return pkgs.data;
    }

    Package[] packagesFor (string suite, string section, string arch, bool withLongDescs = true)
    {
        immutable id = "%s-%s-%s".format (suite, section, arch);
        if (id !in pkgCache) {
            auto pkgs = loadPackages (suite, section, arch);
            synchronized (this) pkgCache[id] = pkgs;
        }

        return pkgCache[id];
    }

    Package packageForFile (string fname, string suite = null, string section = null)
    {
        return null; // FIXME: not implemented
    }

    bool hasChanges (DataStore dstore, string suite, string section, string arch)
    {
        return true;
    }
}
