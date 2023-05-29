/*
 * Copyright (C) 2020 Rasmus Thomsen <oss@cogitri.dev>
 *
 * Based on the archlinux backend, which is:
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

module asgen.backends.alpinelinux.apkpkg;

import std.array : empty;
import std.format : format;
import std.path : baseName, buildNormalizedPath, buildPath;

import asgen.backends.interfaces;
import asgen.config : Config;
import asgen.downloader : Downloader;
import asgen.utils : isRemote;
import asgen.zarchive : ArchiveDecompressor;

final class AlpinePackage : Package {
private:
    string pkgname;
    string pkgver;
    string pkgarch;
    string pkgmaintainer;
    string[string] desc;
    string pkgFname;
    string localPkgFName;
    string tmpDir;

    string[] contentsL = null;

    ArchiveDecompressor archive;

public:
    this (string pkgname, string pkgver, string pkgarch)
    {
        this.pkgname = pkgname;
        this.pkgver = pkgver;
        this.pkgarch = pkgarch;

        auto conf = Config.get();
        this.tmpDir = buildPath(conf.getTmpDir(), format("%s-%s_%s", name, ver, arch));
    }

    override @property string name () const
    {
        return this.pkgname;
    }

    @property void name (string val)
    {
        this.pkgname = val;
    }

    override @property string ver () const
    {
        return this.pkgver;
    }

    @property void ver (string val)
    {
        this.pkgver = val;
    }

    override @property string arch () const
    {
        return this.pkgarch;
    }

    @property void arch (string val)
    {
        this.pkgarch = val;
    }

    override @property const(string[string]) description () const
    {
        return this.desc;
    }

    @property void filename (string fname)
    {
        this.pkgFname = fname;
    }

    override @property string getFilename ()
    {
        if (!this.localPkgFName.empty)
            return this.localPkgFName;

        if (pkgFname.isRemote) {
            synchronized (this) {
                auto dl = Downloader.get;
                immutable path = buildNormalizedPath(this.tmpDir, this.pkgFname.baseName);
                dl.downloadFile(this.pkgFname, path);
                this.localPkgFName = path;
                return this.localPkgFName;
            }
        } else {
            this.localPkgFName = pkgFname;
            return this.localPkgFName;
        }
    }

    override @property string maintainer () const
    {
        return this.pkgmaintainer;
    }

    @property void maintainer (string maint)
    {
        this.pkgmaintainer = maint;
    }

    void setDescription (string text, string locale)
    {
        this.desc[locale] = text;
    }

    override const(ubyte)[] getFileData (string fname)
    {
        if (!this.archive.isOpen())
            this.archive.open(this.getFilename);

        return this.archive.readData(fname);
    }

    @property override string[] contents ()
    {
        if (!this.contentsL.empty)
            return this.contentsL;

        ArchiveDecompressor ad;
        ad.open(this.getFilename);
        this.contentsL = ad.readContents();

        return this.contentsL;
    }

    @property void contents (string[] c)
    {
        this.contentsL = c;
    }

    override void finish ()
    {
    }
}
