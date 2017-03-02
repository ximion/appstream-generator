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

module asgen.backends.rpmmd.rpmpkgindex;

import std.stdio;
import std.path;
import std.string;
import std.algorithm : canFind;
static import std.file;

import asgen.logging;
import asgen.backends.interfaces;
import asgen.backends.rpmmd.rpmpkg;


final class RPMPackageIndex : PackageIndex
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

    private void setPkgDescription (RPMPackage pkg, string pkgDesc)
    {
        if (pkgDesc is null)
            return;

        auto desc = "<p>%s</p>".format (pkgDesc);
        pkg.setDescription (desc, "C");
    }

    private Package[] loadPackages (string suite, string section, string arch)
    {
        auto metadataRoot = buildPath (rootDir, "distrib", suite, arch, "media", section, "release", "repodata");

        // read repomd.xml

        Package[] pkgs;
        return pkgs;
    }

    Package[] packagesFor (string suite, string section, string arch)
    {
        immutable id = "%s-%s-%s".format (suite, section, arch);
        if (id !in pkgCache) {
            auto pkgs = loadPackages (suite, section, arch);
            synchronized (this) pkgCache[id] = pkgs;
        }

        return pkgCache[id];
    }

    bool hasChanges (DataStore dstore, string suite, string section, string arch)
    {
        return true;
    }
}
