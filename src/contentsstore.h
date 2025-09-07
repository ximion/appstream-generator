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
#include <mutex>
#include <lmdb.h>

namespace ASGenerator
{

class Config;

/**
 * Contains a cache about available files in packages.
 * This is useful for finding icons and for quickly
 * re-scanning packages which may become interesting later.
 */
class ContentsStore
{
public:
    ContentsStore();
    ~ContentsStore();

    void open(const std::string &dir);
    void open(const Config &conf);
    void close();

    /**
     * Drop a package-id from the contents cache.
     */
    void removePackage(const std::string &pkid);

    bool packageExists(const std::string &pkid);

    void addContents(const std::string &pkid, const std::vector<std::string> &contents);

    std::unordered_map<std::string, std::string> getContentsMap(const std::vector<std::string> &pkids);
    std::unordered_map<std::string, std::string> getIconFilesMap(const std::vector<std::string> &pkids);

    /**
     * We make the assumption here that all locale for a given domain are in one package.
     * Otherwise this global search will get even more insane.
     */
    std::unordered_map<std::string, std::string> getLocaleMap(const std::vector<std::string> &pkids);

    std::vector<std::string> getContents(const std::string &pkid);
    std::vector<std::string> getIcons(const std::string &pkid);
    std::vector<std::string> getLocaleFiles(const std::string &pkid);

    std::unordered_set<std::string> getPackageIdSet();

    void removePackages(const std::unordered_set<std::string> &pkidSet);

    void sync();

    // Delete copy constructor and assignment operator
    ContentsStore(const ContentsStore &) = delete;
    ContentsStore &operator=(const ContentsStore &) = delete;

private:
    MDB_env *dbEnv;
    MDB_dbi dbContents{0};
    MDB_dbi dbIcons{0};
    MDB_dbi dbLocale{0};

    bool m_opened;
    std::mutex m_mutex;

    void checkError(int rc, const std::string &msg);
    MDB_val makeDbValue(const std::string &data);
    MDB_txn *newTransaction(unsigned int flags = 0);
    void commitTransaction(MDB_txn *txn);
    void quitTransaction(MDB_txn *txn);

    std::unordered_map<std::string, std::string> getFilesMap(
        const std::vector<std::string> &pkids,
        MDB_dbi dbi,
        bool useBaseName = false);

    std::vector<std::string> getContentsList(const std::string &pkid, MDB_dbi dbi);
};

} // namespace ASGenerator
