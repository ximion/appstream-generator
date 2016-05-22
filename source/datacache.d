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
import std.conv : to;
import std.file : mkdirRecurse;
import std.json;

import c.lmdb;
import appstream.Metadata;
import appstream.Component;

import ag.config;
import ag.logging;
import ag.config : DataType;
import ag.result;


/**
 * Main database containing information about scanned packages,
 * the components they provide, the component metadata itself,
 * issues found as well as statistics about the metadata evolution
 * over time.
 **/
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

    string mediaDir;

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

    @property
    string mediaExportDir ()
    {
        return mediaDir;
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
        logDebug ("Using %s major=%s minor=%s patch=%s", ver.fromStringz, major, minor, patch);
    }

    void open (string dir, string mediaDir)
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

        // set a huge map size to be futureproof.
        // This means we're cruel to non-64bit users, but this
        // software is supposed to be run on 64bit machines anyway.
        auto mapsize = cast (size_t) std.math.pow (512L, 4);
        rc = dbEnv.mdb_env_set_mapsize (mapsize);
        checkError (rc, "mdb_env_set_mapsize");

        // open database
        rc = dbEnv.mdb_env_open (dir.toStringz (), MDB_NOMETASYNC, std.conv.octal!755);
        checkError (rc, "mdb_env_open");

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

        rc = txn.mdb_dbi_open ("statistics", MDB_CREATE | MDB_INTEGERKEY, &dbStats);
        checkError (rc, "open statistics database");

        rc = txn.mdb_txn_commit ();
        checkError (rc, "mdb_txn_commit");

        this.mediaDir = mediaDir;
        mkdirRecurse (mediaDir);
    }

    void open (Config conf)
    {
        import std.path : buildPath;
        this.open (buildPath (conf.workspaceDir, "cache", "main"), buildPath (conf.workspaceDir, "export", "media"));
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

    private string getValue (MDB_dbi dbi, MDB_val dkey)
    {
        import std.conv;
        MDB_val dval;
        MDB_cursorp cur;

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

    private string getValue (MDB_dbi dbi, string key)
    {
        MDB_val dkey;
        dkey = makeDbValue (key);

        return getValue (dbi, dkey);
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

    void addGeneratorResult (DataType dtype, GeneratorResult gres)
    {
        // if the package has no components or hints,
        // mark it as always-ignore
        if (gres.packageIsIgnored ()) {
            setPackageIgnore (gres.pkid);
            return;
        }

        foreach (ref cpt; gres.getComponents ()) {
            auto gcid = gres.gcidForComponent (cpt);
            if (metadataExists (dtype, gcid)) {
                // we already have seen this exact metadata - only adjust the reference,
                // and don't regenerate it.
                continue;
            }

            mdata.clearComponents ();
            mdata.addComponent (cpt);

            // convert out compoent into metadata
            string data;
            try {
                if (dtype == DataType.XML) {
                    data = mdata.componentsToDistroXml ();
                } else {
                    data = mdata.componentsToDistroYaml ();
                }
            } catch (Exception e) {
                gres.addHint (cpt.getId (), "metadata-serialization-failed", e.msg);
                continue;
            }
            // remove trailing whitespaces and linebreaks
            data = data.stripRight ();

            // store metadata
            if (!empty (data))
                setMetadata (dtype, gcid, data);
        }

        if (gres.hintsCount () > 0) {
            auto hintsJson = gres.hintsToJson ();
            if (!hintsJson.empty)
                setHints (gres.pkid, hintsJson);
        }

        auto gcids = gres.getGCIDs ();
        if (gcids.empty) {
            // no global components, and we're not ignoring this component.
            // this means we likely have hints stored for this one. Mark it
            // as "seen" so we don't reprocess it again.
            putKeyValue (dbPackages, gres.pkid, "seen");
        } else {
            import std.array : join;
            // store global component IDs for this package as newline-separated list
            auto gcidVal = join (gcids, "\n");

            putKeyValue (dbPackages, gres.pkid, gcidVal);
        }
    }

    string[] getGCIDsForPackage (string pkid)
    {
        auto pkval = getPackageValue (pkid);
        if (pkval == "ignore")
            return null;
        if (pkval == "seen")
            return null;

        string[] validCids;
        auto cids = pkval.split ("\n");
        foreach (cid; cids) {
            if (cid.empty)
                continue;
            validCids ~= cid;
        }

        return validCids;
    }

    string[] getMetadataForPackage (DataType dtype, string pkid)
    {
        auto gcids = getGCIDsForPackage (pkid);
        if (gcids is null)
            return null;

        string[] res;
        foreach (cid; gcids) {
            auto data = getMetadata (dtype, cid);
            if (!data.empty)
                res ~= data;
        }

        return res;
    }

    /**
     * Drop a package from the database. This process might leave cruft behind,
     * which can be collected using the cleanupCruft() method.
     */
    void removePackage (string pkid)
    {
        MDB_val dbkey;

        dbkey = makeDbValue (pkid);

        auto txn = newTransaction ();
        scope (success) commitTransaction (txn);
        scope (failure) quitTransaction (txn);

        auto res = txn.mdb_del (dbPackages, &dbkey, null);
        if (res != MDB_NOTFOUND)
            checkError (res, "mdb_del");

        res = txn.mdb_del (dbHints, &dbkey, null);
        if (res != MDB_NOTFOUND)
            checkError (res, "mdb_del");
    }

    private auto getActiveGCIDs ()
    {
        MDB_val dkey, dval;
        MDB_cursorp cur;
        string[long] stats;

        auto txn = newTransaction (MDB_RDONLY);
        scope (exit) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbPackages, &cur);
        scope (exit) cur.mdb_cursor_close ();
        checkError (res, "mdb_cursor_open (gcids)");

        bool[string] gcids;
        while (cur.mdb_cursor_get (&dkey, &dval, MDB_NEXT) == 0) {
            auto pkval = std.conv.to!string (fromStringz (cast(char*) dval.mv_data));
            if ((pkval == "ignore") || (pkval == "seen"))
                continue;

            foreach (gcid; pkval.split ("\n"))
                gcids[gcid] = true;
        }

        return gcids;
    }

    void cleanupCruft ()
    {
        import std.file;
        import std.path;

        if (mediaDir is null) {
            logError ("Can not clean up cruft: No media directory is set.");
            return;
        }

        auto activeGCIDs = getActiveGCIDs ();
        bool gcidReferenced (string gcid)
        {
            // we use an associative array as a set here
            return (gcid in activeGCIDs) !is null;
        }

        void dropOrphanedData (MDB_dbi dbi)
        {
            MDB_cursorp cur;

            auto txn = newTransaction ();
            scope (success) commitTransaction (txn);
            scope (failure) quitTransaction (txn);

            auto res = txn.mdb_cursor_open (dbi, &cur);
            scope (exit) cur.mdb_cursor_close ();
            checkError (res, "mdb_cursor_open (stats)");

            MDB_val ckey;
            while (cur.mdb_cursor_get (&ckey, null, MDB_NEXT) == 0) {
                auto gcid = std.conv.to!string (fromStringz (cast(char*) ckey.mv_data));
                if (gcidReferenced (gcid))
                    continue;

                // if we got here, the component is cruft and can be removed
                res = cur.mdb_cursor_del (0);
                checkError (res, "mdb_del");
                logInfo ("Marked %s as cruft.", gcid);
            }
        }

        // drop orphaned metadata
        dropOrphanedData (dbDataXml);
        dropOrphanedData (dbDataYaml);

        bool dirEmpty (string dir)
        {
            bool empty = true;
            foreach (e; dirEntries (dir, SpanMode.shallow, false)) {
                empty = false;
                break;
            }
            return empty;
        }

        auto mdirLen = mediaDir.length;
        foreach (path; dirEntries (mediaDir, SpanMode.depth, false)) {
            if (path.length <= mdirLen)
                continue;
            auto relPath = path[mdirLen+1..$];
            auto split = std.array.array (pathSplitter (relPath));
            if (split.length != 4)
                continue;
            auto gcid = relPath;

            if (gcidReferenced (gcid))
                continue;

            // if we are here, the component is removed and we can drop its media
            if (std.file.exists (path))
                rmdirRecurse (path);

            // remove possibly empty directories
            auto pdir = buildNormalizedPath (path, "..");
            if (dirEmpty (pdir))
                rmdir (pdir);
            pdir = buildNormalizedPath (pdir, "..");
            if (dirEmpty (pdir))
                rmdir (pdir);

            logInfo ("Expired media for '%s'", gcid);
        }

    }

    void removePackagesNotInSet (bool[string] pkgSet)
    {
        MDB_cursorp cur;

        auto txn = newTransaction ();
        scope (success) commitTransaction (txn);
        scope (failure) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbPackages, &cur);
        scope (exit) cur.mdb_cursor_close ();
        checkError (res, "mdb_cursor_open (pkgcruft)");

        MDB_val pkey;
        while (cur.mdb_cursor_get (&pkey, null, MDB_NEXT) == 0) {
            auto pkid = std.conv.to!string (fromStringz (cast(char*) pkey.mv_data));
            if (pkid in pkgSet)
                continue;

            // if we got here, the package is not in the set of valid packages,
            // and we can remove it.
            res = cur.mdb_cursor_del (0);
            checkError (res, "mdb_del");
            logInfo ("Dropped package %s", pkid);
        }
    }

    void addStatistics (JSONValue stats)
    {
        MDB_val dbkey, dbvalue;
        size_t unixTime = core.stdc.time.time (null);

        auto statsJsonStr = toJSON (&stats);

        dbkey.mv_size = size_t.sizeof;
        dbkey.mv_data = &unixTime;
        dbvalue = makeDbValue (statsJsonStr);

        auto txn = newTransaction ();
        scope (success) commitTransaction (txn);
        scope (failure) quitTransaction (txn);

        auto res = txn.mdb_put (dbStats, &dbkey, &dbvalue, MDB_APPEND);
        if (res == MDB_KEYEXIST) {
            // we were too fast! - add the new data to this point in time
            logDebug ("Attempted to add statistics at the exact same time when we have already added some. We are suspiciously fast...");

            // retrieve the old statistics data
            auto existingJsonData = getValue (dbStats, dbkey);
            auto existingJson = parseJSON (existingJsonData);

            // make the new JSON a list of the old and the new data, if it isn't one already
            JSONValue newJson;
            if (existingJson.type == JSON_TYPE.ARRAY) {
                newJson = existingJson;
                newJson.array ~= stats;
            } else {
                newJson = JSONValue ([existingJson, stats]);
            }

            // build new database value and add it to the db, overriding the old one
            statsJsonStr = toJSON (&newJson);
            dbvalue = makeDbValue (statsJsonStr);

            res = txn.mdb_put (dbStats, &dbkey, &dbvalue, 0);
        }
        checkError (res, "mdb_put (stats)");
    }

    string[long] getStatistics ()
    {
        MDB_val dkey, dval;
        MDB_cursorp cur;
        string[long] stats;

        auto txn = newTransaction (MDB_RDONLY);
        scope (exit) quitTransaction (txn);

        auto res = txn.mdb_cursor_open (dbStats, &cur);
        scope (exit) cur.mdb_cursor_close ();
        checkError (res, "mdb_cursor_open (stats)");

        while (cur.mdb_cursor_get (&dkey, &dval, MDB_NEXT) == 0) {
            auto jsonData = std.conv.to!string (fromStringz (cast(char*) dval.mv_data));
            stats[*(cast(size_t*) dkey.mv_data)] = jsonData;
        }

        return stats;
    }

}
