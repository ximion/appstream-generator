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

module ag.backend.debian.contentsindex;

import std.stdio;
import std.path;
import std.string;
import std.array : split;

import ag.logging;
import ag.archive;
import ag.backend.intf;
import ag.backend.debian.debpackage;
import ag.backend.debian.pkgindex;


class DebianContentsIndex : ContentsIndex
{

private:
    Package[string] filePkgMap;

public:

    this ()
    {

    }

    private string[] filePkgFromContentsLine (string rawLine)
    {
        auto line = rawLine.strip ();
        if (line.indexOf (" ") <= 0)
            return null;

        auto parts = line.split (" ");
        auto path = parts[0].strip ();
        auto group_pkg = join (parts[1..$]).strip ();

        string pkgname;
        if (group_pkg.indexOf ("/") > 0) {
            auto tmp = group_pkg.split ("/");
            pkgname = tmp[1].strip ();
        } else
            pkgname = group_pkg;

        return [path, pkgname];
    }

    void loadDataFor (string dir, string suite, string section, string arch, PackageIndex pindex = null)
    {
        import std.parallelism;

        auto contentsBaseName = format ("Contents-%s.gz", arch);
        auto contentsFname = buildPath (dir, "dists", suite, section, contentsBaseName);

        // Ubuntu does not place the Contents file in a component-specific directory,
        // so fall back to the global one.
        if (!std.file.exists (contentsFname)) {
            auto path = buildPath (dir, "dists", suite, contentsBaseName);
            if (std.file.exists (path))
                contentsFname = path;
        }

        string data;
        try {
            data = decompressFile (contentsFname);
        } catch (Exception e) {
            throw e;
        }

        if (pindex is null) {
            pindex = new DebianPackageIndex ();
            pindex.open (dir, suite, section, arch);
        }

        Package[string] pkgMap;
        foreach (pkg; pindex.packages) {
            pkgMap[pkg.name] = pkg;
        }

        // load and preprocess the large Contents file.
        foreach (line; parallel (splitLines (data))) {
            auto parts = filePkgFromContentsLine (line);
            if (parts is null)
                continue;
            if (parts.length != 2)
                continue;
            auto fname = "/" ~ parts[0];
            auto pkgname = parts[1];

            auto pkgP = (pkgname in pkgMap);
            // continue if package is not in map
            if (pkgP is null)
                continue;

            synchronized (this)
                filePkgMap[fname] = *pkgP;
        }

        logDebug ("Loaded: %s", contentsFname);
    }

    Package packageForFile (string fname)
    {
        auto pkgP = (fname in filePkgMap);
        if (pkgP is null)
            return null;

        return *pkgP;
    }

    @property string[] files ()
    {
        return filePkgMap.keys;
    }

    void close ()
    {
        // free resources
        filePkgMap = null;
    }
}

unittest
{
    import std.file : getcwd;
    import std.path : buildPath;
    import ag.backend.debian.pkgindex;
    writeln ("TEST: ", "Debian::ContentsIndex");

    auto samplePool = buildPath (getcwd(), "test", "samples", "debian");

    auto ci = new DebianContentsIndex ();
    auto pi = new DebianPackageIndex ();
    pi.open (samplePool, "chromodoris", "main", "amd64");
    ci.loadDataFor (samplePool, "chromodoris", "main", "amd64", pi);

    assert (ci.packageForFile ("/usr/include/AppStream/appstream.h").name == "libappstream-dev");
    assert (ci.packageForFile ("/usr/share/appdata/gnome-calculator.appdata.xml").name == "gnome-calculator");
}
