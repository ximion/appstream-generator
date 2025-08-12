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

#include "contentsstore.h"

#include <format>
#include <filesystem>
#include <algorithm>
#include <sstream>
#include <cassert>
#include <cstring>
#include <cmath>

#include "config.h"
#include "logging.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

ContentsStore::ContentsStore()
    : dbEnv(nullptr),
      m_opened(false)
{
}

ContentsStore::~ContentsStore()
{
    close();
}

void ContentsStore::checkError(int rc, const std::string &msg)
{
    if (rc != 0)
        throw std::runtime_error(std::format("{}[{}]: {}", msg, rc, mdb_strerror(rc)));
}

void ContentsStore::open(const std::string &dir)
{
    int rc;
    if (m_opened)
        throw std::runtime_error("ContentsStore was already opened.");

    logDebug("Opening contents cache.");

    // ensure the cache directory exists
    fs::create_directories(dir);

    rc = mdb_env_create(&dbEnv);
    if (rc != 0) {
        checkError(rc, "mdb_env_create");
        return;
    }

    // We are going to use at max 3 sub-databases:
    // contents, icons and locale
    rc = mdb_env_set_maxdbs(dbEnv, 3);
    if (rc != 0) {
        mdb_env_close(dbEnv);
        checkError(rc, "mdb_env_set_maxdbs");
        return;
    }

    // set a huge map size to be futureproof.
    // This means we're cruel to non-64bit users, but this
    // software is supposed to be run on 64bit machines anyway.
    auto mapsize = static_cast<size_t>(std::pow(512L, 4));
    rc = mdb_env_set_mapsize(dbEnv, mapsize);
    if (rc != 0) {
        mdb_env_close(dbEnv);
        checkError(rc, "mdb_env_set_mapsize");
        return;
    }

    // open database
    rc = mdb_env_open(dbEnv, dir.c_str(), MDB_NOMETASYNC, 0755);
    if (rc != 0) {
        mdb_env_close(dbEnv);
        checkError(rc, "mdb_env_open");
        return;
    }

    // open sub-databases in the environment
    MDB_txn *txn;
    rc = mdb_txn_begin(dbEnv, nullptr, 0, &txn);
    if (rc != 0) {
        mdb_env_close(dbEnv);
        checkError(rc, "mdb_txn_begin");
        return;
    }

    try {
        // contains a full list of all contents
        rc = mdb_dbi_open(txn, "contents", MDB_CREATE, &dbContents);
        checkError(rc, "open contents database");

        // contains list of icon files and related data
        // the contents sub-database exists only to allow building instances
        // of IconHandler much faster.
        rc = mdb_dbi_open(txn, "icondata", MDB_CREATE, &dbIcons);
        checkError(rc, "open icon-info database");

        // contains list of locale files and related data
        rc = mdb_dbi_open(txn, "localedata", MDB_CREATE, &dbLocale);
        checkError(rc, "open locale-info database");

        rc = mdb_txn_commit(txn);
        checkError(rc, "mdb_txn_commit");

        m_opened = true;
    } catch (...) {
        mdb_txn_abort(txn);
        mdb_env_close(dbEnv);
        throw;
    }
}

void ContentsStore::open(const Config &conf)
{
    auto path = conf.databaseDir() / "contents";
    open(path.string());
}

void ContentsStore::close()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_opened && dbEnv) {
        mdb_env_close(dbEnv);
        m_opened = false;
        dbEnv = nullptr;
    }
}

MDB_val ContentsStore::makeDbValue(const std::string &data)
{
    MDB_val mval;
    mval.mv_size = data.length() + 1;
    mval.mv_data = const_cast<void *>(static_cast<const void *>(data.c_str()));
    return mval;
}

MDB_txn *ContentsStore::newTransaction(unsigned int flags)
{
    assert(m_opened);

    int rc;
    MDB_txn *txn;

    rc = mdb_txn_begin(dbEnv, nullptr, flags, &txn);
    checkError(rc, "mdb_txn_begin");

    return txn;
}

void ContentsStore::commitTransaction(MDB_txn *txn)
{
    auto rc = mdb_txn_commit(txn);
    checkError(rc, "mdb_txn_commit");
}

void ContentsStore::quitTransaction(MDB_txn *txn)
{
    if (txn == nullptr)
        return;
    mdb_txn_abort(txn);
}

void ContentsStore::removePackage(const std::string &pkid)
{
    MDB_val key = makeDbValue(pkid);

    auto txn = newTransaction();
    try {
        auto res = mdb_del(txn, dbContents, &key, nullptr);
        checkError(res, "mdb_del (contents)");

        res = mdb_del(txn, dbIcons, &key, nullptr);
        if (res != MDB_NOTFOUND)
            checkError(res, "mdb_del (icons)");

        res = mdb_del(txn, dbLocale, &key, nullptr);
        if (res != MDB_NOTFOUND)
            checkError(res, "mdb_del (locale)");

        commitTransaction(txn);
    } catch (...) {
        quitTransaction(txn);
        throw;
    }
}

bool ContentsStore::packageExists(const std::string &pkid)
{
    MDB_val dkey = makeDbValue(pkid);
    MDB_cursor *cur = nullptr;

    auto txn = newTransaction(MDB_RDONLY);
    try {
        auto res = mdb_cursor_open(txn, dbContents, &cur);
        checkError(res, "mdb_cursor_open");

        res = mdb_cursor_get(cur, &dkey, nullptr, MDB_SET);
        mdb_cursor_close(cur);
        cur = nullptr;

        if (res == MDB_NOTFOUND) {
            quitTransaction(txn);
            return false;
        }
        checkError(res, "mdb_cursor_get");

        quitTransaction(txn);
        return true;
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }
}

void ContentsStore::addContents(const std::string &pkid, const std::vector<std::string> &contents)
{
    // filter out icon filenames and filenames of icon-related stuff (e.g. theme.index),
    // as well as locale information
    std::vector<std::string> iconInfo;
    std::vector<std::string> localeInfo;

    for (const auto &f : contents) {
        if (f.starts_with("/usr/share/icons/") || f.starts_with("/usr/share/pixmaps/")) {
            iconInfo.push_back(f);
            continue;
        }

        // create a huge index of all Gettext and Qt translation filenames
        if (f.ends_with(".mo") || f.ends_with(".qm")) {
            localeInfo.push_back(f);
            continue;
        }
    }

    // Join contents with newlines
    std::ostringstream contentsStream;
    for (size_t i = 0; i < contents.size(); ++i) {
        if (i > 0)
            contentsStream << "\n";
        contentsStream << contents[i];
    }
    const std::string contentsStr = contentsStream.str();

    std::lock_guard<std::mutex> lock(m_mutex);

    auto key = makeDbValue(pkid);
    auto contentsVal = makeDbValue(contentsStr);

    auto txn = newTransaction();
    try {
        auto res = mdb_put(txn, dbContents, &key, &contentsVal, 0);
        checkError(res, "mdb_put");

        // if we have icon information, store that too
        if (!iconInfo.empty()) {
            std::ostringstream iconsStream;
            for (size_t i = 0; i < iconInfo.size(); ++i) {
                if (i > 0)
                    iconsStream << "\n";
                iconsStream << iconInfo[i];
            }
            const std::string iconsStr = iconsStream.str();
            MDB_val iconsVal = makeDbValue(iconsStr);

            res = mdb_put(txn, dbIcons, &key, &iconsVal, 0);
            checkError(res, "mdb_put (icons)");
        }

        // store locale
        if (!localeInfo.empty()) {
            std::ostringstream localeStream;
            for (size_t i = 0; i < localeInfo.size(); ++i) {
                if (i > 0)
                    localeStream << "\n";
                localeStream << localeInfo[i];
            }
            const std::string localeStr = localeStream.str();
            MDB_val localeVal = makeDbValue(localeStr);

            res = mdb_put(txn, dbLocale, &key, &localeVal, 0);
            checkError(res, "mdb_put (locale)");
        }

        commitTransaction(txn);
    } catch (...) {
        quitTransaction(txn);
        throw;
    }
}

std::unordered_map<std::string, std::string> ContentsStore::getFilesMap(
    const std::vector<std::string> &pkids,
    MDB_dbi dbi,
    bool useBaseName)
{
    MDB_cursor *cur;

    auto txn = newTransaction(MDB_RDONLY);
    std::unordered_map<std::string, std::string> pkgCMap;

    try {
        auto res = mdb_cursor_open(txn, dbi, &cur);
        checkError(res, "mdb_cursor_open");

        for (const auto &pkid : pkids) {
            MDB_val pkey = makeDbValue(pkid);
            MDB_val cval;

            res = mdb_cursor_get(cur, &pkey, &cval, MDB_SET);
            if (res == MDB_NOTFOUND)
                continue;
            checkError(res, "mdb_cursor_get");

            auto data = static_cast<const char *>(cval.mv_data);
            std::string contents(data);

            std::istringstream stream(contents);
            std::string line;
            while (std::getline(stream, line)) {
                if (useBaseName) {
                    auto pos = line.find_last_of('/');
                    std::string basename = (pos != std::string::npos) ? line.substr(pos + 1) : line;
                    pkgCMap[basename] = pkid;
                } else {
                    pkgCMap[line] = pkid;
                }
            }
        }

        mdb_cursor_close(cur);
        quitTransaction(txn);
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }

    return pkgCMap;
}

std::unordered_map<std::string, std::string> ContentsStore::getContentsMap(const std::vector<std::string> &pkids)
{
    return getFilesMap(pkids, dbContents);
}

std::unordered_map<std::string, std::string> ContentsStore::getIconFilesMap(const std::vector<std::string> &pkids)
{
    return getFilesMap(pkids, dbIcons);
}

std::unordered_map<std::string, std::string> ContentsStore::getLocaleMap(const std::vector<std::string> &pkids)
{
    // we make the assumption here that all locale for a given domain are in one package.
    // otherwise this global search will get even more insane.
    return getFilesMap(pkids, dbLocale);
}

std::vector<std::string> ContentsStore::getContentsList(const std::string &pkid, MDB_dbi dbi)
{
    MDB_val pkey = makeDbValue(pkid);
    MDB_val cval;
    MDB_cursor *cur;

    auto txn = newTransaction(MDB_RDONLY);
    std::vector<std::string> result;

    try {
        auto res = mdb_cursor_open(txn, dbi, &cur);
        checkError(res, "mdb_cursor_open");

        res = mdb_cursor_get(cur, &pkey, &cval, MDB_SET);
        if (res == MDB_NOTFOUND) {
            mdb_cursor_close(cur);
            quitTransaction(txn);
            return result;
        }
        checkError(res, "mdb_cursor_get");

        auto data = static_cast<const char *>(cval.mv_data);
        std::string contentsStr(data);

        std::istringstream stream(contentsStr);
        std::string line;
        while (std::getline(stream, line))
            result.push_back(line);

        mdb_cursor_close(cur);
        quitTransaction(txn);
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }

    return result;
}

std::vector<std::string> ContentsStore::getContents(const std::string &pkid)
{
    return getContentsList(pkid, dbContents);
}

std::vector<std::string> ContentsStore::getIcons(const std::string &pkid)
{
    return getContentsList(pkid, dbIcons);
}

std::vector<std::string> ContentsStore::getLocaleFiles(const std::string &pkid)
{
    return getContentsList(pkid, dbLocale);
}

std::unordered_set<std::string> ContentsStore::getPackageIdSet()
{
    MDB_cursor *cur;

    auto txn = newTransaction();
    std::unordered_set<std::string> pkgSet;

    try {
        auto res = mdb_cursor_open(txn, dbContents, &cur);
        checkError(res, "mdb_cursor_open (getPackageIdSet)");

        MDB_val pkey;
        while (mdb_cursor_get(cur, &pkey, nullptr, MDB_NEXT) == 0) {
            auto data = static_cast<const char *>(pkey.mv_data);
            std::string pkid(data);
            pkgSet.insert(pkid);
        }

        mdb_cursor_close(cur);
        quitTransaction(txn);
    } catch (...) {
        if (cur)
            mdb_cursor_close(cur);
        quitTransaction(txn);
        throw;
    }

    return pkgSet;
}

void ContentsStore::removePackages(const std::unordered_set<std::string> &pkidSet)
{
    auto txn = newTransaction();
    try {
        for (const auto &pkid : pkidSet) {
            auto key = makeDbValue(pkid);

            auto res = mdb_del(txn, dbContents, &key, nullptr);
            checkError(res, "mdb_del (contents)");

            res = mdb_del(txn, dbIcons, &key, nullptr);
            if (res != MDB_NOTFOUND)
                checkError(res, "mdb_del (icons)");

            res = mdb_del(txn, dbLocale, &key, nullptr);
            if (res != MDB_NOTFOUND)
                checkError(res, "mdb_del (locale)");
        }

        commitTransaction(txn);
    } catch (...) {
        quitTransaction(txn);
        throw;
    }
}

void ContentsStore::sync()
{
    assert(m_opened);
    mdb_env_sync(dbEnv, 1);
}

} // namespace ASGenerator
