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
        auto repoRoot = buildPath (rootDir, suite);
        auto metaFname = buildPath (repoRoot, "meta.conf");
        string dataFname;

        if (!std.file.exists (metaFname)) {
            logError ("Metadata file '%s' does not exist.", metaFname);
            return [];
        }

        foreach(line; std.file.slurp!(string)(metaFname, "%s")) {
            if (line.startsWith("data")) {
                // data = "data";
                auto splitResult = line.split("\"");
                if (splitResult.length == 3) {
                    dataFname = splitResult[1];
                    break;
                }
            }
        }

        auto dataTarFname = buildPath (repoRoot, dataFname ~ ".pkg");
        if (!std.file.exists (dataTarFname)) {
            logError ("Package lists file '%s' does not exist.", dataTarFname);
            return [];
        }

        ArchiveDecompressor ad;
        ad.open (dataTarFname);
        logDebug ("Opened: %s", dataTarFname);

        auto dataJson = parseJSON(assumeUTF(ad.readData(dataFname)));
        if (dataJson.type != JSONType.object) {
            logError ("JSON from '%s' is not an object .", dataTarFname);
            return [];
        }
        auto pkgs = appender!(Package[]);

        foreach(entry; dataJson.object["packages"].array) {
            if (entry.type == JSONType.object)
                pkgs ~= to!Package(new FreeBSDPackage(repoRoot, entry.object));
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
        if (!std.file.exists (fname)) {
            logError ("Working dir '%s' does not exist.", fname);
            return null;
        }
        return to!Package(FreeBSDPackage.createFromWorkdir(fname));
    }

    bool hasChanges (DataStore dstore, string suite, string section, string arch)
    {
        return true;
    }
}
