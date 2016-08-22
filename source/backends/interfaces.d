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

module backends.interfaces;

import appstream.Component;
import glib.KeyFile;

import std.string;
import std.container;
public import datastore;


/**
 * Represents a distribution package in the generator.
 */
abstract class Package
{
    @property string name () const @safe pure;
    @property string ver () const @safe pure;
    @property string arch () const @safe pure;
    @property string maintainer () const;
    @property Package[] otherPackages;

    /**
     * A associative array containing package descriptions.
     * Key is the language (or locale), value the description.
     *
     * E.g.: ["en": "A description.", "de": "Eine Beschreibung"]
     */
    @property const(string[string]) description () const;

    /**
     * Filename of the package. This string is only used for
     * issue reporting and other information, the file is never
     * accessed directly (all data is retrieved via getFileData())
     */
    @property string filename () const;

    /**
     * A list payload files this package contains.
     */
    @property string[] contents ();

    /**
     * Obtain data for a specific file in the package.
     */
    abstract const(ubyte)[] getFileData (string fname);

    /**
     * Retrieve backend-specific translations.
     */
    string[string] processDesktopFile (KeyFile desktopFile, const string text) { return null; }

    /**
     * Close the package. This function is called when we will
     * no longer request any file data from this package.
     */
    abstract void close ();

    private string pkid;
    /**
     * Get the unique identifier for this package.
     * The ID is supposed to be unique per backend, it should never appear
     * multiple times in suites/sections.
     */
    @property
    final string id () @safe pure
    {
        import std.array : empty;
        if (pkid.empty)
            pkid = "%s/%s/%s".format (this.name, this.ver, this.arch);
        return pkid;
    }

    /**
     * Check if the package is valid.
     * A Package must at least have a name, version and architecture defined.
     */
    @safe pure
    final bool isValid ()
    {
        import std.array : empty;
        return (!name.empty) &&
               (!ver.empty) &&
               (!arch.empty);
    }

    @safe pure override
    string toString ()
    {
        return id;
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
    bool hasChanges (DataStore dstore,
                     string suite,
                     string section,
                     string arch);
}
