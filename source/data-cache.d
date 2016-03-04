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
import lmdb;


class DataCache
{

private:
    MDB_envp env;
    MDB_dbi dbDataXML;
    MDB_dbi dbDataYAML;
    MDB_dbi dbPackages;
    MDB_dbi dbStats;

public:

    this ()
    {
        writeln ("HELLO THERE!");
    }

    ~this ()
    {
        if (env)
            env.mdb_env_close();
    }

    private void checkError (int rc, string msg)
    {
        if (rc) {
            import std.string;
            import std.format;
            throw new Exception (format ("%s: %s [%i]", msg, mdb_strerror(rc).fromStringz, rc));
        }
    }

    private void printVersionDbg ()
    {
        import std.stdio : writeln;
        import std.string : fromStringz;
        int major, minor, patch;
        auto ver = mdb_version(&major, &minor, &patch);
        writeln("ver=", ver.fromStringz, "; major=", major, "; minor=", minor, "; patch=", patch);
    }

    void open (string dir)
    {
        int rc;

        // add LMDB version we are using to the debug output
        printVersionDbg ();

        rc = mdb_env_create(&env);
        checkError (rc, "mdb_env_create");

  //
  //       collectException(mkdir("testdb"));
  // lmdbDo(env.mdb_env_open("./testdb", 0, 0o664), "mdb_env_open");
  //
  // lmdbDo(env.mdb_txn_begin(null, 0, &txn), "mdb_txn_begin");
  // scope(exit) txn.mdb_txn_abort();
  //
  // lmdbDo(txn.mdb_dbi_open(null, 0, &dbi), "mdb_dbi_open");
  // scope(exit) env.mdb_dbi_close(dbi);
  //
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
