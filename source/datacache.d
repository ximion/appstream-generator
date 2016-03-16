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
import appstream.Metadata;
import appstream.Component;

import ag.logging;
import ag.config : DataType;
import ag.result;


class DataCache
{

private:
    MDB_envp dbEnv;
    MDB_dbi dbDataXml;
    MDB_dbi dbDataYaml;
    MDB_dbi dbPackages;
    MDB_dbi dbHints;
    MDB_dbi dbStats;

    bool opened;

    Metadata mdata;

public:

    this ()
    {
        opened = false;
        mdata = new Metadata ();
        mdata.setLocale ("ALL");
        mdata.setWriteHeader(false);
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

    private void printVersionDbg ()
    {
        import std.stdio : writeln;
        int major, minor, patch;
        auto ver = mdb_version (&major, &minor, &patch);
        debugmsg ("Using %s major=%s minor=%s patch=%s", ver.fromStringz, major, minor, patch);
    }

    void open (string dir)
    {
        int rc;
        assert (opened == false);

        // add LMDB version we are using to the debug output
        printVersionDbg ();

        // ensure the cache directory exists
        mkdirRecurse (dir);

        rc = mdb_env_create (&dbEnv);
        scope (success) opened = true;
        scope (failure) dbEnv.mdb_env_close ();
        checkError (rc, "mdb_env_create");

        // We are going to use at max 5 sub-databases:
        // packages, hints, metadata_xml, metadata_yaml, statistics
        rc = dbEnv.mdb_env_set_maxdbs (5);
        checkError (rc, "mdb_env_set_maxdbs");

        // open database
        rc = dbEnv.mdb_env_open (dir.toStringz (), MDB_NOMETASYNC, std.conv.octal!755);
        checkError (rc, "mdb_env_open");

        // set a huge map size to be futureproof.
        // This means we're cruel to non-64bit users, but this
        // software is supposed to be run on 64bit machines anyway.
        auto mapsize = cast (size_t) std.math.pow (1024, 4);
        rc = dbEnv.mdb_env_set_mapsize (mapsize);
        checkError (rc, "mdb_env_set_mapsize");

        // open sub-databases in the environment
        MDB_txnp txn;
        rc = dbEnv.mdb_txn_begin (null, 0, &txn);
        checkError (rc, "mdb_txn_begin");
        scope (failure) txn.mdb_txn_abort ();

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

    private void putKeyValue (MDB_dbi dbi, string key, string value)
    {
        MDB_val dbkey, dbvalue;

        dbkey = makeDbValue (key);
        dbvalue = makeDbValue (value);

        auto txn = newTransaction ();
        scope (success) commitTransaction (txn);
        scope (failure) quitTransaction (txn);

        auto res = txn.mdb_put (dbi, &dbkey, &dbvalue, 0);
        checkError (res, "mdb_put");
    }

    private string getValue (MDB_dbi dbi, string key)
    {
        import std.algorithm : copy;
        import std.conv;
        MDB_val dkey, dval;
        MDB_cursorp cur;

        dkey = makeDbValue (key);

        auto txn = newTransaction (MDB_RDONLY);
        scope (exit) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbi, &cur);
        scope (exit) cur.mdb_cursor_close ();
        checkError (res, "mdb_cursor_open");

        res = cur.mdb_cursor_get (&dkey, &dval, MDB_SET);
        if (res == MDB_NOTFOUND)
            return null;
        checkError (res, "mdb_cursor_get");

        auto data = fromStringz (cast(char*) dval.mv_data);
        return to!string (data);
    }

    bool metadataExists (DataType dtype, string gcid)
    {
        return getMetadata (dtype, gcid) !is null;
    }

    void setMetadata (DataType dtype, string gcid, string asdata)
    {
        if (dtype == DataType.XML)
            putKeyValue (dbDataXml, gcid, asdata);
        else
            putKeyValue (dbDataYaml, gcid, asdata);
    }

    string getMetadata (DataType dtype, string gcid)
    {
        string data;
        if (dtype == DataType.XML)
            data = getValue (dbDataXml, gcid);
        else
            data = getValue (dbDataYaml, gcid);
        return data;
    }

    bool hasHints (string pkid)
    {
        return getValue (dbHints, pkid) !is null;
    }

    void setHints (string pkid, string hintsYaml)
    {
        putKeyValue (dbHints, pkid, hintsYaml);
    }

    string getHints (string pkid)
    {
        return getValue (dbHints, pkid);
    }

    string getPackageValue (string pkid)
    {
        return getValue (dbPackages, pkid);
    }

    void setPackageIgnore (string pkid)
    {
        putKeyValue (dbPackages, pkid, "ignore");
    }

    bool isIgnored (string pkid)
    {
        auto val = getValue (dbPackages, pkid);
        return val == "ignore";
    }

    bool packageExists (string pkid)
    {
        auto val = getValue (dbPackages, pkid);
        return val !is null;
    }

    void addGeneratorResult (DataType dtype, GeneratorResult res)
    {
        // if the package has no components,
        // mark it as always-ignore
        if (res.componentsCount () == 0) {
            setPackageIgnore (res.pkid);
            return;
        }

        foreach (Component cpt; res.getComponents ()) {
            mdata.clearComponents ();
            mdata.addComponent (cpt);

            // convert out compoent into metadata
            string data;
            if (dtype == DataType.XML) {
                data = mdata.componentsToDistroXml ();
            } else {
                data = mdata.componentsToDistroYaml ();
            }
            // remove trailing whitespaces and linebreaks
            data = data.stripRight ();

            // store metadata
            if (!empty (data))
                setMetadata (dtype, res.gcidForComponent (cpt), data);
        }

        if (res.hintsCount () > 0) {
            auto hintsYml = res.hintsToYaml ();
            if (!hintsYml.empty)
                setHints (res.pkid, hintsYml);
        }

        auto gcids = res.getGCIDs ();
        if (gcids.empty) {
            // no global components, and we're not ignoring this component.
            // this means we likely have hints stored for this one. Mark it
            // as "seen" so we don't reprocess it again.
            putKeyValue (dbPackages, res.pkid, "seen");
        } else {
            import std.array : join;
            // store global component IDs for this package as newline-separated list
            auto gcidVal = join (gcids, "\n");

            putKeyValue (dbPackages, res.pkid, gcidVal);
        }
    }

    string[] getMetadataForPackage (DataType dtype, string pkid)
    {
        auto pkval = getPackageValue (pkid);
        if (pkval == "ignore")
            return null;
        if (pkval == "seen")
            return null;

        string[] res;
        auto cids = pkval.split ("\n");
        foreach (cid; cids) {
            if (cid.empty)
                continue;

            auto data = getMetadata (dtype, cid);
            if (!data.empty)
                res ~= data;
        }

        return res;
    }

}
