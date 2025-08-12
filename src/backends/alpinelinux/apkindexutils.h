/*
 * Copyright (C) 2020-2025 Rasmus Thomsen <oss@cogitri.dev>
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
#include <format>

#include "../../downloader.h"

namespace ASGenerator
{

/**
 * Struct representing a block inside of an APKINDEX. Each block, separated by
 * a newline, contains information about exactly one package.
 */
struct ApkIndexBlock {
    std::string arch;
    std::string maintainer;
    std::string pkgname;
    std::string pkgversion;
    std::string pkgdesc;

    std::string archiveName() const
    {
        return std::format("{}-{}.apk", pkgname, pkgversion);
    }
};

/**
 * Range for looping over the contents of an APKINDEX, block by block.
 */
class ApkIndexBlockRange
{
public:
    explicit ApkIndexBlockRange(const std::string &contents);

    const ApkIndexBlock &front() const;
    bool empty() const;
    void popFront();

    // Iterator interface for range-based for loops
    class iterator
    {
    private:
        ApkIndexBlockRange *m_range;
        bool m_isEnd;

    public:
        explicit iterator(ApkIndexBlockRange *range, bool isEnd = false);

        const ApkIndexBlock &operator*() const;
        const ApkIndexBlock *operator->() const;

        iterator &operator++();
        bool operator!=(const iterator &other) const;
    };

    iterator begin();
    iterator end();

private:
    std::vector<std::string> m_lines;
    std::size_t m_lineDelta;
    ApkIndexBlock m_currentBlock;
    bool m_empty;

    void getNextBlock();
    void setCurrentBlock(const std::string &key, const std::string &value);
};

/**
 * Download APK index file if necessary
 */
std::string downloadIfNecessary(
    const std::string &apkRootPath,
    const std::string &tmpDir,
    const std::string &fileName,
    const std::string &cacheFileName);

} // namespace ASGenerator
