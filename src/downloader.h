/*
 * Copyright (C) 2019-2026 Matthias Klumpp <matthias@tenstral.net>
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

#include "logging.h"

namespace ASGenerator
{

/**
 * Where a download puts the bytes it receives. Defined in the implementation.
 */
struct WriteCallbackData;

class DownloadException : public std::exception
{
public:
    /**
     * @param message   Description of the failure.
     * @param permanent Whether the failure is a definitive answer from the remote end (such as
     *                  an HTTP 404) that will not change if the download is attempted again.
     */
    explicit DownloadException(const std::string &message, bool permanent = false);
    const char *what() const noexcept override;

    /**
     * True if retrying this download can not succeed, so no further attempts should be made.
     */
    [[nodiscard]] bool isPermanent() const noexcept;

private:
    std::string m_message;
    bool m_permanent;
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
     * Download to file stream and return last-modified time if available.
     * `maxTryCount` is the number of times the download is attempted.
     */
    std::optional<std::chrono::system_clock::time_point> download(
        const std::string &url,
        std::ofstream &dFile,
        std::uint32_t maxTryCount = 4);

    /**
     * Download to memory and return data as byte vector.
     * `maxTryCount` is the number of times the download is attempted.
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
     *      maxTryCount = Number of times to attempt the download.
     */
    std::string downloadText(const std::string &url, std::uint32_t maxTryCount = 4);

    /**
     * Download `url` and return a string array of lines.
     *
     * Params:
     *      url = The URL to download.
     *      maxTryCount = Number of times to attempt the download.
     */
    std::vector<std::string> downloadTextLines(const std::string &url, std::uint32_t maxTryCount = 4);

private:
    quill::Logger *m_log;
    const std::string userAgent;
    const std::string caInfo;

    // thread local instance
    static thread_local std::unique_ptr<Downloader> instance_;

    /**
     * Run a single download attempt, throwing DownloadException if it did not succeed.
     */
    std::optional<std::chrono::system_clock::time_point> performDownload(
        const std::string &url,
        WriteCallbackData &writeData);

    /**
     * Download `url` into the sink described by `writeData`, retrying with an increasing
     * delay between attempts. `maxTryCount` is the total number of attempts made.
     * Failures which are permanent (see DownloadException::isPermanent) are not retried.
     */
    std::optional<std::chrono::system_clock::time_point> downloadWithRetry(
        const std::string &url,
        WriteCallbackData &writeData,
        std::uint32_t maxTryCount);
};

} // namespace ASGenerator
