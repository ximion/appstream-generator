/*
 * Copyright (C) 2020 Rasmus Thomsen <oss@cogitri.dev>
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

module asgen.backends.alpinelinux.apkpkgindex;

import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.format : format;
import std.path : baseName, buildPath;
import std.utf : validate;

import asgen.config : Config;
import asgen.logging : logError;
import asgen.zarchive : ArchiveDecompressor;
import asgen.utils : escapeXml, isRemote;
import asgen.backends.interfaces;
import asgen.backends.alpinelinux.apkpkg;
import asgen.backends.alpinelinux.apkindexutils;

final class AlpinePackageIndex : PackageIndex {

private:
    string rootDir;
    string tmpDir;
    Package[][string] pkgCache;

public:

    this (string dir)
    {
        if (!dir.isRemote)
            enforce (exists(dir), format("Directory '%s' does not exist.", dir));

        this.rootDir = dir;

        auto conf = Config.get();
        tmpDir = buildPath(conf.getTmpDir, dir.baseName);
    }

    override void release ()
    {
        pkgCache = null;
    }

    private void setPkgDescription (AlpinePackage pkg, string pkgDesc)
    {
        if (pkgDesc is null)
            return;

        auto desc = "<p>%s</p>".format(pkgDesc.escapeXml);
        pkg.setDescription(desc, "C");
    }

    private Package[] loadPackages (string suite, string section, string arch)
    {
        auto apkRootPath = buildPath(rootDir, suite, section, arch);
        auto indexFPath = downloadIfNecessary(apkRootPath, tmpDir, "APKINDEX.tar.gz", format(
                "APKINDEX-%s-%s-%s.tar.gz", suite, section, arch));
        AlpinePackage[string] pkgsMap;
        ArchiveDecompressor ad;
        ad.open(indexFPath);
        auto indexString = cast(string) ad.readData("APKINDEX");
        validate(indexString);
        auto range = ApkIndexBlockRange(indexString);

        foreach (pkgInfo; range) {
            auto fileName = pkgInfo.archiveName;
            AlpinePackage pkg;
            if (fileName in pkgsMap) {
                pkg = pkgsMap[fileName];
            } else {
                pkg = new AlpinePackage(pkgInfo.pkgname, pkgInfo.pkgversion, pkgInfo.arch);
                pkgsMap[fileName] = pkg;
            }

            pkg.filename = buildPath(rootDir, suite, section, arch, fileName);
            pkg.maintainer = pkgInfo.maintainer;
            setPkgDescription(pkg, pkgInfo.pkgdesc);
        }

        // perform a sanity check, so we will never emit invalid packages
        auto pkgs = appender!(Package[]);
        if (pkgsMap.length > 20)
            pkgs.reserve((pkgsMap.length.to!long - 10).to!size_t);
        foreach (ref pkg; pkgsMap.byValue())
            if (pkg.isValid)
                pkgs ~= pkg;
            else
                logError("Found an invalid package (name, architecture or version is missing). This is a bug.");

        return pkgs.data;
    }

    override Package[] packagesFor (string suite, string section, string arch, bool withLongDescs = true)
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
        // Alpine currently doesn't have a way other than querying a web API
        // to tell what package owns a file, unless that packages is installed
        // on the system.
        return null;
    }

    bool hasChanges (DataStore dstore, string suite, string section, string arch)
    {
        return true;
    }
}
