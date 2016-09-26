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

module asgen.contentsstore;

import std.stdio;
import std.string;
import std.conv : to, octal;
import std.file : mkdirRecurse;
import std.array : appender, join, split, empty;
static import std.math;

import asgen.bindings.lmdb;
import asgen.config;
import asgen.logging;


/**
 * Contains a cache about available files in packages.
 * This is useful for finding icons and for re-scanning
 * packages which become interesting later.
 **/
class ContentsStore
{

private:
    MDB_envp dbEnv;
    MDB_dbi dbContents;
    MDB_dbi dbIcons;

    bool opened;

public:

    this ()
    {
        opened = false;
    }

    ~this ()
    {
        if (opened)
            dbEnv.mdb_env_close ();
    }

    private void checkError (int rc, string msg)
    {
        if (rc != 0) {
            import std.format;
            throw new Exception (format ("%s[%s]: %s", msg, rc, mdb_strerror (rc).fromStringz));
        }
    }

    void open (string dir)
    {
        int rc;
        assert (!opened);

        logDebug ("Opening contents cache.");

        // ensure the cache directory exists
        mkdirRecurse (dir);

        rc = mdb_env_create (&dbEnv);
        scope (success) opened = true;
        scope (failure) dbEnv.mdb_env_close ();
        checkError (rc, "mdb_env_create");

        // We are going to use at max 2 sub-databases:
        // contents and icons
        rc = dbEnv.mdb_env_set_maxdbs (2);
        checkError (rc, "mdb_env_set_maxdbs");

        // set a huge map size to be futureproof.
        // This means we're cruel to non-64bit users, but this
        // software is supposed to be run on 64bit machines anyway.
        auto mapsize = cast (size_t) std.math.pow (512L, 4);
        rc = dbEnv.mdb_env_set_mapsize (mapsize);
        checkError (rc, "mdb_env_set_mapsize");

        // open database
        rc = dbEnv.mdb_env_open (dir.toStringz (),
                                 MDB_NOMETASYNC | MDB_NOTLS,
                                 octal!755);
        checkError (rc, "mdb_env_open");

        // open sub-databases in the environment
        MDB_txnp txn;
        rc = dbEnv.mdb_txn_begin (null, 0, &txn);
        checkError (rc, "mdb_txn_begin");
        scope (failure) txn.mdb_txn_abort ();

        // contains a full list of all contents
        rc = txn.mdb_dbi_open ("contents", MDB_CREATE, &dbContents);
        checkError (rc, "open contents database");

        // contains list of icon files and related data
        // the contents sub-database exists only to allow building instances
        // of IconHandler much faster.
        rc = txn.mdb_dbi_open ("icondata", MDB_CREATE, &dbIcons);
        checkError (rc, "open icon-info database");

        rc = txn.mdb_txn_commit ();
        checkError (rc, "mdb_txn_commit");
    }

    void open (Config conf)
    {
        import std.path : buildPath;
        this.open (buildPath (conf.databaseDir, "contents"));
    }

    private MDB_val makeDbValue (string data)
    {
        import core.stdc.string : strlen;
        MDB_val mval;
        auto cdata = data.toStringz ();
        mval.mv_size = char.sizeof * strlen (cdata) + 1;
        mval.mv_data = cast(void *) cdata;
        return mval;
    }

    private MDB_txnp newTransaction (uint flags = 0)
    {
        int rc;
        MDB_txnp txn;

        rc = dbEnv.mdb_txn_begin (null, flags, &txn);
        checkError (rc, "mdb_txn_begin");

        return txn;
    }

    private void commitTransaction (MDB_txnp txn)
    {
        auto rc = txn.mdb_txn_commit ();
        checkError (rc, "mdb_txn_commit");
    }

    private void quitTransaction (MDB_txnp txn)
    {
        if (txn is null)
            return;
        txn.mdb_txn_abort ();
    }

    /**
     * Drop a package-id from the contents cache.
     */
    void removePackage (string pkid)
    {
        MDB_val key;

        key = makeDbValue (pkid);

        auto txn = newTransaction ();
        scope (success) commitTransaction (txn);
        scope (failure) quitTransaction (txn);

        auto res = txn.mdb_del (dbContents, &key, null);
        checkError (res, "mdb_del (contents)");

        res = txn.mdb_del (dbIcons, &key, null);
        if (res != MDB_NOTFOUND)
            checkError (res, "mdb_del (icons)");
    }

    bool packageExists (string pkid)
    {
        MDB_val dkey;
        MDB_cursorp cur;

        dkey = makeDbValue (pkid);
        auto txn = newTransaction (MDB_RDONLY);
        scope (exit) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbContents, &cur);
        scope (exit) cur.mdb_cursor_close ();
        checkError (res, "mdb_cursor_open");

        res = cur.mdb_cursor_get (&dkey, null, MDB_SET);
        if (res == MDB_NOTFOUND)
            return false;
        checkError (res, "mdb_cursor_get");

        return true;
    }

    void addContents (string pkid, string[] contents)
    {
        MDB_val key, value;

        // filter out icon filenames and filenames of icon-related stuff (e.g. theme.index)
        auto iconInfo = appender!(string[]);
        foreach (ref c; contents) {
            if ((c.startsWith ("/usr/share/icons/")) ||
                (c.startsWith ("/usr/share/pixmaps/"))) {
                    iconInfo ~= c;
                }
        }

        immutable contentsStr = contents.join ("\n");
        key = makeDbValue (pkid);
        value = makeDbValue (contentsStr);

        auto txn = newTransaction ();
        scope (success) commitTransaction (txn);
        scope (failure) quitTransaction (txn);

        auto res = txn.mdb_put (dbContents, &key, &value, 0);
        checkError (res, "mdb_put");

        if (!iconInfo.data.empty) {
            // we have icon information, store it too
            immutable iconsStr = iconInfo.data.join ("\n");
            value = makeDbValue (iconsStr);

            res = txn.mdb_put (dbIcons, &key, &value, 0);
            checkError (res, "mdb_put (icons)");
        }
    }

    private string[string] getFilesMap (string[] pkids, MDB_dbi dbi)
    {
        MDB_cursorp cur;

        auto txn = newTransaction (MDB_RDONLY);
        scope (exit) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbi, &cur);
        scope (exit) cur.mdb_cursor_close ();
        checkError (res, "mdb_cursor_open");

        string[string] pkgCMap;

        MDB_val pkey;
        MDB_val cval;

        foreach (ref pkid; pkids) {
            pkey = makeDbValue (pkid);

            res = cur.mdb_cursor_get (&pkey, &cval, MDB_SET);
            if (res == MDB_NOTFOUND)
                continue;
            checkError (res, "mdb_cursor_get");

            auto data = fromStringz (cast(char*) cval.mv_data);
            auto contents = to!string (data);

            foreach (ref c; contents.split ("\n")) {
                pkgCMap[c] = pkid;
            }
        }

        return pkgCMap;
    }

    string[string] getContentsMap (string[] pkids)
    {
        return getFilesMap (pkids, dbContents);
    }

    string[string] getIconFilesMap (string[] pkids)
    {
        return getFilesMap (pkids, dbIcons);
    }

    string[] getContents (string pkid)
    {
        MDB_val pkey, cval;
        MDB_cursorp cur;

        pkey = makeDbValue (pkid);

        auto txn = newTransaction (MDB_RDONLY);
        scope (exit) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbContents, &cur);
        scope (exit) cur.mdb_cursor_close ();
        checkError (res, "mdb_cursor_open");

        res = cur.mdb_cursor_get (&pkey, &cval, MDB_SET);
        if (res == MDB_NOTFOUND)
            return null;
        checkError (res, "mdb_cursor_get");

        auto data = fromStringz (cast(char*) cval.mv_data);
        auto contentsStr = to!string (data);

        return contentsStr.split ("\n");
    }

    void removePackagesNotInSet (bool[string] pkgSet)
    {
        MDB_cursorp cur;

        auto txn = newTransaction ();
        scope (success) commitTransaction (txn);
        scope (failure) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbContents, &cur);
        scope (exit) cur.mdb_cursor_close ();
        checkError (res, "mdb_cursor_open (pkgcruft_contents)");

        MDB_val pkey;
        while (cur.mdb_cursor_get (&pkey, null, MDB_NEXT) == 0) {
            immutable pkid = to!string (fromStringz (cast(char*) pkey.mv_data));
            if (pkid in pkgSet)
                continue;

            // if we got here, the package is not in the set of valid packages,
            // and we can remove it.
            res = cur.mdb_cursor_del (0);
            checkError (res, "mdb_del");

            res = txn.mdb_del (dbIcons, &pkey, null);
            if (res != MDB_NOTFOUND)
                checkError (res, "mdb_del (icons)");
        }
    }

}
