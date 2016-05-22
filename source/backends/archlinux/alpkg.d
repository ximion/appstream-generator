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

module ag.backend.archlinux.alpkg;

import std.stdio;
import std.string;
import std.array : empty;

import ag.logging;
import ag.archive;
import ag.backend.intf;


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
    @property string name () { return pkgname; }
    @property void   name (string val) { pkgname = val; }
    @property string ver () { return pkgver; }
    @property void   ver (string val) { pkgver = val; }
    @property string arch () { return pkgarch; }
    @property void   arch (string val) { pkgarch = val; }
    @property string[string] description () { return desc; }
    @property string filename () { return pkgFname; }
    @property void filename (string fname) { pkgFname = fname; }
    @property string maintainer () { return pkgmaintainer; }
    @property void maintainer (string maint) { pkgmaintainer = maint; }

    bool isValid ()
    {
        if ((!name) || (!ver) || (!arch))
            return false;
        return true;
    }

    override
    string toString ()
    {
        return format ("%s/%s/%s", name, ver, arch);
    }

    void setDescription (string text, string locale)
    {
        desc[locale] = text;
    }

    const(ubyte)[] getFileData (string fname)
    {
        if (archive is null) {
            archive = new ArchiveDecompressor ();
            archive.open (this.filename);
        }

        return archive.readData (fname);
    }

    @property
    string[] contents ()
    {
        return contentsL;
    }

    @property
    void contents (string[] c)
    {
        contentsL = c;
    }

    void close ()
    {
        archive = null;
    }
}
