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

module asgen.backends.dummy.dummypkg;

import std.stdio;
import std.string;
import std.array : empty;
import asgen.backends.interfaces;
import asgen.logging;


final class DummyPackage : Package
{
private:
    string pkgname;
    string pkgver;
    string pkgarch;
    string pkgmaintainer;
    string[string] desc;
    string testPkgFname;

public:
    @property override string name () const { return pkgname; }
    @property override string ver () const { return pkgver; }
    @property override string arch () const { return pkgarch; }

    @property override const(string[string]) description () const { return desc; }

    override
    @property string filename () const { return testPkgFname; }
    @property void   filename (string fname) { testPkgFname = fname; }

    override
    @property string maintainer () const { return pkgmaintainer; }
    @property void   maintainer (string maint) { pkgmaintainer = maint; }

    this (string pname, string pver, string parch)
    {
        pkgname = pname;
        pkgver = pver;
        pkgarch = parch;
    }

    void setDescription (string text, string locale)
    {
        desc[locale] = text;
    }

    override
    ubyte[] getFileData (string fname)
    {
        return ['N', 'O', 'T', 'H', 'I', 'N', 'G'];
    }

    @property override
    string[] contents ()
    {
        return ["NOTHING1", "NOTHING2"];
    }

    override
    void close ()
    {
    }
}
