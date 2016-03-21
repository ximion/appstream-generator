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
    string location;
    string architecture;
    TagFile tagf;

    Package[] pkgList;
    bool pkgsLoaded;


public:

    this ()
    {
        tagf = new TagFile ();
        pkgsLoaded = false;
    }

    void open (string dir, string suite, string section, string arch)
    {
        this.location = dir;
        this.architecture = arch;

        auto indexFname = buildPath(dir, "dists", suite, section, format ("binary-%s", arch), "Packages.gz");
        if (!std.file.exists (indexFname))
            throw new Exception ("File '%s' does not exist.", indexFname);

        try {
            tagf.open (indexFname);
        } catch (Exception e) {
            throw e;
        }

        logDebug ("Opened: %s", indexFname);
    }

    void close ()
    {
        // Not needed
    }

    private Package[] getPackages ()
    {
        Package[] pkgs;
        assert (!pkgsLoaded);

        do {
            auto name = tagf.readField ("Package");
            auto ver  = tagf.readField ("Version");
            auto fname  = tagf.readField ("Filename");
            if (!name)
                continue;

            auto pkg = new DebPackage (name, ver, architecture);
            pkg.filename = buildPath (location, fname);

            if (!pkg.isValid ()) {
                logWarning ("Found invalid package (%s)! Skipping it.", pkg.toString ());
                continue;
            }

            pkgs ~= pkg;
        } while (tagf.nextSection ());

        pkgsLoaded = true;
        return pkgs;
    }

    @property
    Package[] packages ()
    {
        if (!pkgsLoaded)
            pkgList = getPackages ();
        return pkgList;
    }
}
