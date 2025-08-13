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

namespace fs = std::filesystem;

enum class ArchiveType {
    GZIP,
    XZ,
    ZSTD
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
    ~ArchiveDecompressor();
    void open(const std::string &fname, const fs::path &tmpDir = fs::path());
    bool isOpen() const;
    void close();

    /**
     * If this is set to true, and the archive is large, it will be extracted to a
     * temporary location and entries read from there. This avoids repeatedly
     * seeking through the archive to extract data if readData() and extractFileTo()
     * are used a lot. Repeated seeking is slower than temporary extraction.
     *
     * @param enable Enable or disable optimization for repeated reads.
     */
    void setOptimizeRepeatedReads(bool enable);

    bool extractFileTo(const std::string &fname, const std::string &fdest);
    void extractArchive(const std::string &dest);
    std::vector<uint8_t> readData(const std::string &fname);
    std::vector<std::string> extractFilesByRegex(const std::regex &re, const std::string &destdir);
    std::vector<std::string> readContents();
    std::generator<ArchiveEntry> read();

private:
    std::string m_archiveFname;
    fs::path m_tmpDir;
    bool m_canExtractToTmp = false;
    bool m_tmpDirOwned = false;
    bool m_optimizeRepeatedReads = false;
    bool m_isExtractedToTmp = false;

    bool pathMatches(const std::string &path1, const std::string &path2) const;
    std::vector<uint8_t> readEntry(struct archive *ar);
    void extractEntryTo(struct archive *ar, const std::string &fname);
    struct archive *openArchive();
    bool tmpExtractIfPossible();
    void cleanupTempDirectory();
    size_t getArchiveSize() const;
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
