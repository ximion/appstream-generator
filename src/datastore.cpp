/*
 * Copyright (C) 2016-2026 Matthias Klumpp <matthias@tenstral.net>
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

#include "datastore.h"

#include <variant>
#include <stdexcept>
#include <format>
#include <filesystem>
#include <fstream>
#include <cstring>
#include <cmath>
#include <ctime>
#include <algorithm>
#include <nlohmann/json.hpp>

#include "logging.h"
#include "result.h"
#include "utils.h"

namespace ASGenerator
{

using json = nlohmann::json;

std::vector<std::byte> RepoInfo::serialize() const
{
    json payload = json::object();
    for (const auto &[key, value] : data) {
        std::visit(
            [&payload, &key](const auto &v) {
                payload[key] = v;
            },
            value);
    }

    const auto serialized = payload.dump();
    return {
        reinterpret_cast<const std::byte *>(serialized.data()),
        reinterpret_cast<const std::byte *>(serialized.data()) + serialized.size()};
}

RepoInfo RepoInfo::deserialize(const std::vector<std::byte> &data)
{
    if (data.empty())
        return {};

    const std::string payload(reinterpret_cast<const char *>(data.data()), data.size());
    const auto j = json::parse(payload);
    if (!j.is_object())
        throw std::runtime_error("Invalid repository info data: expected JSON object");

    RepoInfo info;
    for (auto it = j.begin(); it != j.end(); ++it) {
        const auto &value = it.value();
        if (value.is_string()) {
            info.data[it.key()] = value.get<std::string>();
        } else if (value.is_number_integer()) {
            info.data[it.key()] = value.get<std::int64_t>();
        } else if (value.is_number_float()) {
            info.data[it.key()] = value.get<double>();
        } else {
            throw std::runtime_error(
                std::format(
                    "Invalid repository info value type for '{}': only string/int64/double are supported", it.key()));
        }
    }

    return info;
}

static std::vector<std::byte> serializeStatsEntryData(const StatisticsEntry &entry)
{
    json statsData = json::object();
    for (const auto &[key, value] : entry.data) {
        std::visit(
            [&statsData, &key](const auto &v) {
                statsData[key] = v;
            },
            value);
    }

    const auto serialized = statsData.dump();
    return {
        reinterpret_cast<const std::byte *>(serialized.data()),
        reinterpret_cast<const std::byte *>(serialized.data()) + serialized.size()};
}

static StatisticsEntry deserializeStatsEntry(std::time_t timestamp, const std::vector<std::byte> &data)
{
    if (data.empty())
        throw std::runtime_error("Invalid statistics data: buffer is empty");

    StatisticsEntry entry;
    entry.time = timestamp;

    const std::string payload(reinterpret_cast<const char *>(data.data()), data.size());
    const auto j = json::parse(payload);
    if (!j.is_object())
        throw std::runtime_error("Invalid statistics data: expected JSON object");

    for (auto it = j.begin(); it != j.end(); ++it) {
        const auto &value = it.value();
        if (value.is_string()) {
            entry.data[it.key()] = value.get<std::string>();
        } else if (value.is_number_integer()) {
            entry.data[it.key()] = value.get<std::int64_t>();
        } else if (value.is_number_float()) {
            entry.data[it.key()] = value.get<double>();
        } else {
            throw std::runtime_error(
                std::format(
                    "Invalid statistics value type for '{}': only string/int64/double are supported", it.key()));
        }
    }

    return entry;
}

DataStore::DataStore()
    : m_dbEnv(nullptr),
      m_dbRepoInfo(0),
      m_dbPackages(0),
      m_dbDataXml(0),
      m_dbDataYaml(0),
      m_dbHints(0),
      m_dbStats(0),
      m_opened(false),
      m_mdata(nullptr)
{
    m_mdata = as_metadata_new();
    as_metadata_set_locale(m_mdata, "ALL");
    as_metadata_set_format_version(m_mdata, Config::get().formatVersion);
    as_metadata_set_write_header(m_mdata, FALSE);
}

DataStore::~DataStore()
{
    close();
    g_object_unref(m_mdata);
}

const fs::path &DataStore::mediaExportPoolDir() const
{
    return m_mediaDir;
}

void DataStore::checkError(int rc, const std::string &msg)
{
    if (rc != 0) {
        throw std::runtime_error(std::format("{}[{}]: {}", msg, rc, mdb_strerror(rc)));
    }
}

void DataStore::printVersionDbg()
{
    int major, minor, patch;
    const char *ver = mdb_version(&major, &minor, &patch);
    logDebug("Using {} major={} minor={} patch={}", ver, major, minor, patch);
}

void DataStore::open(const std::string &dir, const fs::path &mediaBaseDir)
{
    std::lock_guard<std::mutex> lock(m_mutex);

    if (m_opened)
        throw std::runtime_error("DataStore is already opened");

    int rc;

    // add LMDB version we are using to the debug output
    printVersionDbg();

    // ensure the cache directory exists
    fs::create_directories(dir);

    rc = mdb_env_create(&m_dbEnv);
    if (rc != 0)
        checkError(rc, "mdb_env_create");

    // We are going to use at max 6 sub-databases:
    // packages, hints, metadata_xml, metadata_yaml, statistics, repository
    rc = mdb_env_set_maxdbs(m_dbEnv, 6);
    if (rc != 0) {
        mdb_env_close(m_dbEnv);
        checkError(rc, "mdb_env_set_maxdbs");
    }

    // set a huge map size to be futureproof.
    // This means we're cruel to non-64bit users, but this
    // software is supposed to be run on 64bit machines anyway.
    auto mapsize = static_cast<size_t>(std::pow(512L, 4));
    rc = mdb_env_set_mapsize(m_dbEnv, mapsize);
    if (rc != 0) {
        mdb_env_close(m_dbEnv);
        checkError(rc, "mdb_env_set_mapsize");
    }

    // open database
    rc = mdb_env_open(m_dbEnv, dir.c_str(), MDB_NOMETASYNC, 0755);
    if (rc != 0) {
        mdb_env_close(m_dbEnv);
        checkError(rc, "mdb_env_open");
    }

    // open sub-databases in the environment
    MDB_txn *txn;
    rc = mdb_txn_begin(m_dbEnv, nullptr, 0, &txn);
    if (rc != 0) {
        mdb_env_close(m_dbEnv);
        checkError(rc, "mdb_txn_begin");
    }

    try {
        rc = mdb_dbi_open(txn, "packages", MDB_CREATE, &m_dbPackages);
        checkError(rc, "open packages database");

        rc = mdb_dbi_open(txn, "repository", MDB_CREATE, &m_dbRepoInfo);
        checkError(rc, "open repository database");

        rc = mdb_dbi_open(txn, "metadata_xml", MDB_CREATE, &m_dbDataXml);
        checkError(rc, "open metadata (xml) database");

        rc = mdb_dbi_open(txn, "metadata_yaml", MDB_CREATE, &m_dbDataYaml);
        checkError(rc, "open metadata (yaml) database");

        rc = mdb_dbi_open(txn, "hints", MDB_CREATE, &m_dbHints);
        checkError(rc, "open hints database");

        rc = mdb_dbi_open(txn, "statistics", MDB_CREATE | MDB_INTEGERKEY, &m_dbStats);
        checkError(rc, "open statistics database");

        rc = mdb_txn_commit(txn);
        checkError(rc, "mdb_txn_commit");

    } catch (...) {
        mdb_txn_abort(txn);
        mdb_env_close(m_dbEnv);
        throw;
    }

    m_opened = true;
    m_mediaDir = mediaBaseDir / "pool";
    fs::create_directories(m_mediaDir);
}

void DataStore::open(const Config &conf)
{
    open(conf.databaseDir() / "main", conf.mediaExportDir);
}

void DataStore::close()
{
    std::lock_guard<std::mutex> lock(m_mutex);

    if (m_opened) {
        mdb_env_close(m_dbEnv);
        m_opened = false;
        m_dbEnv = nullptr;
    }
}

MDB_val DataStore::makeDbValue(const std::string &data)
{
    // NOTE: We need to be careful about string lifetime
    // The caller must ensure the string remains valid while MDB_val is in use
    MDB_val mval;
    mval.mv_size = data.length() + 1; // include null terminator
    mval.mv_data = const_cast<char *>(data.c_str());

    return mval;
}

MDB_txn *DataStore::newTransaction(unsigned int flags)
{
    if (!m_opened)
        throw std::runtime_error("DataStore is not opened");

    MDB_txn *txn;
    int rc = mdb_txn_begin(m_dbEnv, nullptr, flags, &txn);
    checkError(rc, "mdb_txn_begin");

    return txn;
}

void DataStore::commitTransaction(MDB_txn *txn)
{
    int rc = mdb_txn_commit(txn);
    checkError(rc, "mdb_txn_commit");
}

void DataStore::quitTransaction(MDB_txn *txn)
{
    if (!txn)
        return;
    mdb_txn_abort(txn);
}

void DataStore::putKeyValue(MDB_dbi dbi, const std::string &key, const std::string &value)
{
    MDB_val dbkey = makeDbValue(key);
    MDB_val dbvalue = makeDbValue(value);

    MDB_txn *txn = newTransaction();
    try {
        int res = mdb_put(txn, dbi, &dbkey, &dbvalue, 0);
        checkError(res, "mdb_put");
        commitTransaction(txn);
    } catch (...) {
        quitTransaction(txn);
        throw;
    }
}

std::string DataStore::getValue(MDB_dbi dbi, MDB_val dkey)
{
    MDB_val dval;
    MDB_cursor *cur;

    MDB_txn *txn = newTransaction(MDB_RDONLY);
    try {
        int res = mdb_cursor_open(txn, dbi, &cur);
        checkError(res, "mdb_cursor_open");

        res = mdb_cursor_get(cur, &dkey, &dval, MDB_SET);
        if (res == MDB_NOTFOUND) {
            mdb_cursor_close(cur);
            quitTransaction(txn);
            return {};
        }
        checkError(res, "mdb_cursor_get");

        if (dval.mv_data == nullptr || dval.mv_size == 0) {
            mdb_cursor_close(cur);
            quitTransaction(txn);
            return {};
        }

        std::string result(static_cast<const char *>(dval.mv_data), dval.mv_size - 1); // exclude null terminator
        mdb_cursor_close(cur);
        quitTransaction(txn);
        return result;
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }
}

std::string DataStore::getValue(MDB_dbi dbi, const std::string &key)
{
    MDB_val dkey = makeDbValue(key);
    return getValue(dbi, dkey);
}

bool DataStore::metadataExists(DataType dtype, const std::string &gcid)
{
    return !getMetadata(dtype, gcid).empty();
}

void DataStore::setMetadata(DataType dtype, const std::string &gcid, const std::string &asdata)
{
    if (dtype == DataType::XML)
        putKeyValue(m_dbDataXml, gcid, asdata);
    else
        putKeyValue(m_dbDataYaml, gcid, asdata);
}

std::string DataStore::getMetadata(DataType dtype, const std::string &gcid)
{
    if (dtype == DataType::XML)
        return getValue(m_dbDataXml, gcid);
    else
        return getValue(m_dbDataYaml, gcid);
}

bool DataStore::hasHints(const std::string &pkid)
{
    return !getValue(m_dbHints, pkid).empty();
}

void DataStore::setHints(const std::string &pkid, const std::string &hintsJson)
{
    putKeyValue(m_dbHints, pkid, hintsJson);
}

std::string DataStore::getHints(const std::string &pkid)
{
    return getValue(m_dbHints, pkid);
}

std::string DataStore::getPackageValue(const std::string &pkid)
{
    return getValue(m_dbPackages, pkid);
}

void DataStore::setPackageIgnore(const std::string &pkid)
{
    putKeyValue(m_dbPackages, pkid, "ignore");
}

bool DataStore::isIgnored(const std::string &pkid)
{
    const auto val = getValue(m_dbPackages, pkid);
    return val == "ignore";
}

bool DataStore::packageExists(const std::string &pkid)
{
    return !getValue(m_dbPackages, pkid).empty();
}

void DataStore::addGeneratorResult(DataType dtype, GeneratorResult &gres, bool alwaysRegenerate)
{
    // if the package has no components or hints,
    // mark it as always-ignore
    if (gres.isUnitIgnored()) {
        setPackageIgnore(gres.pkid());
        return;
    }

    g_autoptr(GPtrArray) cptsArray = gres.fetchComponents();
    for (guint i = 0; i < cptsArray->len; i++) {
        AsComponent *cpt = AS_COMPONENT(cptsArray->pdata[i]);
        const auto gcid = gres.gcidForComponent(cpt);
        if (metadataExists(dtype, gcid) && !alwaysRegenerate) {
            // we already have seen this exact metadata - only adjust the reference,
            // and don't regenerate it.
            continue;
        }

        std::lock_guard<std::mutex> lock(m_mutex);
        as_metadata_clear_components(m_mdata);
        as_metadata_add_component(m_mdata, cpt);

        // convert our component into metadata
        std::string data;
        try {
            g_autoptr(GError) error = nullptr;
            g_autofree gchar *metadataStr = nullptr;

            if (dtype == DataType::XML)
                metadataStr = as_metadata_components_to_catalog(m_mdata, AS_FORMAT_KIND_XML, &error);
            else
                metadataStr = as_metadata_components_to_catalog(m_mdata, AS_FORMAT_KIND_YAML, &error);

            if (error != nullptr) {
                gres.addHint(cpt, "metadata-serialization-failed", error->message);
                continue;
            }

            if (metadataStr != nullptr) {
                data = metadataStr;

                // remove trailing whitespaces and linebreaks
                data = Utils::rtrimString(data);
            }
        } catch (const std::exception &e) {
            gres.addHint(cpt, "metadata-serialization-failed", e.what());
            continue;
        }

        // store metadata
        if (!data.empty())
            setMetadata(dtype, gcid, data);
    }

    if (gres.hintsCount() > 0) {
        const auto hintsJson = gres.hintsToJson();
        if (!hintsJson.empty())
            setHints(gres.pkid(), hintsJson);
    }

    const auto gcids = gres.getComponentGcids();
    if (gcids.empty()) {
        // no global components, and we're not ignoring this component.
        // this means we likely have hints stored for this one. Mark it
        // as "seen" so we don't reprocess it again.
        putKeyValue(m_dbPackages, gres.pkid(), "seen");
    } else {
        // store global component IDs for this package as newline-separated list
        std::string gcidVal = Utils::joinStrings(gcids, "\n");
        putKeyValue(m_dbPackages, gres.pkid(), gcidVal);
    }
}

std::vector<std::string> DataStore::getGCIDsForPackage(const std::string &pkid)
{
    const auto pkval = getPackageValue(pkid);
    if (pkval == "ignore" || pkval == "seen") {
        return {};
    }

    std::vector<std::string> validCids;
    const auto cids = Utils::splitString(pkval, '\n');
    for (const auto &cid : cids) {
        if (!cid.empty())
            validCids.push_back(cid);
    }

    return validCids;
}

std::vector<std::string> DataStore::getMetadataForPackage(DataType dtype, const std::string &pkid)
{
    const auto gcids = getGCIDsForPackage(pkid);
    if (gcids.empty())
        return {};

    std::vector<std::string> result;
    result.reserve(gcids.size());
    for (const auto &cid : gcids) {
        const auto data = getMetadata(dtype, cid);
        if (!data.empty())
            result.push_back(data);
    }

    return result;
}

void DataStore::removePackage(const std::string &pkid)
{
    MDB_val dbkey = makeDbValue(pkid);

    MDB_txn *txn = newTransaction();
    try {
        int res = mdb_del(txn, m_dbPackages, &dbkey, nullptr);
        if (res != MDB_NOTFOUND) {
            checkError(res, "mdb_del");
        }

        res = mdb_del(txn, m_dbHints, &dbkey, nullptr);
        if (res != MDB_NOTFOUND) {
            checkError(res, "mdb_del");
        }

        commitTransaction(txn);
    } catch (...) {
        quitTransaction(txn);
        throw;
    }
}

std::unordered_set<std::string> DataStore::getActiveGCIDs()
{
    MDB_val dkey, dval;
    MDB_cursor *cur = nullptr;

    MDB_txn *txn = newTransaction(MDB_RDONLY);
    try {
        int res = mdb_cursor_open(txn, m_dbPackages, &cur);
        checkError(res, "mdb_cursor_open (gcids)");

        std::unordered_set<std::string> gcids;
        while (mdb_cursor_get(cur, &dkey, &dval, MDB_NEXT) == 0) {
            const std::string pkval(static_cast<const char *>(dval.mv_data), dval.mv_size - 1);
            if (pkval == "ignore" || pkval == "seen")
                continue;

            const auto gcidList = Utils::splitString(pkval, '\n');
            for (const auto &gcid : gcidList) {
                if (!gcid.empty())
                    gcids.insert(gcid);
            }
        }

        mdb_cursor_close(cur);
        quitTransaction(txn);
        return gcids;
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }
}

std::unordered_map<std::string, std::vector<std::string>> DataStore::getPackagesForGCIDs(
    std::unordered_set<std::string> gcids)
{
    MDB_val dkey, dval;
    MDB_cursor *cur = nullptr;

    std::unordered_map<std::string, std::vector<std::string>> result;
    MDB_txn *txn = newTransaction(MDB_RDONLY);
    try {
        int res = mdb_cursor_open(txn, m_dbPackages, &cur);
        checkError(res, "mdb_cursor_open (gcids)");

        while (mdb_cursor_get(cur, &dkey, &dval, MDB_NEXT) == 0) {
            const std::string pkval(static_cast<const char *>(dval.mv_data), dval.mv_size - 1);
            if (pkval == "ignore" || pkval == "seen")
                continue;

            const std::string pkid(static_cast<const char *>(dkey.mv_data), dkey.mv_size - 1);
            const auto gcidList = Utils::splitString(pkval, '\n');
            for (const auto &gcid : gcidList) {
                if (gcids.contains(gcid)) {
                    if (result.contains(pkid))
                        result[pkid].push_back(gcid);
                    else
                        result[pkid] = {gcid};
                }
            }
        }

        mdb_cursor_close(cur);
        quitTransaction(txn);
        return result;
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }
}

void DataStore::dropOrphanedData(MDB_dbi dbi, const std::unordered_set<std::string> &activeGCIDs)
{
    MDB_cursor *cur = nullptr;

    MDB_txn *txn = newTransaction();
    try {
        int res = mdb_cursor_open(txn, dbi, &cur);
        checkError(res, "mdb_cursor_open (stats)");

        MDB_val ckey;
        while (mdb_cursor_get(cur, &ckey, nullptr, MDB_NEXT) == 0) {
            const std::string gcid(static_cast<const char *>(ckey.mv_data), ckey.mv_size - 1);
            if (activeGCIDs.contains(gcid)) {
                continue;
            }

            // if we got here, the component is cruft and can be removed
            res = mdb_cursor_del(cur, 0);
            checkError(res, "mdb_del");
            logInfo("Marked {} as cruft.", gcid);
        }

        mdb_cursor_close(cur);
        commitTransaction(txn);
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }
}

void DataStore::cleanupDirs(const std::string &rootPath)
{
    auto pdir = fs::path(rootPath).parent_path();
    if (!fs::exists(pdir))
        return;

    if (Utils::dirEmpty(pdir))
        fs::remove(pdir);

    pdir = pdir.parent_path();
    if (Utils::dirEmpty(pdir))
        fs::remove(pdir);
}

void DataStore::cleanupCruft()
{
    if (m_mediaDir.empty()) {
        logError("Can not clean up cruft: No media directory is set.");
        return;
    }

    const auto activeGCIDs = getActiveGCIDs();

    // drop orphaned metadata
    dropOrphanedData(m_dbDataXml, activeGCIDs);
    dropOrphanedData(m_dbDataYaml, activeGCIDs);

    // we need the global Config instance here
    const auto &conf = Config::get();

    const auto mdirLen = m_mediaDir.string().length();
    if (!fs::exists(m_mediaDir)) {
        logInfo("Media directory '{}' does not exist.", m_mediaDir.string());
        return;
    }

    // Collect all directory paths first to avoid modifying filesystem while iterating
    std::vector<fs::path> dirsToProcess;
    try {
        for (const auto &entry :
             fs::recursive_directory_iterator(m_mediaDir, fs::directory_options::skip_permission_denied)) {
            if (!entry.is_directory())
                continue;

            const auto &path = entry.path();
            if (path.string().length() <= mdirLen)
                continue;

            const std::string relPath = path.string().substr(mdirLen + 1);
            const auto pathParts = Utils::splitString(relPath, '/');
            if (pathParts.size() != 4)
                continue;

            dirsToProcess.push_back(path);
        }
    } catch (const fs::filesystem_error &e) {
        logWarning("Error while scanning media directory: {}", e.what());
        return;
    }

    // Now process the collected directories
    for (const auto &path : dirsToProcess) {
        const std::string relPath = path.string().substr(mdirLen + 1);
        const std::string &gcid = relPath;

        if (activeGCIDs.contains(gcid))
            continue;

        // if we are here, the component is removed and we can drop its media
        if (fs::exists(path))
            fs::remove_all(path);

        // remove possibly empty directories
        cleanupDirs(path);

        // expire data in suite-specific media directories,
        // if suite is not marked as immutable
        if (conf.feature.immutableSuites) {
            for (const auto &suite : conf.suites) {
                if (suite.isImmutable)
                    continue;

                const auto suiteGCIDMediaDir = m_mediaDir.parent_path() / suite.name / gcid;

                if (fs::exists(suiteGCIDMediaDir))
                    fs::remove_all(suiteGCIDMediaDir);

                // remove possibly empty directories
                cleanupDirs(suiteGCIDMediaDir);
            }
        }

        logInfo("Expired media for '{}'", gcid);
    }
}

std::unordered_set<std::string> DataStore::getPackageIdSet()
{
    MDB_cursor *cur = nullptr;

    MDB_txn *txn = newTransaction();
    try {
        std::unordered_set<std::string> pkgSet;

        int res = mdb_cursor_open(txn, m_dbPackages, &cur);
        checkError(res, "mdb_cursor_open (getPackageIdSet)");

        MDB_val pkey;
        while (mdb_cursor_get(cur, &pkey, nullptr, MDB_NEXT) == 0) {
            const std::string pkid(static_cast<const char *>(pkey.mv_data), pkey.mv_size - 1);
            pkgSet.insert(pkid);
        }

        mdb_cursor_close(cur);
        quitTransaction(txn);

        return pkgSet;
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }
}

void DataStore::removePackages(const std::unordered_set<std::string> &pkidSet)
{
    MDB_txn *txn = newTransaction();
    try {
        for (const auto &pkid : pkidSet) {
            MDB_val dbkey = makeDbValue(pkid);
            int res = mdb_del(txn, m_dbPackages, &dbkey, nullptr);
            if (res != MDB_NOTFOUND)
                checkError(res, "mdb_del (metadata)");

            res = mdb_del(txn, m_dbHints, &dbkey, nullptr);
            if (res != MDB_NOTFOUND)
                checkError(res, "mdb_del (hints)");

            logInfo("Dropped package {}", pkid);
        }

        commitTransaction(txn);
    } catch (...) {
        quitTransaction(txn);
        throw;
    }
}

void DataStore::putBinaryValue(MDB_dbi dbi, const std::string &key, const std::vector<std::byte> &value)
{
    MDB_val dbkey = makeDbValue(key);
    MDB_val dbvalue;
    dbvalue.mv_size = value.size();
    dbvalue.mv_data = const_cast<std::byte *>(value.data());

    MDB_txn *txn = newTransaction();
    try {
        int res = mdb_put(txn, dbi, &dbkey, &dbvalue, 0);
        checkError(res, "mdb_put");
        commitTransaction(txn);
    } catch (...) {
        quitTransaction(txn);
        throw;
    }
}

std::vector<std::byte> DataStore::getBinaryValue(MDB_dbi dbi, const std::string &key)
{
    MDB_val dbkey = makeDbValue(key);
    MDB_val dval;
    MDB_cursor *cur = nullptr;

    MDB_txn *txn = newTransaction(MDB_RDONLY);
    try {
        int res = mdb_cursor_open(txn, dbi, &cur);
        checkError(res, "mdb_cursor_open");

        res = mdb_cursor_get(cur, &dbkey, &dval, MDB_SET);
        if (res == MDB_NOTFOUND) {
            mdb_cursor_close(cur);
            quitTransaction(txn);

            return {};
        }
        checkError(res, "mdb_cursor_get");

        std::vector<std::byte> result(
            static_cast<const std::byte *>(dval.mv_data), static_cast<const std::byte *>(dval.mv_data) + dval.mv_size);
        mdb_cursor_close(cur);
        quitTransaction(txn);

        return result;
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }
}

std::vector<StatisticsEntry> DataStore::getStatistics()
{
    MDB_val dkey, dval;
    MDB_cursor *cur = nullptr;

    MDB_txn *txn = newTransaction(MDB_RDONLY);
    try {
        int res = mdb_cursor_open(txn, m_dbStats, &cur);
        checkError(res, "mdb_cursor_open (stats)");

        std::vector<StatisticsEntry> stats;
        stats.reserve(256);
        while (mdb_cursor_get(cur, &dkey, &dval, MDB_NEXT) == 0) {
            if (dkey.mv_size != sizeof(std::int64_t)) {
                logWarning("Skipping statistics entry with invalid key size: {}", dkey.mv_size);
                continue;
            }
            std::int64_t keyTimeRaw = 0;
            std::memcpy(&keyTimeRaw, dkey.mv_data, sizeof(keyTimeRaw));
            std::time_t timestamp = static_cast<std::time_t>(keyTimeRaw);

            std::vector<std::byte> binaryData(
                static_cast<const std::byte *>(dval.mv_data),
                static_cast<const std::byte *>(dval.mv_data) + dval.mv_size);
            if (!binaryData.empty() && static_cast<uint8_t>(binaryData[0]) == 1) {
                // previously, data was stored in binary, instead of reading that data, we ignore it now
                continue;
            }

            try {
                auto entry = deserializeStatsEntry(timestamp, binaryData);
                stats.push_back(std::move(entry));
            } catch (const std::exception &e) {
                logWarning("Failed to deserialize statistics entry: {}", e.what());
                continue;
            }
        }

        mdb_cursor_close(cur);
        quitTransaction(txn);

        return stats;
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }
}

void DataStore::removeStatistics(std::time_t time)
{
    std::int64_t keyTime = time;
    MDB_val dbkey;
    dbkey.mv_size = sizeof(std::int64_t);
    dbkey.mv_data = &keyTime;

    MDB_txn *txn = newTransaction();
    try {
        int res = mdb_del(txn, m_dbStats, &dbkey, nullptr);
        if (res != MDB_NOTFOUND)
            checkError(res, "mdb_del");
        commitTransaction(txn);
    } catch (...) {
        quitTransaction(txn);
        throw;
    }
}

void DataStore::addStatistics(const StatisticsEntry &stats)
{
    std::int64_t keyTime = stats.time;
    MDB_val dbkey;
    dbkey.mv_size = sizeof(std::int64_t);
    dbkey.mv_data = &keyTime;

    auto statsDataBytes = serializeStatsEntryData(stats);
    MDB_val dbvalue;
    dbvalue.mv_size = statsDataBytes.size();
    dbvalue.mv_data = statsDataBytes.data();

    MDB_txn *txn = newTransaction();
    try {
        int res = mdb_put(txn, m_dbStats, &dbkey, &dbvalue, MDB_APPEND);
        if (res == MDB_KEYEXIST) {
            // this point in time already exists, but we do not allow overriding data - so we lie and shift
            // the timestamp one second forward in time, to get a free slot
            logWarning("Statistics entry for timestamp {} already exists, skipping a second", stats.time);

            quitTransaction(txn);

            StatisticsEntry newStats;
            newStats.time = stats.time + 1;
            newStats.data = stats.data;
            addStatistics(newStats);
            return;
        }
        checkError(res, "mdb_put (stats)");
        commitTransaction(txn);
    } catch (...) {
        quitTransaction(txn);
        throw;
    }
}

void DataStore::addStatistics(
    const std::unordered_map<std::string, std::variant<std::int64_t, std::string, double>> &statsData)
{
    StatisticsEntry entry;
    entry.time = std::time(nullptr);
    entry.data = statsData;
    addStatistics(entry);
}

RepoInfo DataStore::getRepoInfo(const std::string &suite, const std::string &section, const std::string &arch)
{
    const auto repoid = suite + "-" + section + "-" + arch;
    const auto binaryData = getBinaryValue(m_dbRepoInfo, repoid);
    if (binaryData.empty())
        return RepoInfo{};
    if (static_cast<uint8_t>(binaryData[0]) == 1) {
        logDebug("Ignoring legacy binary repository info entry for {}", repoid);
        return RepoInfo{};
    }

    try {
        return RepoInfo::deserialize(binaryData);
    } catch (const std::exception &e) {
        logWarning("Failed to deserialize repository info for {}: {}", repoid, e.what());
        return RepoInfo{};
    }
}

void DataStore::setRepoInfo(
    const std::string &suite,
    const std::string &section,
    const std::string &arch,
    const RepoInfo &repoInfo)
{
    const auto repoid = suite + "-" + section + "-" + arch;
    const auto serializedData = repoInfo.serialize();
    putBinaryValue(m_dbRepoInfo, repoid, serializedData);
}

void DataStore::removeRepoInfo(const std::string &suite, const std::string &section, const std::string &arch)
{
    const auto repoid = suite + "-" + section + "-" + arch;
    MDB_val dbkey = makeDbValue(repoid);

    MDB_txn *txn = newTransaction();
    try {
        int res = mdb_del(txn, m_dbRepoInfo, &dbkey, nullptr);
        if (res != MDB_NOTFOUND) {
            checkError(res, "mdb_del");
        }
        commitTransaction(txn);
    } catch (...) {
        quitTransaction(txn);
        throw;
    }
}

std::vector<std::string> DataStore::getPkidsMatching(const std::string &prefix)
{
    MDB_val dkey;
    MDB_cursor *cur = nullptr;

    MDB_txn *txn = newTransaction(MDB_RDONLY);
    try {
        int res = mdb_cursor_open(txn, m_dbPackages, &cur);
        checkError(res, "mdb_cursor_open (pkid-match)");

        std::vector<std::string> pkids;
        const std::string searchPrefix = prefix + "/";

        while (mdb_cursor_get(cur, &dkey, nullptr, MDB_NEXT) == 0) {
            const std::string pkid(static_cast<const char *>(dkey.mv_data), dkey.mv_size - 1);
            if (pkid.starts_with(searchPrefix))
                pkids.push_back(pkid);
        }

        mdb_cursor_close(cur);
        quitTransaction(txn);
        return pkids;
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }
}

} // namespace ASGenerator
