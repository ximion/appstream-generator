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

#include "statsstore.h"

#include <format>
#include <filesystem>
#include <stdexcept>
#include <cassert>
#include <cstring>
#include <nlohmann/json.hpp>

#include "config.h"
#include "logging.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

using json = nlohmann::json;

std::vector<std::byte> serializeStatsEntryData(const StatisticsEntry &entry)
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

StatisticsEntry deserializeStatsEntry(std::time_t timestamp, const std::vector<std::byte> &data)
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

StatsStore::StatsStore()
    : m_log(getLogger("statsstore")),
      m_dbEnv(nullptr),
      m_dbStats(0),
      m_opened(false)
{
}

StatsStore::~StatsStore()
{
    close();
}

void StatsStore::checkError(int rc, const std::string &msg)
{
    if (rc != 0)
        throw std::runtime_error(std::format("{}[{}]: {}", msg, rc, mdb_strerror(rc)));
}

void StatsStore::open(const std::string &dir)
{
    int rc;
    if (m_opened)
        throw std::runtime_error("StatsStore was already opened.");

    LOG_DEBUG(m_log, "Opening statistics database.");

    // ensure the database directory exists
    fs::create_directories(dir);

    rc = mdb_env_create(&m_dbEnv);
    if (rc != 0) {
        checkError(rc, "mdb_env_create");
        return;
    }

    // we only ever use one sub-database here: statistics
    rc = mdb_env_set_maxdbs(m_dbEnv, 1);
    if (rc != 0) {
        mdb_env_close(m_dbEnv);
        checkError(rc, "mdb_env_set_maxdbs");
        return;
    }

    // one entry per suite/section and generator run is all we ever store here, so unlike the
    // other databases this one does not need a huge map size.
    auto mapsize = static_cast<size_t>(2) * 1024 * 1024 * 1024;
    rc = mdb_env_set_mapsize(m_dbEnv, mapsize);
    if (rc != 0) {
        mdb_env_close(m_dbEnv);
        checkError(rc, "mdb_env_set_mapsize");
        return;
    }

    // open database. We do not skip any syncs here (unlike for the caches): writes are rare,
    // and this data can not be regenerated if we lose it.
    rc = mdb_env_open(m_dbEnv, dir.c_str(), 0, 0755);
    if (rc != 0) {
        mdb_env_close(m_dbEnv);
        checkError(rc, "mdb_env_open");
        return;
    }

    // open sub-database in the environment
    MDB_txn *txn;
    rc = mdb_txn_begin(m_dbEnv, nullptr, 0, &txn);
    if (rc != 0) {
        mdb_env_close(m_dbEnv);
        checkError(rc, "mdb_txn_begin");
        return;
    }

    try {
        rc = mdb_dbi_open(txn, "statistics", MDB_CREATE | MDB_INTEGERKEY, &m_dbStats);
        checkError(rc, "open statistics database");

        rc = mdb_txn_commit(txn);
        checkError(rc, "mdb_txn_commit");

        m_opened = true;
    } catch (...) {
        mdb_txn_abort(txn);
        mdb_env_close(m_dbEnv);
        throw;
    }
}

void StatsStore::open(const Config &conf)
{
    auto path = conf.databaseDir() / "stats";
    open(path.string());
}

void StatsStore::close()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_opened && m_dbEnv) {
        mdb_env_close(m_dbEnv);
        m_opened = false;
        m_dbEnv = nullptr;
    }
}

MDB_txn *StatsStore::newTransaction(unsigned int flags)
{
    assert(m_opened);

    MDB_txn *txn;
    auto rc = mdb_txn_begin(m_dbEnv, nullptr, flags, &txn);
    checkError(rc, "mdb_txn_begin");

    return txn;
}

void StatsStore::commitTransaction(MDB_txn *txn)
{
    auto rc = mdb_txn_commit(txn);
    checkError(rc, "mdb_txn_commit");
}

void StatsStore::quitTransaction(MDB_txn *txn)
{
    if (txn == nullptr)
        return;
    mdb_txn_abort(txn);
}

std::vector<StatisticsEntry> StatsStore::getStatistics()
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
                LOG_WARNING(m_log, "Skipping statistics entry with invalid key size: {}", dkey.mv_size);
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
                LOG_WARNING(m_log, "Failed to deserialize statistics entry: {}", e.what());
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

void StatsStore::addStatistics(const StatisticsEntry &stats)
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
            LOG_WARNING(m_log, "Statistics entry for timestamp {} already exists, skipping a second", stats.time);

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

void StatsStore::addStatistics(const std::unordered_map<std::string, MetaValue> &statsData)
{
    StatisticsEntry entry;
    entry.time = std::time(nullptr);
    entry.data = statsData;
    addStatistics(entry);
}

void StatsStore::removeStatistics(std::time_t time)
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

} // namespace ASGenerator
