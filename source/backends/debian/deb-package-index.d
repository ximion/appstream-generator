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
import std.container;

import ag.logging;
import ag.backend.intf;
import ag.backend.debian.tagfile;
import ag.backend.debian.debpackage;


class DebianPackageIndex : PackageIndex
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
        auto indexFname = buildPath (rootDir, "dists", suite, section, format ("binary-%s", arch), "Packages.gz");
        if (!std.file.exists (indexFname))
            throw new Exception ("File '%s' does not exist.", indexFname);

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

        return pkgs.values ();
    }

    Package[] packagesFor (string suite, string section, string arch)
    {
        string id = suite ~ "/" ~ section ~ "/" ~ arch;
        if (id !in pkgCache) {
            pkgCache[id] = loadPackages (suite, section, arch);
        }

        return pkgCache[id];
    }
}
