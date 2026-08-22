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

#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <filesystem>
#include <memory>
#include <mutex>
#include <atomic>
#include <cstddef>
#include <variant>
#include <appstream.h>
#include <lmdb.h>

#include "logging.h"
#include "config.h"

namespace ASGenerator
{

class GeneratorResult;

/**
 * Type alias for generic metadata values used in DataStore.
 */
using MetaValue = std::variant<std::int64_t, std::string, double>;

/**
 * Statistics entry
 */
struct StatisticsEntry {
    std::time_t time{0};
    std::unordered_map<std::string, MetaValue> data;
};

/**
 * Repository info entry
 */
struct RepoInfo {
    std::unordered_map<std::string, MetaValue> data;

    std::vector<std::byte> serialize() const;
    static RepoInfo deserialize(const std::vector<std::byte> &data);
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
     * Get the ID of the package that owns the component data stored for @gcid,
     * or an empty string if we have no record of it.
     *
     * Two packages shipping byte-identical metadata produce the same GCID, so we
     * have to pick one of them to be associated with the resulting component.
     * That choice must not depend on the order in which packages happen to be
     * processed, so we remember who won (see @componentOwnerWins).
     */
    std::string getGcidOwner(const std::string &gcid);

    /**
     * Try to become the package associated with the component data of @gcid.
     *
     * The claim is granted if nobody owns the component yet, if we already own it, or if
     * we beat the current owner according to @componentOwnerWins. The whole check-and-set
     * happens in one write transaction, so two packages racing for the same component can
     * not both walk away thinking they won.
     *
     * @param previousOwner Set to the package that owned the component before this call,
     *                      or an empty string if it was unowned.
     * @param force Take the component over regardless of who owns it. Used for injected
     *              metadata, which is meant to override whatever the archive contains.
     * @return true if we own the component now.
     */
    bool claimComponentOwnership(
        const std::string &gcid,
        const std::string &pkid,
        std::string &previousOwner,
        bool force = false);

    /**
     * Create a new, empty directory for a media renderer of this run to work in.
     *
     * Media is never written to the pool directly: it is rendered into a staging directory
     * and only moved over once we know that the component it belongs to is ours to keep.
     * The staging area belongs to this generator run and is removed when the store is
     * closed, so callers only need to clean up between packages.
     */
    fs::path createMediaStagingDir();

    /**
     * Decide which of two packages should be associated with a component that both
     * of them provide identical metadata for.
     *
     * @param contenderPkid The package that wants to take ownership.
     * @param ownerPkid The package currently owning the data. May be empty or lack a
     *                  version if it was recorded by an older version of the generator,
     *                  in which case we compare names only.
     * @return true if @contenderPkid should take ownership.
     */
    static bool componentOwnerWins(const std::string &contenderPkid, const std::string &ownerPkid);

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
     * Add generator result to database.
     *
     * Media of components we get to keep are moved into the pool from the staging area that
     * @gres owns, and the staging area is dropped afterwards.
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
    void removeStatistics(std::time_t time);

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
    quill::Logger *m_log;
    MDB_env *m_dbEnv;
    MDB_dbi m_dbRepoInfo;
    MDB_dbi m_dbPackages;
    MDB_dbi m_dbDataXml;
    MDB_dbi m_dbDataYaml;
    MDB_dbi m_dbHints;
    MDB_dbi m_dbGcidRegistry;
    MDB_dbi m_dbStats;

    bool m_opened;
    AsMetadata *m_mdata;
    fs::path m_mediaDir;

    // media staging area of this generator run, as well as the lock that marks it as
    // belonging to a live process
    fs::path m_mediaStagingRoot;
    int m_stagingLockFd;
    std::atomic<std::uint64_t> m_stagingDirCounter;

    mutable std::mutex m_mutex;

    /**
     * Create the media staging area of this run and mark it as in use, removing any
     * staging areas that runs which are no longer alive have left behind.
     */
    void acquireMediaStaging(const fs::path &mediaBaseDir);

    /**
     * Drop the media staging area of this run. The shared staging directory is removed
     * as well, unless another generator run is still using it.
     */
    void releaseMediaStaging();

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
     * Move the media rendered for @gcid from @stagedMediaDir into the media pool, replacing
     * any data that was there before. @stagedMediaDir holds the media of this one component,
     * as returned by GeneratorResult::mediaStagingDir().
     *
     * The media pool is only ever modified here, while all rendering happens in the staging
     * areas the results own. Callers must ensure that results are committed one at a time
     * (Engine holds a mutex for that), otherwise two packages could swap out the same
     * destination directory simultaneously.
     */
    void publishComponentMedia(const std::string &gcid, const fs::path &stagedMediaDir);

    /**
     * Take the component @gcid away from @pkid, after another package won it.
     *
     * Drops the package's reference to the component and, if @cid is set, records why by
     * adding a duplicate-ID hint naming @newOwnerName. A package that was committed before
     * the winner can not know that it lost, so this leaves it in the same state it would
     * have been in had it known all along.
     */
    void takeComponentFrom(
        const std::string &pkid,
        const std::string &gcid,
        const std::string &cid,
        const std::string &newOwnerName);

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
    void putBinaryValue(MDB_dbi dbi, const std::string &key, const std::vector<std::byte> &value);

    /**
     * Get binary value from database
     */
    std::vector<std::byte> getBinaryValue(MDB_dbi dbi, const std::string &key);
};

} // namespace ASGenerator
