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

module ag.contentscache;

import std.stdio;
import std.string;
import std.conv : to;
import std.file : mkdirRecurse;
import std.array : join, split, empty;

import c.lmdb;
import ag.logging;


/**
 * Contains a cache about available files in packages.
 * This is useful for finding icons and for re-scanning
 * packages which become interesting later.
 **/
class ContentsCache
{

private:
    MDB_envp dbEnv;
    MDB_dbi dbi;

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

        // ensure the cache directory exists
        mkdirRecurse (dir);

        rc = mdb_env_create (&dbEnv);
        scope (success) opened = true;
        scope (failure) dbEnv.mdb_env_close ();
        checkError (rc, "mdb_env_create");

        // set a huge map size to be futureproof.
        // This means we're cruel to non-64bit users, but this
        // software is supposed to be run on 64bit machines anyway.
        auto mapsize = cast (size_t) std.math.pow (1024L, 4);
        rc = dbEnv.mdb_env_set_mapsize (mapsize);
        checkError (rc, "mdb_env_set_mapsize");

        // open database
        rc = dbEnv.mdb_env_open (dir.toStringz (), MDB_NOMETASYNC, std.conv.octal!755);
        checkError (rc, "mdb_env_open");

        // get dbi
        MDB_txnp txn;
        rc = dbEnv.mdb_txn_begin (null, 0, &txn);
        checkError (rc, "mdb_txn_begin");
        scope (failure) txn.mdb_txn_abort ();

        rc = txn.mdb_dbi_open (null, MDB_CREATE, &dbi);
        checkError (rc, "open contents database");

        rc = txn.mdb_txn_commit ();
        checkError (rc, "mdb_txn_commit");
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

        auto res = txn.mdb_del (dbi, &key, null);
        checkError (res, "mdb_del");
    }

    bool packageExists (string pkid)
    {
        MDB_val dkey;
        MDB_cursorp cur;

        dkey = makeDbValue (pkid);
        auto txn = newTransaction (MDB_RDONLY);
        scope (exit) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbi, &cur);
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

        string contentsStr = contents.join ("\n");
        key = makeDbValue (pkid);
        value = makeDbValue (contentsStr);

        auto txn = newTransaction ();
        scope (success) commitTransaction (txn);
        scope (failure) quitTransaction (txn);

        auto res = txn.mdb_put (dbi, &key, &value, 0);
        checkError (res, "mdb_put");
    }

    string[string] getContents ()
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
        while (cur.mdb_cursor_get (&pkey, &cval, MDB_NEXT) == 0) {
            auto pkid = std.conv.to!string (fromStringz (cast(char*) pkey.mv_data));
            auto contentsStr = std.conv.to!string (fromStringz (cast(char*) cval.mv_data));
            if (contentsStr.empty)
                continue;
            string[] contents = contentsStr.split ("\n");
            foreach (c; contents)
                pkgCMap[c] = pkid;
        }

        return pkgCMap;
    }

    string[] getContents (string pkid)
    {
        MDB_val pkey, cval;
        MDB_cursorp cur;

        pkey = makeDbValue (pkid);

        auto txn = newTransaction (MDB_RDONLY);
        scope (exit) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbi, &cur);
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

}
