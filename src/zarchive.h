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
#include <filesystem>
#include <optional>
#include <regex>
#include <mutex>
#include <generator>

struct archive;

namespace ASGenerator
{

enum class ArchiveType {
    GZIP,
    XZ
};

std::string decompressFile(const std::string &fname);
std::string decompressData(const std::vector<uint8_t> &data);

class ArchiveDecompressor
{
public:
    struct ArchiveEntry {
        std::string fname;
        std::vector<uint8_t> data;
    };

    ArchiveDecompressor() = default;
    void open(const std::string &fname);
    bool isOpen() const;
    void close();
    bool extractFileTo(const std::string &fname, const std::string &fdest);
    void extractArchive(const std::string &dest);
    std::vector<uint8_t> readData(const std::string &fname);
    std::vector<std::string> extractFilesByRegex(const std::regex &re, const std::string &destdir);
    std::vector<std::string> readContents();
    std::generator<ArchiveEntry> read();

private:
    std::string archive_fname;
    bool pathMatches(const std::string &path1, const std::string &path2) const;
    std::vector<uint8_t> readEntry(struct archive *ar);
    void extractEntryTo(struct archive *ar, const std::string &fname);
    struct archive *openArchive();
};

void compressAndSave(const std::vector<uint8_t> &data, const std::string &fname, ArchiveType atype);

class ArchiveCompressor
{
public:
    explicit ArchiveCompressor(ArchiveType type);
    ~ArchiveCompressor();
    void open(const std::string &fname);
    bool isOpen() const;
    void close();
    void addFile(const std::string &fname, const std::optional<std::string> &dest = std::nullopt);

private:
    std::string archiveFname;
    struct archive *ar = nullptr;
    bool closed = true;
    std::mutex m_mutex;
};

} // namespace ASGenerator
