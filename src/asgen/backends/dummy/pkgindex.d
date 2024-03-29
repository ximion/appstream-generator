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

module asgen.backends.dummy.pkgindex;

import std.stdio;
import std.path;
import std.string;
import std.algorithm : remove;

import asgen.logging;
import asgen.backends.interfaces;
import asgen.backends.dummy.dummypkg;

final class DummyPackageIndex : PackageIndex {

private:
    Package[][string] pkgCache;

public:

    this (string dir)
    {
    }

    void release ()
    {
        pkgCache = null;
    }

    Package[] packagesFor (string suite, string section, string arch, bool withLongDescs = true)
    {
        return [new DummyPackage("test", "1.0", "amd64")];
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
