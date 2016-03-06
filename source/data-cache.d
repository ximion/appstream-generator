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

module ag.datacache;

import std.stdio;
import std.string;
import std.file : mkdirRecurse;
import lmdb;

import ag.logging;


class DataCache
{

private:
    MDB_envp env;
    MDB_dbi dbDataXml;
    MDB_dbi dbDataYaml;
    MDB_dbi dbPackages;
    MDB_dbi dbHints;
    MDB_dbi dbStats;

public:

    this ()
    {
    }

    ~this ()
    {
        if (env !is null)
            env.mdb_env_close();
    }

    private void checkError (int rc, string msg)
    {
        if (rc != 0) {
            import std.format;
            throw new Exception (format ("%s[%s]: %s", msg, rc, mdb_strerror (rc).fromStringz));
        }
    }

    private void printVersionDbg ()
    {
        import std.stdio : writeln;
        int major, minor, patch;
        auto ver = mdb_version(&major, &minor, &patch);
        debugmsg ("Using %s major=%s minor=%s patch=%s", ver.fromStringz, major, minor, patch);
    }

    void open (string dir)
    {
        int rc;

        // add LMDB version we are using to the debug output
        printVersionDbg ();

        // ensure the cache directory exists
        mkdirRecurse (dir);

        rc = mdb_env_create(&env);
        checkError (rc, "mdb_env_create");

        // We are going to use at max 5 sub-databases:
        // packages, hints, metadata_xml, metadata_yaml, statistics
        rc = env.mdb_env_set_maxdbs (5);
        checkError (rc, "mdb_env_set_maxdbs");

        // open database
        rc = env.mdb_env_open (dir.toStringz (), MDB_NOMETASYNC, std.conv.octal!755);
        checkError (rc, "mdb_env_open");

        // set a huge map size to be futureproof.
        // This means we're cruel to non-64bit users, but this
        // software is supposed to be run on 64bit machines anyway.
        auto mapsize = cast (size_t) std.math.pow (1024, 4);
        rc = env.mdb_env_set_mapsize (mapsize);
        checkError (rc, "mdb_env_set_mapsize");

        // open sub-databases in the environment
        MDB_txnp txn;
        rc = env.mdb_txn_begin (null, 0, &txn);
        checkError (rc, "mdb_txn_begin");
        scope (exit) txn.mdb_txn_abort ();

        rc = txn.mdb_dbi_open ("packages", MDB_CREATE, &dbPackages);
        checkError (rc, "open packages database");

        rc = txn.mdb_dbi_open ("hints", MDB_CREATE, &dbHints);
        checkError (rc, "open hints database");

        rc = txn.mdb_dbi_open ("metadata_xml", MDB_CREATE, &dbDataXml);
        checkError (rc, "open metadata (xml) database");

        rc = txn.mdb_dbi_open ("metadata_yaml", MDB_CREATE, &dbDataYaml);
        checkError (rc, "open metadata (yaml) database");

        rc = txn.mdb_dbi_open ("statistics", MDB_CREATE, &dbStats);
        checkError (rc, "open statistics database");
    }

    void setMetadataXml (string gcid, string xmlData)
    {
        // key.mv_size = int.sizeof;
        // key.mv_data = cast(void *)sval;
        // data.mv_size = sval.sizeof;
        // data.mv_data = cast(void *)sval;
        //
        // {
        //   import core.stdc.stdio : sprintf;
        //   sprintf(cast(char *)sval, "%03x %d foo bar", 32, 3141592);
        // }
        //
        // lmdbDo(txn.mdb_put(dbi, &key, &data, 0), "mdb_put");
        // lmdbDo(txn.mdb_txn_commit(), "mdb_txn_commit");
        //
        // lmdbDo(env.mdb_txn_begin(null, MDB_RDONLY, &txn), "mdb_txn_begin");
        //
        // lmdbDo(txn.mdb_cursor_open(dbi, &cursor), "mdb_cursor_open");
        // scope(exit) cursor.mdb_cursor_close();
        //
        // while ((rc = cursor.mdb_cursor_get(&key, &data, MDB_NEXT)) == 0) {
        //   import core.stdc.stdio : printf;
        //   printf("key: %p %.*s, data: %p %.*s\n",
        //     key.mv_data,  cast(int) key.mv_size,  cast(char *) key.mv_data,
        //     data.mv_data, cast(int) data.mv_size, cast(char *) data.mv_data);
        // }
    }
}
