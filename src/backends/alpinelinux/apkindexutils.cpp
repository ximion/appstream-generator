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

#include "apkindexutils.h"

#include <filesystem>
#include <algorithm>
#include <format>

#include "../../utils.h"
#include "../../logging.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

ApkIndexBlockRange::ApkIndexBlockRange(const std::string &contents)
    : m_lineDelta(0),
      m_empty(false)
{
    m_lines = splitString(contents, '\n');
    getNextBlock();
}

void ApkIndexBlockRange::getNextBlock()
{
    std::vector<std::string> completePair;
    std::size_t iterations = 0;

    m_currentBlock = ApkIndexBlock{};

    for (std::size_t i = m_lineDelta; i < m_lines.size(); ++i) {
        const auto &currentLine = m_lines[i];
        iterations++;

        if (currentLine.empty()) {
            // next block for next package started
            break;
        }

        if (currentLine.find(':') != std::string::npos) {
            if (completePair.empty()) {
                completePair = {currentLine};
                continue;
            }

            const auto joinedPair = joinStrings(completePair, " ");
            const auto colonPos = joinedPair.find(':');
            if (colonPos != std::string::npos) {
                const auto key = joinedPair.substr(0, colonPos);
                const auto value = joinedPair.substr(colonPos + 1);
                setCurrentBlock(key, value);
            }
            completePair = {currentLine};
        } else {
            completePair.push_back(trimString(currentLine));
        }
    }

    // Handle the last pair if we reached the end
    if (!completePair.empty()) {
        const auto joinedPair = joinStrings(completePair, " ");
        const auto colonPos = joinedPair.find(':');
        if (colonPos != std::string::npos) {
            const auto key = joinedPair.substr(0, colonPos);
            const auto value = joinedPair.substr(colonPos + 1);
            setCurrentBlock(key, value);
        }
    }

    m_lineDelta += iterations;
    m_empty = (m_lineDelta >= m_lines.size());
}

void ApkIndexBlockRange::setCurrentBlock(const std::string &key, const std::string &value)
{
    const auto trimmedValue = trimString(value);

    if (key == "P") {
        m_currentBlock.pkgname = trimmedValue;
    } else if (key == "V") {
        m_currentBlock.pkgversion = trimmedValue;
    } else if (key == "A") {
        m_currentBlock.arch = trimmedValue;
    } else if (key == "m") {
        m_currentBlock.maintainer = trimmedValue;
    } else if (key == "T") {
        m_currentBlock.pkgdesc = trimmedValue;
    }
    // Ignore other fields for now
}

const ApkIndexBlock &ApkIndexBlockRange::front() const
{
    return m_currentBlock;
}

bool ApkIndexBlockRange::empty() const
{
    return m_empty;
}

void ApkIndexBlockRange::popFront()
{
    getNextBlock();
}

// Iterator implementation
ApkIndexBlockRange::iterator::iterator(ApkIndexBlockRange *range, bool isEnd)
    : m_range(range),
      m_isEnd(isEnd)
{
}

const ApkIndexBlock &ApkIndexBlockRange::iterator::operator*() const
{
    return m_range->front();
}

const ApkIndexBlock *ApkIndexBlockRange::iterator::operator->() const
{
    return &m_range->front();
}

ApkIndexBlockRange::iterator &ApkIndexBlockRange::iterator::operator++()
{
    m_range->popFront();
    if (m_range->empty()) {
        m_isEnd = true;
    }
    return *this;
}

bool ApkIndexBlockRange::iterator::operator!=(const iterator &other) const
{
    return m_isEnd != other.m_isEnd;
}

ApkIndexBlockRange::iterator ApkIndexBlockRange::begin()
{
    return iterator(this, empty());
}

ApkIndexBlockRange::iterator ApkIndexBlockRange::end()
{
    return iterator(this, true);
}

std::string downloadIfNecessary(
    const std::string &apkRootPath,
    const std::string &tmpDir,
    const std::string &fileName,
    const std::string &cacheFileName)
{
    const std::string fullPath = (fs::path(apkRootPath) / fileName).string();
    const std::string cachePath = (fs::path(tmpDir) / cacheFileName).string();

    if (isRemote(fullPath)) {
        fs::create_directories(tmpDir);
        auto &dl = Downloader::get();
        dl.downloadFile(fullPath, cachePath);
        return cachePath;
    } else {
        if (fs::exists(fullPath))
            return fullPath;
        else
            throw std::runtime_error(std::format("File '{}' does not exist.", fullPath));
    }
}

} // namespace ASGenerator
