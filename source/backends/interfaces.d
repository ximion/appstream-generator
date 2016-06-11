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
public import ag.datacache;


/**
 * Represents a distribution package in the generator.
 */
interface Package
{
    @property string name () const;
    @property string ver () const;
    @property string arch () const;
    @property string maintainer () const;
    @property const(string[string]) description () const;

    @property string filename () const; // only used for diagnostic information and reporting
    @property string[] contents ();

    void setDescription (string desc,
                         string locale);

    const(ubyte)[] getFileData (string fname);
    void close ();

    static string getId (const Package pkg)
    {
        return "%s/%s/%s".format (pkg.name, pkg.ver, pkg.arch);
    }

    static bool isValid (Package pkg)
    {
        import std.array : empty;
        return (!pkg.name.empty ()) &&
               (!pkg.ver.empty ()) &&
               (!pkg.arch.empty ());
    }
}

/**
 * An index of information about packages in a distribution.
 */
interface PackageIndex
{
    /**
     * Called after a set of operations has completed, which allows the index to
     * release memory it might have allocated for cached data, or delete temporary
     * files.
     **/
    void release ();

    /**
     * Get a list of packages for the given suite/section/arch triplet.
     * The PackageIndex should cache the data if obtaining it is an expensive
     * operation, since the generator might query the data multiple times.
     **/
    Package[] packagesFor (string suite,
                           string section,
                           string arch);

    /**
     * Check if the index for the given suite/section/arch triplet has changed since
     * the last generator run. The index can use the (get/set)RepoInfo methods on DataCache
     * to store mtime or checksum data for the given suite.
     * For the lifetime of the PackagesIndex, this method must return the same result,
     * which means an internal cache is useful.
     */
    bool hasChanges (DataCache dcache,
                     string suite,
                     string section,
                     string arch);
}
