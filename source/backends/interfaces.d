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

module ag.backend.intf;

import std.string;
import std.container;


/**
 * Represents a distribution package in the generator.
 */
interface Package
{
    @property string name ();
    @property string ver ();
    @property string arch ();
    @property string[string] description ();
    @property string filename ();
    @property void filename (string fname);

    string[] getContentsList ();
    string getFileData (string fname);
    void close ();

    static string getId (Package pkg)
    {
        return format ("%s/%s/%s", pkg.name, pkg.ver, pkg.arch);
    }
}

/**
 * An index of information about packages in a distribution.
 */
interface PackagesIndex
{
    void open (string dir, string suite, string section, string arch);
    void close ();

    Package[] getPackages ();
}

/**
 * An index containing a mapping of files to packages.
 */
interface ContentsIndex
{
    void open (string suite, string arch);
    void close ();
}
