/*
 * Copyright (C) 2025 Victor Fuentes <vlinkz@snowflakeos.org>
 *
 * Based on the archlinux, alpinelinux, and freebsd backends, which are:
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 * Copyright (C) 2020 Rasmus Thomsen <oss@cogitri.dev>
 * Copyright (C) 2023 Serenity Cyber Security, LLC. Author: Gleb Popov <arrowd@FreeBSD.org>
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

module asgen.backends.nix.nixpkgindex;

import std.algorithm : canFind, startsWith;
import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json : JSONType, parseJSON;
import std.path : buildPath;
import std.process : execute;
import std.regex : matchFirst;
import std.string : chomp, empty, lastIndexOf, split, splitLines, strip;
static import std.file;

import asgen.backends.interfaces;
import asgen.backends.nix.nixindexutils;
import asgen.backends.nix.nixpkg;
import asgen.logging : logDebug, logError, logWarning;

final class NixPackageIndex : PackageIndex {

private:
    string storeUrl;
    string nixExe;
    Package[][string] pkgCache;

public:

    this (string storeUrl)
    {
        import glib.Util : Util;

        this.storeUrl = storeUrl;
        this.nixExe = Util.findProgramInPath("nix");
    }

    void release ()
    {
        pkgCache = null;
    }

    private Package[] loadPackages (string suite, string section, string arch)
    {
        if (this.nixExe.empty) {
            logError("nix binary not found. Cannot load nix packages.");
            return [];
        }

        auto pkgRoot = buildPath(suite, section, arch);

        auto packagesFname = generateNixPackagesIfNecessary(
                nixExe,
                suite,
                section,
                buildPath(pkgRoot, "packages.json")
        );

        auto packagesJson = parseJSON(std.file.readText(packagesFname));
        if (packagesJson.type != JSONType.object) {
            logError("JSON from '%s' is not an object .", packagesFname);
            return [];
        }
        logDebug("Opened: %s", packagesFname);

        auto pkgs = appender!(Package[]);

        string[string] attrToStorePath = getInterestingNixPkgs(nixExe, buildPath(pkgRoot, "index"), storeUrl, packagesJson);

        foreach (attr, storePath; attrToStorePath) {
            string pkgattr = attr;
            string pkgoutput = "out";
            auto lastDotIndex = pkgattr.lastIndexOf('.');
            if (lastDotIndex != -1) {
                pkgoutput = pkgattr[lastDotIndex + 1 .. $];
                pkgattr = pkgattr[0 .. lastDotIndex];
            }

            if (pkgattr !in packagesJson.object["packages"].object) {
                logError("Attribute %s not found in packages.json", pkgattr);
                continue;
            }

            auto entry = packagesJson.object["packages"].object[pkgattr];
            if (entry.type == JSONType.object) {
                // If output is in outputsToInstall, we don't need to state it explicitly
                if (auto meta = "meta" in entry) {
                    if (auto outputsToInstall = "outputsToInstall" in meta.object) {
                        if (outputsToInstall.array.canFind!(x => x.str == pkgoutput)) {
                            attr = chomp(attr, "." ~ pkgoutput);
                        }
                    }
                }
                pkgs ~= to!Package(new NixPackage(storeUrl, storePath, nixExe, attr, entry.object));
            }
        }

        return pkgs.data;
    }

    Package[] packagesFor (string suite, string section, string arch, bool withLongDescs = true)
    {
        immutable id = "%s-%s-%s".format(suite, section, arch);
        if (id !in pkgCache) {
            auto pkgs = loadPackages(suite, section, arch);
            synchronized (this)
                pkgCache[id] = pkgs;
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
