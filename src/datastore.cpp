/*
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
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

#include "logging.h"
#include "result.h"
#include "utils.h"

namespace ASGenerator
{

// Helper function for binary serialization of variant maps
static std::vector<std::uint8_t> serializeVariantMap(
    const std::unordered_map<std::string, std::variant<std::int64_t, std::string, double>> &data,
    std::optional<std::size_t> timestamp = std::nullopt)
{
    std::vector<std::uint8_t> buffer;
    buffer.reserve(1024);

    // Version byte for future compatibility
    buffer.push_back(1);

    // Serialize timestamp if provided (for StatisticsEntry)
    if (timestamp) {
        const auto time_bytes = reinterpret_cast<const std::uint8_t *>(&*timestamp);
        buffer.insert(buffer.end(), time_bytes, time_bytes + sizeof(std::size_t));
    }

    // Serialize data map count (4 bytes)
    const auto data_count = static_cast<std::uint32_t>(data.size());
    const auto count_bytes = reinterpret_cast<const std::uint8_t *>(&data_count);
    buffer.insert(buffer.end(), count_bytes, count_bytes + sizeof(std::uint32_t));

    // Serialize each key-value pair
    for (const auto &[key, value] : data) {
        // Key length (2 bytes) + key string
        const auto key_len = static_cast<std::uint16_t>(key.length());
        const auto key_len_bytes = reinterpret_cast<const std::uint8_t *>(&key_len);
        buffer.insert(buffer.end(), key_len_bytes, key_len_bytes + sizeof(std::uint16_t));
        buffer.insert(buffer.end(), key.begin(), key.end());

        // Value type (1 byte) + value data
        std::visit(
            [&buffer](const auto &val) {
                using T = std::decay_t<decltype(val)>;
                if constexpr (std::is_same_v<T, std::int64_t>) {
                    buffer.push_back(1); // int64 type
                    const auto val_bytes = reinterpret_cast<const std::uint8_t *>(&val);
                    buffer.insert(buffer.end(), val_bytes, val_bytes + sizeof(std::int64_t));
                } else if constexpr (std::is_same_v<T, double>) {
                    buffer.push_back(2); // double type
                    const auto val_bytes = reinterpret_cast<const std::uint8_t *>(&val);
                    buffer.insert(buffer.end(), val_bytes, val_bytes + sizeof(double));
                } else if constexpr (std::is_same_v<T, std::string>) {
                    buffer.push_back(3); // string type
                    const auto str_len = static_cast<std::uint16_t>(val.length());
                    const auto str_len_bytes = reinterpret_cast<const std::uint8_t *>(&str_len);
                    buffer.insert(buffer.end(), str_len_bytes, str_len_bytes + sizeof(std::uint16_t));
                    buffer.insert(buffer.end(), val.begin(), val.end());
                }
            },
            value);
    }

    return buffer;
}

// Helper function for binary deserialization of variant maps
template<typename T>
T deserializeVariantMap(const std::vector<std::uint8_t> &binary_data, bool has_timestamp = false)
{
    const size_t min_size = has_timestamp ? 13 : 5; // version + [time +] count
    if (binary_data.size() < min_size)
        throw std::runtime_error("Invalid data: buffer too small");

    size_t pos = 0;
    T entry{};

    // Check version
    const std::uint8_t version = binary_data[pos++];
    if (version != 1)
        throw std::runtime_error(std::format("Unsupported version: {}", static_cast<int>(version)));

    // Read timestamp if present (for StatisticsEntry)
    if constexpr (std::is_same_v<T, StatisticsEntry>) {
        if (has_timestamp) {
            std::memcpy(&entry.time, &binary_data[pos], sizeof(std::size_t));
            pos += sizeof(std::size_t);
        }
    }

    // Read data count
    std::uint32_t data_count;
    std::memcpy(&data_count, &binary_data[pos], sizeof(std::uint32_t));
    pos += sizeof(std::uint32_t);

    // Read key-value pairs
    for (std::uint32_t i = 0; i < data_count; ++i) {
        if (pos + 2 > binary_data.size())
            throw std::runtime_error("Invalid data: truncated key length");

        // Read key
        std::uint16_t key_len;
        std::memcpy(&key_len, &binary_data[pos], sizeof(std::uint16_t));
        pos += sizeof(std::uint16_t);

        if (pos + key_len > binary_data.size())
            throw std::runtime_error("Invalid data: truncated key");

        std::string key(reinterpret_cast<const char *>(&binary_data[pos]), key_len);
        pos += key_len;

        if (pos >= binary_data.size())
            throw std::runtime_error("Invalid data: missing value type");

        // Read value based on type
        const std::uint8_t value_type = binary_data[pos++];
        switch (value_type) {
        case 1: { // int64
            if (pos + sizeof(std::int64_t) > binary_data.size())
                throw std::runtime_error("Invalid data: truncated int64 value");

            std::int64_t value;
            std::memcpy(&value, &binary_data[pos], sizeof(std::int64_t));
            pos += sizeof(std::int64_t);
            entry.data[key] = value;
            break;
        }
        case 2: { // double
            if (pos + sizeof(double) > binary_data.size())
                throw std::runtime_error("Invalid data: truncated double value");

            double value;
            std::memcpy(&value, &binary_data[pos], sizeof(double));
            pos += sizeof(double);
            entry.data[key] = value;
            break;
        }
        case 3: { // string
            if (pos + sizeof(std::uint16_t) > binary_data.size())
                throw std::runtime_error("Invalid data: truncated string length");

            std::uint16_t str_len;
            std::memcpy(&str_len, &binary_data[pos], sizeof(std::uint16_t));
            pos += sizeof(std::uint16_t);

            if (pos + str_len > binary_data.size())
                throw std::runtime_error("Invalid data: truncated string value");

            std::string value(reinterpret_cast<const char *>(&binary_data[pos]), str_len);
            pos += str_len;
            entry.data[key] = value;
            break;
        }
        default: {
            throw std::runtime_error(std::format("Unknown value type: {}", static_cast<int>(value_type)));
        }
        }
    }

    return entry;
}

// Binary serialization implementation for RepoInfo
std::vector<std::uint8_t> RepoInfo::serialize() const
{
    return serializeVariantMap(data);
}

RepoInfo RepoInfo::deserialize(const std::vector<std::uint8_t> &binary_data)
{
    return deserializeVariantMap<RepoInfo>(binary_data, false);
}

// Binary serialization implementation for StatisticsEntry
std::vector<std::uint8_t> StatisticsEntry::serialize() const
{
    return serializeVariantMap(data, time);
}

StatisticsEntry StatisticsEntry::deserialize(const std::vector<std::uint8_t> &binary_data)
{
    return deserializeVariantMap<StatisticsEntry>(binary_data, true);
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
    MDB_cursor *cur;

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

void DataStore::dropOrphanedData(MDB_dbi dbi, const std::unordered_set<std::string> &activeGCIDs)
{
    MDB_cursor *cur;

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
    MDB_cursor *cur;

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

void DataStore::putBinaryValue(MDB_dbi dbi, const std::string &key, const std::vector<std::uint8_t> &value)
{
    MDB_val dbkey = makeDbValue(key);
    MDB_val dbvalue;
    dbvalue.mv_size = value.size();
    dbvalue.mv_data = const_cast<std::uint8_t *>(value.data());

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

std::vector<std::uint8_t> DataStore::getBinaryValue(MDB_dbi dbi, const std::string &key)
{
    MDB_val dbkey = makeDbValue(key);
    MDB_val dval;
    MDB_cursor *cur;

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

        std::vector<std::uint8_t> result(
            static_cast<const std::uint8_t *>(dval.mv_data),
            static_cast<const std::uint8_t *>(dval.mv_data) + dval.mv_size);
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
    MDB_cursor *cur;

    MDB_txn *txn = newTransaction(MDB_RDONLY);
    try {
        int res = mdb_cursor_open(txn, m_dbStats, &cur);
        checkError(res, "mdb_cursor_open (stats)");

        std::vector<StatisticsEntry> stats;
        stats.reserve(256);
        while (mdb_cursor_get(cur, &dkey, &dval, MDB_NEXT) == 0) {
            std::vector<std::uint8_t> binaryData(
                static_cast<const std::uint8_t *>(dval.mv_data),
                static_cast<const std::uint8_t *>(dval.mv_data) + dval.mv_size);
            if (!binaryData.empty() && binaryData[0] == '{') {
                // previously, data was stored in JSON, instead of reading that data, we ignore it now
                continue;
            }
            try {
                auto entry = StatisticsEntry::deserialize(binaryData);
                stats.push_back(entry);
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

void DataStore::removeStatistics(std::size_t time)
{
    MDB_val dbkey;
    dbkey.mv_size = sizeof(std::size_t);
    dbkey.mv_data = const_cast<std::size_t *>(&time);

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
    MDB_val dbkey;
    dbkey.mv_size = sizeof(std::size_t);
    dbkey.mv_data = const_cast<std::size_t *>(&stats.time);

    auto serializedData = stats.serialize();
    MDB_val dbvalue;
    dbvalue.mv_size = serializedData.size();
    dbvalue.mv_data = serializedData.data();

    MDB_txn *txn = newTransaction();
    try {
        int res = mdb_put(txn, m_dbStats, &dbkey, &dbvalue, MDB_APPEND);
        if (res == MDB_KEYEXIST) {
            // this point in time already exists, so we need to extend it with additional data
            logWarning("Statistics entry for timestamp {} already exists, overwriting", stats.time);
            res = mdb_put(txn, m_dbStats, &dbkey, &dbvalue, 0);
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
    MDB_cursor *cur;

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
