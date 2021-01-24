/*
 * Copyright (C) 2016-2019 Matthias Klumpp <matthias@tenstral.net>
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

import asgen.containers : HashMap;
import asgen.bindings.lmdb;
import asgen.config;
import asgen.logging;


/**
 * Contains a cache about available files in packages.
 * This is useful for finding icons and for re-scanning
 * packages which become interesting later.
 **/
final class ContentsStore
{

private:
    MDB_envp dbEnv;
    MDB_dbi dbContents;
    MDB_dbi dbIcons;
    MDB_dbi dbLocale;

    bool opened;

public:

    this ()
    {
        opened = false;
    }

    ~this ()
    {
        close ();
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
        static import std.math;

        int rc;
        assert (!opened);

        logDebug ("Opening contents cache.");

        // ensure the cache directory exists
        mkdirRecurse (dir);

        rc = mdb_env_create (&dbEnv);
        scope (success) opened = true;
        scope (failure) dbEnv.mdb_env_close ();
        checkError (rc, "mdb_env_create");

        // We are going to use at max 3 sub-databases:
        // contents, icons and locale
        rc = dbEnv.mdb_env_set_maxdbs (3);
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

        // contains list of locale files and related data
        rc = txn.mdb_dbi_open ("localedata", MDB_CREATE, &dbLocale);
        checkError (rc, "open locale-info database");

        rc = txn.mdb_txn_commit ();
        checkError (rc, "mdb_txn_commit");
    }

    void open (Config conf)
    {
        import std.path : buildPath;
        this.open (buildPath (conf.databaseDir, "contents"));
    }

    void close ()
    {
        synchronized (this) {
            if (opened)
                dbEnv.mdb_env_close ();
            opened = false;
            dbEnv = null;
        }
    }

    private MDB_val makeDbValue (const string data)
    {
        import core.stdc.string : strlen;
        MDB_val mval;
        auto cdata = data.toStringz ();
        mval.mv_size = char.sizeof * strlen (cdata) + 1;
        mval.mv_data = cast(void*) cdata;
        return mval;
    }

    private MDB_txnp newTransaction (uint flags = 0)
    in { assert (opened); }
    do
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

        res = txn.mdb_del (dbLocale, &key, null);
        if (res != MDB_NOTFOUND)
            checkError (res, "mdb_del (locale)");
    }

    bool packageExists (const string pkid)
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
        // filter out icon filenames and filenames of icon-related stuff (e.g. theme.index),
        // as well as locale information
        auto iconInfo = appender!(string[]);
        auto localeInfo = appender!(string[]);
        foreach (ref f; contents) {
            if ((f.startsWith ("/usr/share/icons/")) ||
                (f.startsWith ("/usr/share/pixmaps/"))) {
                    iconInfo ~= f;
                    continue;
                }

            // we do not limit the list to just stuff in `/usr/share/locale/` (mind the trailing
            // slash) but to anything starting with "locale", as Ubuntu
            // language packs install their translations into `/usr/share/locale-langpack`
            // and we want to find those too.
            if (f.startsWith ("/usr/share/locale")) {
                    if (f.endsWith (".mo") || f.endsWith (".qm") || f.endsWith (".pak"))
                        localeInfo ~= f;
                    continue;
            }
        }

        immutable contentsStr = contents.join ("\n");

        synchronized (this) {
            MDB_val key, contentsVal;

            key = makeDbValue (pkid);
            contentsVal = makeDbValue (contentsStr);

            auto txn = newTransaction ();
            scope (success) commitTransaction (txn);
            scope (failure) quitTransaction (txn);

            auto res = txn.mdb_put (dbContents, &key, &contentsVal, 0);
            checkError (res, "mdb_put");

            // if we have icon information, store that too
            if (!iconInfo.data.empty) {
                MDB_val iconsVal;

                immutable iconsStr = iconInfo.data.join ("\n");
                iconsVal = makeDbValue (iconsStr);

                res = txn.mdb_put (dbIcons, &key, &iconsVal, 0);
                checkError (res, "mdb_put (icons)");
            }

            // store locale
            if (!localeInfo.data.empty) {
                MDB_val localeVal;

                immutable localeStr = localeInfo.data.join ("\n");
                localeVal = makeDbValue (localeStr);

                res = txn.mdb_put (dbLocale, &key, &localeVal, 0);
                checkError (res, "mdb_put (locale)");
            }
        }
    }

    private HashMap!(string, string) getFilesMap (string[] pkids, MDB_dbi dbi, bool useBaseName = false)
    {
        import std.path : baseName;

        MDB_cursorp cur;

        auto txn = newTransaction (MDB_RDONLY);
        scope (exit) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbi, &cur);
        scope (exit) cur.mdb_cursor_close ();
        checkError (res, "mdb_cursor_open");

        HashMap!(string, string) pkgCMap;
        foreach (ref pkid; pkids) {
            MDB_val pkey = makeDbValue (pkid);
            MDB_val cval;

            res = cur.mdb_cursor_get (&pkey, &cval, MDB_SET);
            if (res == MDB_NOTFOUND)
                continue;
            checkError (res, "mdb_cursor_get");

            auto data = fromStringz (cast(char*) cval.mv_data);
            auto contents = to!string (data);

            foreach (const ref c; contents.split ("\n")) {
                if (useBaseName)
                    pkgCMap[c.baseName] = pkid;
                else
                    pkgCMap[c] = pkid;
            }
        }

        return pkgCMap;
    }

    auto getContentsMap (string[] pkids)
    {
        return getFilesMap (pkids, dbContents);
    }

    auto getIconFilesMap (string[] pkids)
    {
        return getFilesMap (pkids, dbIcons);
    }

    auto getLocaleMap (string[] pkids)
    {
        // we make the assumption here that all locale for a given domain are in one package.
        // otherwise this global search will get even more insane.
        // (that's why useBaseName is set to "true" - this could maybe change in future though
        return getFilesMap (pkids, dbLocale, true);
    }

    private string[] getContentsList (string pkid, MDB_dbi dbi)
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

    string[] getContents (string pkid)
    {
        return getContentsList (pkid, dbContents);
    }

    string[] getIcons (string pkid)
    {
        return getContentsList (pkid, dbIcons);
    }

    string[] getLocaleFiles (string pkid)
    {
        return getContentsList (pkid, dbLocale);
    }

    HashMap!(immutable string, bool) getPackageIdSet ()
    {
        MDB_cursorp cur;

        auto txn = newTransaction ();
        scope (exit) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbContents, &cur);
        scope (exit) cur.mdb_cursor_close ();
        checkError (res, "mdb_cursor_open (getPackageIdSet)");

        HashMap!(immutable string, bool) pkgSet;
        MDB_val pkey;
        while (cur.mdb_cursor_get (&pkey, null, MDB_NEXT) == 0) {
            immutable pkid = to!string (fromStringz (cast(char*) pkey.mv_data));
            pkgSet.put (pkid, true);
        }

        return pkgSet;
    }

    void removePackages (ref HashMap!(immutable string, bool) pkidSet)
    {
        auto txn = newTransaction ();
        scope (success) commitTransaction (txn);
        scope (failure) quitTransaction (txn);

        foreach (ref pkid; pkidSet.byKey) {
            auto key = makeDbValue (pkid);

            auto res = txn.mdb_del (dbContents, &key, null);
            checkError (res, "mdb_del (contents)");

            res = txn.mdb_del (dbIcons, &key, null);
            if (res != MDB_NOTFOUND)
                checkError (res, "mdb_del (icons)");
            res = txn.mdb_del (dbLocale, &key, null);
            if (res != MDB_NOTFOUND)
                checkError (res, "mdb_del (locale)");
        }
    }

    void sync ()
    in { assert (opened); }
    do
    {
        dbEnv.mdb_env_sync (1);
    }

}
