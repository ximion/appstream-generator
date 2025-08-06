/*
 * Copyright (C) 2016-2022 Matthias Klumpp <matthias@tenstral.net>
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
#include <optional>
#include <format>
#include <compare>
#include <filesystem>
#include <appstream.h>

#include "downloader.h"

namespace ASGenerator
{

inline constexpr std::size_t GENERIC_BUFFER_SIZE = 8192;
namespace fs = std::filesystem;

/**
 * Structure representing image dimensions and scale factor.
 */
struct ImageSize {
    uint32_t width;
    uint32_t height;
    uint32_t scale;

    /**
     * Constructor with width, height, and scale.
     */
    constexpr ImageSize(std::uint32_t w, std::uint32_t h, std::uint32_t s)
        : width(w),
          height(h),
          scale(s)
    {
    }

    /**
     * Constructor with width and height (scale = 1).
     */
    constexpr ImageSize(std::uint32_t w, std::uint32_t h)
        : width(w),
          height(h),
          scale(1)
    {
    }

    /**
     * Constructor with size (square image, scale = 1).
     */
    explicit constexpr ImageSize(std::uint32_t s)
        : width(s),
          height(s),
          scale(1)
    {
    }

    /**
     * Constructor with size (square image, scale = 1).
     */
    explicit constexpr ImageSize()
        : width(0),
          height(0),
          scale(1)
    {
    }

    /**
     * Constructor from string representation (e.g., "64x64" or "64x64@2").
     */
    explicit ImageSize(const std::string &str);

    /**
     * Convert to string representation.
     */
    std::string toString() const;

    /**
     * Convert to integer (larger dimension * scale).
     */
    std::uint32_t toInt() const;

    /**
     * Three-way comparison operator for natural sorting.
     * Compares width first, then scale if widths are equal.
     */
    // clang-format off
    std::strong_ordering operator<=> (const ImageSize &other) const
    {
        if (auto cmp = width <=> other.width; cmp != 0)
            return cmp;
        return scale <=> other.scale;
    }

    /**
     * Equality comparison operator.
     */
    bool operator==(const ImageSize &other) const = default;
    // clang-format on
};

/**
 * Generate a random alphanumeric string.
 */
std::string randomString(std::uint32_t len);

/**
 * Check if the locale is a valid locale which we want to include
 * in the resulting metadata. Some locales added just for testing
 * by upstreams should be filtered out.
 */
bool localeValid(const std::string &locale);

/**
 * Check if the given string is a top-level domain name.
 * The TLD list of AppStream is incomplete, but it will
 * cover 99% of all cases.
 * (in a short check on Debian, it covered all TLDs in use there)
 */
bool isTopLevelDomain(const std::string &value);

/**
 * Get the component-id back from a global component-id.
 */
std::optional<std::string> getCidFromGlobalID(const std::string &gcid);

/**
 * Create a hard link between two files.
 */
void hardlink(const std::string &srcFname, const std::string &destFname);

/**
 * Copy a directory using multiple threads.
 * This function follows symbolic links,
 * and replaces them with actual directories
 * in destDir.
 *
 * @param srcDir Source directory to copy.
 * @param destDir Path to the destination directory.
 * @param useHardlinks Use hardlinks instead of copying files.
 */
void copyDir(const std::string &srcDir, const std::string &destDir, bool useHardlinks = false);

std::string getExecutableDir();

/**
 * Get full path for an AppStream generator data file.
 */
std::string getDataPath(const std::string &fname);

/**
 * Check if a path exists and is a directory.
 */
bool existsAndIsDir(const std::string &path);

/**
 * Convert a string array into a byte array.
 */
std::vector<std::uint8_t> stringArrayToByteArray(const std::vector<std::string> &strArray);

/**
 * Check if string contains a remote URI.
 */
bool isRemote(const std::string &uri);

/**
 * Download or open `path` and return it as a string array.
 *
 * @param path The path to access.
 * @param maxTryCount Maximum number of retry attempts.
 * @param downloader Downloader instance (can be null).
 * @return The data if successful.
 */
std::vector<std::string> getTextFileContents(
    const std::string &path,
    std::uint32_t maxTryCount = 4,
    Downloader *downloader = nullptr);

/**
 * Download or open `path` and return it as a byte array.
 *
 * @param path The path to access.
 * @param maxTryCount Maximum number of retry attempts.
 * @param downloader Downloader instance (can be null).
 * @return The data if successful.
 */
std::vector<std::uint8_t> getFileContents(
    const std::string &path,
    std::uint32_t maxTryCount = 4,
    Downloader *downloader = nullptr);

/**
 * Get path of the directory with test samples.
 */
fs::path getTestSamplesDir();

/**
 * Return a suitable, "raw" icon name (either a stock icon name or local icon)
 * for this component that can be processed further by the generator.
 * Return null if this component does not have a suitable icon.
 */
std::optional<AsIcon *> componentGetRawIcon(AsComponent *cpt);

/**
 * Extract filename from URI, removing query parameters and fragments.
 */
std::string filenameFromURI(const std::string &uri);

/**
 * Convert a string to lowercase.
 *
 * @param s The string to convert to lowercase.
 */
std::string toLower(const std::string &s);

} // namespace ASGenerator
