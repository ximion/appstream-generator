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

#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <filesystem>
#include <memory>
#include <mutex>
#include <cstddef>
#include <variant>
#include <appstream.h>
#include <lmdb.h>

#include "config.h"

namespace ASGenerator
{

class GeneratorResult;

/**
 * Statistics entry
 */
struct StatisticsEntry {
    std::size_t time;
    std::unordered_map<std::string, std::variant<std::int64_t, std::string, double>> data;

    std::vector<std::uint8_t> serialize() const;
    static StatisticsEntry deserialize(const std::vector<std::uint8_t> &binary_data);
};

/**
 * Repository info entry
 */
struct RepoInfo {
    std::unordered_map<std::string, std::variant<std::int64_t, std::string, double>> data;

    std::vector<std::uint8_t> serialize() const;
    static RepoInfo deserialize(const std::vector<std::uint8_t> &binary_data);
};

/**
 * Main database containing information about scanned packages,
 * the components they provide, the component metadata itself,
 * issues found as well as statistics about the metadata evolution
 * over time.
 */
class DataStore
{
public:
    DataStore();
    ~DataStore();

    // Delete copy constructor and assignment operator
    DataStore(const DataStore &) = delete;
    DataStore &operator=(const DataStore &) = delete;

    /**
     * Get the media export pool directory
     */
    const fs::path &mediaExportPoolDir() const;

    /**
     * Open database with explicit directories
     */
    void open(const std::string &dir, const fs::path &mediaBaseDir);

    /**
     * Open database using configuration
     */
    void open(const Config &conf);

    /**
     * Close the database
     */
    void close();

    /**
     * Check if metadata exists for given type and GCID
     */
    bool metadataExists(DataType dtype, const std::string &gcid);

    /**
     * Set metadata for given type and GCID
     */
    void setMetadata(DataType dtype, const std::string &gcid, const std::string &asdata);

    /**
     * Get metadata for given type and GCID
     */
    std::string getMetadata(DataType dtype, const std::string &gcid);

    /**
     * Check if package has hints
     */
    bool hasHints(const std::string &pkid);

    /**
     * Set hints for package
     */
    void setHints(const std::string &pkid, const std::string &hintsJson);

    /**
     * Get hints for package
     */
    std::string getHints(const std::string &pkid);

    /**
     * Get package value from database
     */
    std::string getPackageValue(const std::string &pkid);

    /**
     * Mark package as ignored
     */
    void setPackageIgnore(const std::string &pkid);

    /**
     * Check if package is ignored
     */
    bool isIgnored(const std::string &pkid);

    /**
     * Check if package exists in database
     */
    bool packageExists(const std::string &pkid);

    /**
     * Add generator result to database
     */
    void addGeneratorResult(DataType dtype, GeneratorResult &gres, bool alwaysRegenerate = false);

    /**
     * Get global component IDs for package
     */
    std::vector<std::string> getGCIDsForPackage(const std::string &pkid);

    /**
     * Get metadata strings for package
     */
    std::vector<std::string> getMetadataForPackage(DataType dtype, const std::string &pkid);

    /**
     * Drop a package from the database. This process might leave cruft behind,
     * which can be collected using the cleanupCruft() method.
     */
    void removePackage(const std::string &pkid);

    /**
     * Clean up orphaned data and media files
     */
    void cleanupCruft();

    /**
     * Get map of package-IDs to global component IDs based on given GCID list
     */
    std::unordered_map<std::string, std::vector<std::string>> getPackagesForGCIDs(
        std::unordered_set<std::string> gcids);

    /**
     * Get set of all package IDs in database
     */
    std::unordered_set<std::string> getPackageIdSet();

    /**
     * Remove multiple packages from database
     */
    void removePackages(const std::unordered_set<std::string> &pkidSet);

    /**
     * Get all statistics entries
     */
    std::vector<StatisticsEntry> getStatistics();

    /**
     * Remove statistics entry for given time
     */
    void removeStatistics(std::size_t time);

    /**
     * Add statistics entry
     */
    void addStatistics(const StatisticsEntry &stats);

    /**
     * Add statistics entry from key-value data
     */
    void addStatistics(
        const std::unordered_map<std::string, std::variant<std::int64_t, std::string, double>> &statsData);

    /**
     * Get repository info
     */
    RepoInfo getRepoInfo(const std::string &suite, const std::string &section, const std::string &arch);

    /**
     * Set repository info
     */
    void setRepoInfo(
        const std::string &suite,
        const std::string &section,
        const std::string &arch,
        const RepoInfo &repoInfo);

    /**
     * Remove repository info
     */
    void removeRepoInfo(const std::string &suite, const std::string &section, const std::string &arch);

    /**
     * Get a list of package-ids which match a prefix.
     */
    std::vector<std::string> getPkidsMatching(const std::string &prefix);

private:
    MDB_env *m_dbEnv;
    MDB_dbi m_dbRepoInfo;
    MDB_dbi m_dbPackages;
    MDB_dbi m_dbDataXml;
    MDB_dbi m_dbDataYaml;
    MDB_dbi m_dbHints;
    MDB_dbi m_dbStats;

    bool m_opened;
    AsMetadata *m_mdata;
    fs::path m_mediaDir;

    mutable std::mutex m_mutex;

    /**
     * Check LMDB error and throw exception if needed
     */
    void checkError(int rc, const std::string &msg);

    /**
     * Print LMDB version debug info
     */
    void printVersionDbg();

    /**
     * Create MDB_val from string data
     */
    MDB_val makeDbValue(const std::string &data);

    /**
     * Create new LMDB transaction
     */
    MDB_txn *newTransaction(unsigned int flags = 0);

    /**
     * Commit LMDB transaction
     */
    void commitTransaction(MDB_txn *txn);

    /**
     * Abort LMDB transaction
     */
    void quitTransaction(MDB_txn *txn);

    /**
     * Put key-value pair into database
     */
    void putKeyValue(MDB_dbi dbi, const std::string &key, const std::string &value);

    /**
     * Get value from database using MDB_val key
     */
    std::string getValue(MDB_dbi dbi, MDB_val dkey);

    /**
     * Get value from database using string key
     */
    std::string getValue(MDB_dbi dbi, const std::string &key);

    /**
     * Get active global component IDs
     */
    std::unordered_set<std::string> getActiveGCIDs();

    /**
     * Drop orphaned data from given database
     */
    void dropOrphanedData(MDB_dbi dbi, const std::unordered_set<std::string> &activeGCIDs);

    /**
     * Clean up empty directories
     */
    void cleanupDirs(const std::string &rootPath);

    /**
     * Put binary value into database
     */
    void putBinaryValue(MDB_dbi dbi, const std::string &key, const std::vector<std::uint8_t> &value);

    /**
     * Get binary value from database
     */
    std::vector<std::uint8_t> getBinaryValue(MDB_dbi dbi, const std::string &key);
};

} // namespace ASGenerator
