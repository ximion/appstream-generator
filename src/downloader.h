/*
 * Copyright (C) 2019-2025 Matthias Klumpp <matthias@tenstral.net>
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
#include <chrono>
#include <cstdint>

namespace ASGenerator
{

class DownloadException : public std::exception
{
public:
    explicit DownloadException(const std::string &message);
    const char *what() const noexcept override;

private:
    std::string m_message;
};

/**
 * Download data via HTTP. Based on cURL.
 */
class Downloader
{
public:
    /**
     * Get thread-local singleton instance
     */
    static Downloader &get();

    Downloader();

    /**
     * Download to file stream and return last-modified time if available
     */
    std::optional<std::chrono::system_clock::time_point> download(
        const std::string &url,
        std::ofstream &dFile,
        std::uint32_t maxTryCount = 4);

    /**
     * Download to memory and return data as byte vector
     */
    std::vector<std::uint8_t> download(const std::string &url, std::uint32_t maxTryCount = 4);

    /**
     * Download `url` to `dest`.
     *
     * Params:
     *      url = The URL to download.
     *      dest = The location for the downloaded file.
     *      maxTryCount = Number of times to attempt the download.
     */
    void downloadFile(const std::string &url, const std::string &dest, std::uint32_t maxTryCount = 4);

    /**
     * Download `url` and return a string with its contents.
     *
     * Params:
     *      url = The URL to download.
     *      maxTryCount = Number of times to retry on timeout.
     */
    std::string downloadText(const std::string &url, std::uint32_t maxTryCount = 4);

    /**
     * Download `url` and return a string array of lines.
     *
     * Params:
     *      url = The URL to download.
     *      maxTryCount = Number of times to retry on timeout.
     */
    std::vector<std::string> downloadTextLines(const std::string &url, std::uint32_t maxTryCount = 4);

private:
    const std::string userAgent;
    const std::string caInfo;

    // thread local instance
    static thread_local std::unique_ptr<Downloader> instance_;

    std::optional<std::chrono::system_clock::time_point> downloadInternal(
        const std::string &url,
        std::ofstream &dest,
        std::uint32_t maxTryCount = 5);
};

} // namespace ASGenerator
