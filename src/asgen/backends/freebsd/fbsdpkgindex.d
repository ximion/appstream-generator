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

    Package[] packagesFor (string suite, string section, string arch, bool withLongDescs = true)
    {
        auto pkgRoot = buildPath (rootDir, suite);
        auto listsTarFname = buildPath (pkgRoot, "packagesite.pkg");
        if (!std.file.exists (listsTarFname)) {
            logWarning ("Package lists file '%s' does not exist.", listsTarFname);
            return [];
        }

        ArchiveDecompressor ad;
        ad.open (listsTarFname);
        logDebug ("Opened: %s", listsTarFname);

        auto d = ad.readData("packagesite.yaml");
        auto pkgs = appender!(Package[]);

        foreach(entry; d.split('\n')) {
            auto j = parseJSON(assumeUTF(entry));
            if (j.type == JSONType.object)
                pkgs ~= to!Package(new FreeBSDPackage(pkgRoot, j.object));
        }

        return pkgs.data;
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
