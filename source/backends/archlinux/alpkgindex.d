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

module ag.backend.archlinux.pkgindex;

import std.stdio;
import std.path;
import std.string;
import std.algorithm : canFind;

import ag.logging;
import ag.archive;
import ag.backend.intf;
import ag.backend.archlinux.alpkg;
import ag.backend.archlinux.listfile;


class ArchPackageIndex : PackageIndex
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

    private void setPkgDescription (ArchPackage pkg, string pkgDesc)
    {
        if (pkgDesc is null)
            return;

        auto desc = "<p>" ~ pkgDesc ~ "</p>";
        pkg.setDescription (desc, "C");
    }

    private Package[] loadPackages (string suite, string section, string arch)
    {
        auto pkgRoot = buildPath (rootDir, suite, section, "os", arch);
        auto listsTarFname = buildPath (pkgRoot, format ("%s.files.tar.gz", section));
        if (!std.file.exists (listsTarFname)) {
            logWarning ("Package lists tarball '%s' does not exist.", listsTarFname);
            return [];
        }

        auto ad = new ArchiveDecompressor ();
        ad.open (listsTarFname);
        auto tarContents = ad.readContents ();

        logDebug ("Opened: %s", listsTarFname);

        // TODO: This approach is very slow - we want a generator in ArchiveDecompressor,
        // allowing us to go through the tarball and extract interesting entries immediately,
        // without reopening the archive and scanning through it over and over again.

        Package[] pkgs;
        foreach (fname; tarContents) {
            if (baseName (fname) != "desc")
                continue;

            auto descData = ad.readData (fname);
            auto descF = new ListFile ();
            descF.loadData (descData);

            auto filesData = ad.readData (buildNormalizedPath (fname, "..", "files"));
            auto filesF = new ListFile ();
            filesF.loadData (filesData);

            auto pkg = new ArchPackage (descF.getEntry ("NAME"),
                                        descF.getEntry ("VERSION"),
                                        descF.getEntry ("ARCH"));
            pkg.maintainer = descF.getEntry ("PACKAGER");
            pkg.filename = buildPath (pkgRoot, descF.getEntry ("FILENAME"));
            setPkgDescription (pkg, descF.getEntry ("DESC"));

            auto filesStr = filesF.getEntry ("FILES");
            if (filesStr is null) {
                if (!pkg.name.canFind ("-meta")) {
                    logError ("Package '%s' has no file list set. Ignoring it.", pkg.toString ());
                    continue;
                }
            }

            string[] contents;
            foreach (l; filesStr.splitLines ())
                contents ~= "/" ~ l;
            pkg.contents = contents;

            pkgs ~= pkg;
        }

        return pkgs;
    }

    Package[] packagesFor (string suite, string section, string arch)
    {
        if ((suite == "arch") || (suite == "archlinux"))
            suite = "";

        string id = suite ~ "-" ~ section ~ "-" ~ arch;
        if (id !in pkgCache) {
            auto pkgs = loadPackages (suite, section, arch);
            synchronized (this) pkgCache[id] = pkgs;
        }

        return pkgCache[id];
    }
}
