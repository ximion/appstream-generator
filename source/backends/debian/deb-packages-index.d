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
//import std.experimental.logger;
import ag.backend.intf;
import ag.backend.debian.tagfile;
import ag.backend.debian.debpackage;


class DebianPackagesIndex : PackagesIndex
{

private:
    string location;
    string architecture;
    TagFile tagf;


public:

    this ()
    {
        tagf = new TagFile ();
    }

    void open (string dir, string suite, string section, string arch)
    {
        location = dir;
        architecture = arch;

        auto index_fname = buildPath(dir, "dists", suite, section, format ("binary-%s", arch), "Packages.gz");
        if (!std.file.exists (index_fname))
            throw new Exception ("File '%s' does not exist.", index_fname);

        try {
            tagf.open (index_fname);
        } catch (Exception e) {
            throw e;
        }
    }

    void close ()
    {
        // Not needed
    }

    DList!Package getPackages ()
    {
        DList!Package pkgs;

        do {
            auto name = tagf.readField ("Package");
            auto ver  = tagf.readField ("Version");
            auto fname  = tagf.readField ("Filename");

            auto pkg = new DebPackage (name, ver, architecture);
            pkg.filename = buildPath (location, fname);

            if (!pkg.isValid ()) {
                writeln ("WARNING: Found invalid package! Skipping it.");
                continue;
            }

            pkgs.insertBack (pkg);
        } while (tagf.nextSection ());

        return pkgs;
    }
}
