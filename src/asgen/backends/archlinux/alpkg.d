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

module asgen.backends.archlinux.alpkg;

import std.stdio;
import std.string;
import std.array : empty;

import asgen.logging;
import asgen.zarchive;
import asgen.backends.interfaces;


class ArchPackage : Package
{
private:
    string pkgname;
    string pkgver;
    string pkgarch;
    string pkgmaintainer;
    string[string] desc;
    string pkgFname;

    string[] contentsL;

    ArchiveDecompressor archive;

public:
    override
    @property string name () const { return pkgname; }
    @property void   name (string val) { pkgname = val; }

    override
    @property string ver () const { return pkgver; }
    @property void   ver (string val) { pkgver = val; }

    override
    @property string arch () const { return pkgarch; }
    @property void   arch (string val) { pkgarch = val; }

    override
    @property const(string[string]) description () const { return desc; }

    override
    @property string filename () const { return pkgFname; }
    @property void filename (string fname) { pkgFname = fname; }

    override
    @property string maintainer () const { return pkgmaintainer; }
    @property void maintainer (string maint) { pkgmaintainer = maint; }

    void setDescription (string text, string locale)
    {
        desc[locale] = text;
    }

    override
    const(ubyte)[] getFileData (string fname)
    {
        if (archive is null) {
            archive = new ArchiveDecompressor ();
            archive.open (this.filename);
        }

        return archive.readData (fname);
    }

    @property override
    string[] contents ()
    {
        return contentsL;
    }

    @property
    void contents (string[] c)
    {
        contentsL = c;
    }

    override
    void close ()
    {
        archive = null;
    }
}
