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

#include "zarchive.h"

#include <archive.h>
#include <archive_entry.h>
#include <stdexcept>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <regex>
#include <vector>
#include <string>
#include <optional>
#include <chrono>
#include <format>
#include <sys/stat.h>

#include "utils.h"
#include "logging.h"

namespace ASGenerator
{

constexpr size_t DEFAULT_BLOCK_SIZE = 65536;
using ArchivePtr = std::unique_ptr<archive, decltype(&archive_read_free)>;

static std::string getArchiveErrorMessage(archive *ar)
{
    const char *err = archive_error_string(ar);
    return err ? std::string(err) : std::string();
}

static std::string readArchiveData(archive *ar, const std::string &name = "")
{
    archive_entry *ae = nullptr;
    int ret;
    std::vector<char> buffer(GENERIC_BUFFER_SIZE);
    std::string data;

    ret = archive_read_next_header(ar, &ae);
    if (ret == ARCHIVE_EOF)
        return data;

    if (ret != ARCHIVE_OK) {
        if (name.empty())
            throw std::runtime_error(
                std::format("Unable to read header of compressed data: {}", getArchiveErrorMessage(ar)));
        else
            throw std::runtime_error(
                std::format("Unable to read header of compressed file '{}': {}", name, getArchiveErrorMessage(ar)));
    }

    while (true) {
        const ssize_t size = archive_read_data(ar, buffer.data(), buffer.size());
        if (size < 0) {
            if (name.empty())
                throw std::runtime_error(std::format("Failed to read compressed data: {}", getArchiveErrorMessage(ar)));
            else
                throw std::runtime_error(
                    std::format("Failed to read data from '{}': {}", name, getArchiveErrorMessage(ar)));
        }

        if (size == 0)
            break;

        data.append(buffer.data(), size);
    }

    return data;
}

std::string decompressFile(const std::string &fname)
{
    ArchivePtr ar(archive_read_new(), archive_read_free);
    if (!ar)
        throw std::runtime_error("Failed to create archive object");

    archive_read_support_format_raw(ar.get());
    archive_read_support_format_empty(ar.get());
    archive_read_support_filter_all(ar.get());
    int ret = archive_read_open_filename(ar.get(), fname.c_str(), DEFAULT_BLOCK_SIZE);
    if (ret != ARCHIVE_OK) {
        int ret_errno = archive_errno(ar.get());
        throw std::runtime_error(std::format(
            "Unable to open compressed file '{}': {}. error: {}",
            fname,
            getArchiveErrorMessage(ar.get()),
            std::strerror(ret_errno)));
    }

    return readArchiveData(ar.get(), fname);
}

std::string decompressData(const std::vector<uint8_t> &data)
{
    ArchivePtr ar(archive_read_new(), archive_read_free);
    if (!ar)
        throw std::runtime_error("Failed to create archive object");

    archive_read_support_filter_all(ar.get());
    archive_read_support_format_empty(ar.get());
    archive_read_support_format_raw(ar.get());

    int ret = archive_read_open_memory(ar.get(), (void *)data.data(), data.size());
    if (ret != ARCHIVE_OK)
        throw std::runtime_error(std::format("Unable to open compressed data: {}", getArchiveErrorMessage(ar.get())));

    return readArchiveData(ar.get());
}

void ArchiveDecompressor::open(const std::string &fname)
{
    archive_fname = fname;
}

bool ArchiveDecompressor::isOpen() const
{
    return !archive_fname.empty();
}

void ArchiveDecompressor::close()
{
    archive_fname.clear();
}

bool ArchiveDecompressor::pathMatches(const std::string &path1, const std::string &path2) const
{
    if (path1 == path2)
        return true;

    auto abs1 = fs::weakly_canonical(fs::path("/") / path1);
    auto abs2 = fs::weakly_canonical(fs::path("/") / path2);

    return abs1 == abs2;
}

std::vector<uint8_t> ArchiveDecompressor::readEntry(archive *ar)
{
    const void *buff = nullptr;
    size_t size = 0;
    int64_t offset = 0;
    std::vector<uint8_t> result;

    while (archive_read_data_block(ar, &buff, &size, &offset) == ARCHIVE_OK) {
        const auto ptr = static_cast<const uint8_t *>(buff);
        result.insert(result.end(), ptr, ptr + size);
    }

    return result;
}

void ArchiveDecompressor::extractEntryTo(archive *ar, const std::string &fname)
{
    const void *buff = nullptr;
    size_t size = 0;
    int64_t offset = 0;
    int64_t output_offset = 0;

    std::ofstream f(fname, std::ios::binary);
    if (!f)
        throw std::runtime_error(std::format("Failed to open file for writing: {}", fname));

    while (archive_read_data_block(ar, &buff, &size, &offset) == ARCHIVE_OK) {
        if (offset > output_offset) {
            f.seekp(offset - output_offset, std::ios::cur);
            output_offset = offset;
        }

        while (size > 0) {
            auto bytes_to_write = size;
            if (bytes_to_write > DEFAULT_BLOCK_SIZE)
                bytes_to_write = DEFAULT_BLOCK_SIZE;

            f.write(static_cast<const char *>(buff), bytes_to_write);
            output_offset += bytes_to_write;
            if (bytes_to_write > size)
                break;
            size -= bytes_to_write;
        }
    }
}

archive *ArchiveDecompressor::openArchive()
{
    archive *ar = archive_read_new();

    archive_read_support_filter_all(ar);
    archive_read_support_format_all(ar);

    int ret = archive_read_open_filename(ar, archive_fname.c_str(), DEFAULT_BLOCK_SIZE);
    if (ret != ARCHIVE_OK) {
        int ret_errno = archive_errno(ar);
        throw std::runtime_error(std::format(
            "Unable to open compressed file '{}': {}. error: {}",
            archive_fname,
            getArchiveErrorMessage(ar),
            std::strerror(ret_errno)));
    }

    return ar;
}

bool ArchiveDecompressor::extractFileTo(const std::string &fname, const std::string &fdest)
{
    archive_entry *en = nullptr;
    ArchivePtr ar(openArchive(), archive_read_free);

    while (archive_read_next_header(ar.get(), &en) == ARCHIVE_OK) {
        std::string pathname = archive_entry_pathname(en);

        if (pathMatches(fname, pathname)) {
            extractEntryTo(ar.get(), fdest);
            return true;
        } else {
            archive_read_data_skip(ar.get());
        }
    }

    return false;
}

void ArchiveDecompressor::extractArchive(const std::string &dest)
{
    if (!fs::is_directory(dest))
        throw std::runtime_error(std::format("Destination is not a directory: {}", dest));

    archive_entry *en = nullptr;
    ArchivePtr ar(openArchive(), archive_read_free);

    while (archive_read_next_header(ar.get(), &en) == ARCHIVE_OK) {
        std::string pathname = fs::path(dest) / archive_entry_pathname(en);

        /* at the moment we only handle directories and files */
        auto filetype = archive_entry_filetype(en);
        if (filetype == AE_IFDIR) {
            if (!fs::exists(pathname))
                fs::create_directory(pathname);
            continue;
        }

        if (filetype == AE_IFREG) {
            extractEntryTo(ar.get(), pathname);
        }
    }
}

std::vector<uint8_t> ArchiveDecompressor::readData(const std::string &fname)
{
    archive_entry *en = nullptr;
    ArchivePtr ar(openArchive(), archive_read_free);

    while (archive_read_next_header(ar.get(), &en) == ARCHIVE_OK) {
        std::string pathname = archive_entry_pathname(en);

        if (pathMatches(fname, pathname)) {
            auto filetype = archive_entry_filetype(en);
            if (filetype == AE_IFDIR) {
                /* we don't extract directories explicitly */
                throw std::runtime_error(std::format("Path '{}' is a directory and can not be extracted.", fname));
            }

            /* check if we are dealing with a symlink */
            if (filetype == AE_IFLNK) {
                // Symlink: try to resolve and read target
                const char *linkTarget = archive_entry_symlink(en);
                if (!linkTarget)
                    throw std::runtime_error(
                        std::format("Unable to read destination of symbolic link for '{}' .", fname));

                std::string linkTargetStr(linkTarget);
                if (!fs::path(linkTargetStr).is_absolute())
                    linkTargetStr = (fs::path(fname).parent_path() / linkTargetStr).string();

                try {
                    return readData(linkTargetStr);
                } catch (const std::exception &e) {
                    logError("Unable to read destination data of symlink in archive: {}", e.what());
                    return {};
                }
            }

            if (filetype != AE_IFREG) {
                // we really don't want to extract special files from a tarball - usually, those shouldn't
                // be present anyway.
                // This should probably be an error, but return nothing for now.
                logError("Tried to extract non-regular file '{}' from the archive", fname);
                return {};
            }

            return readEntry(ar.get());

        } else {
            archive_read_data_skip(ar.get());
        }
    }

    throw std::runtime_error(std::format("File '{}' was not found in the archive.", fname));
}

std::vector<std::string> ArchiveDecompressor::extractFilesByRegex(const std::regex &re, const std::string &destdir)
{
    archive_entry *en = nullptr;
    std::vector<std::string> matches;
    ArchivePtr ar(openArchive(), archive_read_free);

    while (archive_read_next_header(ar.get(), &en) == ARCHIVE_OK) {
        std::string pathname = archive_entry_pathname(en);
        if (std::regex_search(pathname, re)) {
            std::string fdest = (fs::path(destdir) / fs::path(pathname).filename()).string();
            extractEntryTo(ar.get(), fdest);
            matches.push_back(fdest);
        } else {
            archive_read_data_skip(ar.get());
        }
    }

    return matches;
}

std::vector<std::string> ArchiveDecompressor::readContents()
{
    archive_entry *en = nullptr;
    std::vector<std::string> contents;
    ArchivePtr ar(openArchive(), archive_read_free);

    while (archive_read_next_header(ar.get(), &en) == ARCHIVE_OK) {
        std::string pathname = archive_entry_pathname(en);

        // ignore directories
        if (!pathname.empty() && pathname.back() == '/')
            continue;

        contents.push_back(fs::weakly_canonical(fs::path("/") / pathname).string());
    }

    return contents;
}

/**
 * Returns a generator to iterate over the contents of this tarball.
 */
std::generator<ArchiveDecompressor::ArchiveEntry> ArchiveDecompressor::read()
{
    archive_entry *en = nullptr;
    ArchivePtr ar(openArchive(), archive_read_free);

    while (archive_read_next_header(ar.get(), &en) == ARCHIVE_OK) {
        std::string pathname = archive_entry_pathname(en);

        // ignore directories
        if (!pathname.empty() && pathname.back() == '/')
            continue;

        ArchiveEntry entry;
        entry.fname = fs::weakly_canonical(fs::path("/") / pathname).string();
        auto filetype = archive_entry_filetype(en);

        // check if we are dealing with a symlink
        if (filetype == AE_IFLNK) {
            const char *linkTarget = archive_entry_symlink(en);
            if (linkTarget == nullptr)
                throw std::runtime_error(
                    std::format("Unable to read destination of symbolic link for '{}'.", entry.fname));

            // we cheat here and set the link target as data
            // TODO: Proper handling of symlinks, e.g. by adding a filetype property to ArchiveEntry.
            entry.data = std::vector<uint8_t>(linkTarget, linkTarget + std::strlen(linkTarget));
            co_yield entry;
            continue;
        }

        if (filetype != AE_IFREG) {
            co_yield entry;
            continue;
        }

        entry.data = readEntry(ar.get());
        co_yield entry;
    }
}

/**
 * Save data to a compressed file.
 *
 * Params:
 *      data = The data to save.
 *      fname = The filename the data should be saved to.
 *      atype = The archive type (GZ or XZ).
 */
void compressAndSave(const std::vector<uint8_t> &data, const std::string &fname, ArchiveType atype)
{
    ArchivePtr ar(archive_write_new(), archive_write_free);

    archive_write_set_format_raw(ar.get());
    if (atype == ArchiveType::GZIP) {
        archive_write_add_filter_gzip(ar.get());
        archive_write_set_filter_option(ar.get(), "gzip", "timestamp", nullptr);
    } else {
        archive_write_add_filter_xz(ar.get());
    }

    // don't write to the new file directly, we create a temporary file and
    // rename it when we successfully saved the data.
    std::string tmpFname = std::format("{}.new", fname);

    int ret = archive_write_open_filename(ar.get(), tmpFname.c_str());
    if (ret != ARCHIVE_OK)
        throw std::runtime_error(
            std::format("Unable to open file '{}' : {}", tmpFname, getArchiveErrorMessage(ar.get())));

    std::unique_ptr<archive_entry, decltype(&archive_entry_free)> entry(archive_entry_new(), archive_entry_free);

    archive_entry_set_filetype(entry.get(), AE_IFREG);
    archive_entry_set_size(entry.get(), data.size());
    archive_write_header(ar.get(), entry.get());
    archive_write_data(ar.get(), data.data(), data.size());
    archive_write_close(ar.get());

    // delete old file if it exists
    if (fs::exists(fname))
        fs::remove(fname);

    // rename temporary file to actual file
    fs::rename(tmpFname, fname);
}

ArchiveCompressor::ArchiveCompressor(ArchiveType type)
{
    ar = archive_write_new();

    if (type == ArchiveType::GZIP) {
        archive_write_add_filter_gzip(ar);
        archive_write_set_filter_option(ar, "gzip", "timestamp", nullptr);
    } else {
        archive_write_add_filter_xz(ar);
    }

    archive_write_set_format_pax_restricted(ar);
    closed = true;
}

ArchiveCompressor::~ArchiveCompressor()
{
    close();
    if (ar)
        archive_write_free(ar);
}

void ArchiveCompressor::open(const std::string &fname)
{
    archiveFname = fname;
    int ret = archive_write_open_filename(ar, fname.c_str());
    if (ret != ARCHIVE_OK)
        throw std::runtime_error(std::format("Unable to open file '{}' : {}", fname, getArchiveErrorMessage(ar)));
    closed = false;
}

bool ArchiveCompressor::isOpen() const
{
    return !closed;
}

void ArchiveCompressor::close()
{
    if (closed)
        return;
    archive_write_close(ar);
    closed = true;
}

void ArchiveCompressor::addFile(const std::string &fname, const std::optional<std::string> &dest)
{
    if (!fs::exists(fname))
        throw std::runtime_error(std::format("File does not exist: {}", fname));

    std::unique_ptr<archive_entry, decltype(&archive_entry_free)> entry(archive_entry_new(), archive_entry_free);
    std::string destName = dest ? *dest : fs::path(fname).filename().string();

    struct stat st;
    lstat(fname.c_str(), &st);

    archive_entry_set_pathname(entry.get(), destName.c_str());
    archive_entry_set_size(entry.get(), st.st_size);
    archive_entry_set_filetype(entry.get(), S_IFREG);
    archive_entry_set_perm(entry.get(), 0755);
    archive_entry_set_mtime(entry.get(), st.st_mtime, 0);

    {
        std::lock_guard<std::mutex> lock(m_mutex);
        std::ifstream f(fname, std::ios::binary);
        if (!f)
            throw std::runtime_error(std::format("Failed to open file for reading: {}", fname));
        archive_write_header(ar, entry.get());
        std::vector<char> buff(GENERIC_BUFFER_SIZE);
        while (f) {
            f.read(buff.data(), buff.size());
            std::streamsize n = f.gcount();
            if (n > 0)
                archive_write_data(ar, buff.data(), n);
        }
    }
}

} // namespace ASGenerator
