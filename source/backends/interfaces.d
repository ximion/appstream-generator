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
    @property string maintainer ();
    @property string[string] description ();

    @property string filename ();   // only used for diagnostic information and reporting
    @property string[] contents ();

    void setDescription (string desc, string locale);

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
interface PackageIndex
{
    void release ();

    Package[] packagesFor (string suite, string section, string arch);
}
