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

#include "downloader.h"

#include <algorithm>
#include <format>
#include <filesystem>
#include <sstream>
#include <fstream>
#include <memory>
#include <curl/curl.h>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <thread>
#include <fcntl.h>
#include <sys/stat.h>

#include "defines.h"
#include "config.h"
#include "logging.h"
#include "utils.h"

namespace ASGenerator
{

// Thread-local instance
thread_local std::unique_ptr<Downloader> Downloader::instance_;

DownloadException::DownloadException(const std::string &message, bool permanent)
    : m_message(message),
      m_permanent(permanent)
{
}

const char *DownloadException::what() const noexcept
{
    return m_message.c_str();
}

bool DownloadException::isPermanent() const noexcept
{
    return m_permanent;
}

struct WriteCallbackData {
    std::ofstream *file;
    std::vector<std::uint8_t> *buffer;
};

struct CurlDeleter {
    void operator()(CURL *handle) const noexcept
    {
        curl_easy_cleanup(handle);
    }
};
using CurlHandle = std::unique_ptr<CURL, CurlDeleter>;

/* We deliberately do not set CURLOPT_TIMEOUT: it limits the total duration of a transfer,
 * so a package fetched while many other downloads share the same link may get aborted even
 * though the connection is perfectly healthy. Detect transfers that have actually stalled
 * instead, and let slow ones run to completion. */
constexpr long CurlConnectTimeoutSec = 30;    // seconds spent waiting for the connection
constexpr long CurlLowSpeedLimitBytesS = 100; // bytes/s below which a transfer counts as stalled
constexpr long CurlLowSpeedTimeSec = 120;     // seconds it may stay below that before we give up

// How long to wait before retrying a failed download. Doubles with every attempt, so that a
// remote end which is briefly overloaded is not immediately hit with the next request.
constexpr auto RetryBackoffBase = std::chrono::seconds(1);
constexpr auto RetryBackoffMax = std::chrono::seconds(30);

/**
 * Discard whatever a failed attempt has already written, so a retry starts from a clean sink.
 */
static void resetWriteSink(WriteCallbackData &writeData)
{
    if (writeData.file) {
        // a failed write leaves the stream in an error state, in which seeking is ignored
        writeData.file->clear();
        writeData.file->seekp(0);
    }
    if (writeData.buffer)
        writeData.buffer->clear();
}

// Callback function for writing data to file or buffer
static size_t writeCallback(void *contents, size_t size, size_t nmemb, void *userData)
{
    size_t totalSize = size * nmemb;
    WriteCallbackData *data = static_cast<WriteCallbackData *>(userData);

    if (data->file && data->file->is_open()) {
        data->file->write(static_cast<const char *>(contents), totalSize);
        return data->file->good() ? totalSize : 0;
    } else if (data->buffer) {
        const auto *bytes = static_cast<const std::uint8_t *>(contents);
        data->buffer->insert(data->buffer->end(), bytes, bytes + totalSize);
        return totalSize;
    }

    return 0;
}

// Callback function for header processing
struct HeaderCallbackData {
    bool httpsUrl;
    std::optional<std::chrono::system_clock::time_point> *lastModified;

    /* Set when a header makes us abort the transfer (Exceptions must not propagate through
     * curl's C frames, so the callback records the problem here) */
    std::optional<std::string> error;
};

static size_t headerCallback(char *buffer, size_t size, size_t nitems, void *userData)
{
    size_t totalSize = size * nitems;
    HeaderCallbackData *data = static_cast<HeaderCallbackData *>(userData);

    std::string header(buffer, totalSize);
    std::transform(header.begin(), header.end(), header.begin(), ::tolower);

    // Check for HTTPS -> HTTP downgrade
    if (data->httpsUrl && header.starts_with("location:")) {
        auto pos = header.find("http:");
        if (pos != std::string::npos) {
            data->error = "HTTPS URL tried to redirect to a less secure HTTP URL.";
            return 0; // makes curl abort the transfer
        }
    }

    // Parse Last-Modified header
    if (header.starts_with("last-modified:")) {
        auto colonPos = header.find(':');
        if (colonPos != std::string::npos) {
            std::string dateStr = header.substr(colonPos + 1);
            // Trim whitespace
            dateStr.erase(0, dateStr.find_first_not_of(" \t"));
            dateStr.erase(dateStr.find_last_not_of(" \t\r\n") + 1);

            // Parse RFC822 date format using strptime. HTTP dates are always GMT
            // (RFC 9110 §5.6.7) and strptime does not apply the parsed zone, so this
            // has to be converted with timegm().
            std::tm tm = {};
            if (strptime(dateStr.c_str(), "%a, %d %b %Y %H:%M:%S %Z", &tm)) {
                auto timeT = timegm(&tm);
                if (timeT != -1) {
                    *(data->lastModified) = std::chrono::system_clock::from_time_t(timeT);
                }
            }
        }
    }

    return totalSize;
}

Downloader &Downloader::get()
{
    if (!instance_)
        instance_ = std::make_unique<Downloader>();
    return *instance_;
}

Downloader::Downloader()
    : m_log(getLogger("downloader")),
      userAgent(ASGEN_USER_AGENT),
      caInfo(Config::get().caInfo)
{
    // Initialize curl globally (should be done once per process)
    static bool curlInitialized = false;
    if (!curlInitialized) {
        curl_global_init(CURL_GLOBAL_DEFAULT);
        curlInitialized = true;
    }
}

std::optional<std::chrono::system_clock::time_point> Downloader::performDownload(
    const std::string &url,
    WriteCallbackData &writeData)
{
    std::optional<std::chrono::system_clock::time_point> lastModified;

    CurlHandle curl{curl_easy_init()};
    if (!curl)
        throw DownloadException("Failed to initialize curl");

    HeaderCallbackData headerData{url.starts_with("https"), &lastModified};

    curl_easy_setopt(curl.get(), CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl.get(), CURLOPT_WRITEFUNCTION, writeCallback);
    curl_easy_setopt(curl.get(), CURLOPT_WRITEDATA, &writeData);
    curl_easy_setopt(curl.get(), CURLOPT_HEADERFUNCTION, headerCallback);
    curl_easy_setopt(curl.get(), CURLOPT_HEADERDATA, &headerData);
    curl_easy_setopt(curl.get(), CURLOPT_USERAGENT, userAgent.c_str());
    curl_easy_setopt(curl.get(), CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl.get(), CURLOPT_CONNECTTIMEOUT, CurlConnectTimeoutSec);
    curl_easy_setopt(curl.get(), CURLOPT_LOW_SPEED_LIMIT, CurlLowSpeedLimitBytesS);
    curl_easy_setopt(curl.get(), CURLOPT_LOW_SPEED_TIME, CurlLowSpeedTimeSec);

    if (!caInfo.empty())
        curl_easy_setopt(curl.get(), CURLOPT_CAINFO, caInfo.c_str());

    const CURLcode res = curl_easy_perform(curl.get());
    if (headerData.error)
        throw DownloadException(*headerData.error, /* permanent */ true);
    if (res != CURLE_OK)
        throw DownloadException(std::format("curl_easy_perform() failed: {}", curl_easy_strerror(res)));

    long responseCode;
    curl_easy_getinfo(curl.get(), CURLINFO_RESPONSE_CODE, &responseCode);

    if (responseCode != 200 && responseCode != 301 && responseCode != 302) {
        if (responseCode == 0) {
            // just to be safe, check whether we received data before assuming everything went fine
            const bool gotData = writeData.file ? writeData.file->tellp() > 0
                                                : (writeData.buffer && !writeData.buffer->empty());
            if (!gotData)
                throw DownloadException(
                    std::format("No data was received from the remote end (Code: {}).", responseCode));
        } else {
            // A server error or an explicit request to slow down may well clear up by the next
            // attempt. Any other status (most importantly 404) is the remote end's final word,
            // and repeating the request would only delay callers that probe for optional files.
            const bool transient = responseCode == 429 || responseCode >= 500;
            throw DownloadException(std::format("HTTP request returned status code {}", responseCode), !transient);
        }
    }

    return lastModified;
}

std::optional<std::chrono::system_clock::time_point> Downloader::downloadWithRetry(
    const std::string &url,
    WriteCallbackData &writeData,
    std::uint32_t maxTryCount)
{
    if (!Utils::isRemote(url))
        throw DownloadException("URL is not remote");

    LOG_DEBUG(m_log, "Downloading {}", url);

    const std::uint32_t attempts = std::max<std::uint32_t>(maxTryCount, 1);
    auto backoff = RetryBackoffBase;

    for (std::uint32_t attempt = 1;; ++attempt) {
        std::string error;
        try {
            auto lastModified = performDownload(url, writeData);
            LOG_DEBUG(m_log, "Downloaded {}", url);
            return lastModified;
        } catch (const DownloadException &e) {
            // the remote end gave a definitive answer, asking again will not change it
            if (e.isPermanent())
                throw;
            error = e.what();
        } catch (const std::exception &e) {
            error = e.what();
        }

        if (attempt >= attempts)
            throw DownloadException(attempts > 1 ? std::format("{} (after {} attempts)", error, attempts) : error);

        LOG_DEBUG(
            m_log,
            "Failed to download {}: {} - retrying in {}s ({} {} left)",
            url,
            error,
            backoff.count(),
            attempts - attempt,
            attempts - attempt > 1 ? "attempts" : "attempt");

        resetWriteSink(writeData);
        std::this_thread::sleep_for(backoff);
        backoff = std::min(backoff * 2, RetryBackoffMax);
    }
}

std::optional<std::chrono::system_clock::time_point> Downloader::download(
    const std::string &url,
    std::ofstream &dFile,
    std::uint32_t maxTryCount)
{
    WriteCallbackData writeData{&dFile, nullptr};
    return downloadWithRetry(url, writeData, maxTryCount);
}

std::vector<std::uint8_t> Downloader::download(const std::string &url, std::uint32_t maxTryCount)
{
    std::vector<std::uint8_t> buffer;
    WriteCallbackData writeData{nullptr, &buffer};
    downloadWithRetry(url, writeData, maxTryCount);

    return buffer;
}

void Downloader::downloadFile(const std::string &url, const std::string &dest, std::uint32_t maxTryCount)
{
    if (!Utils::isRemote(url))
        throw DownloadException("URL is not remote");

    if (fs::exists(dest)) {
        LOG_DEBUG(m_log, "File '{}' already exists, re-download of '{}' skipped.", dest, url);
        return;
    }

    fs::create_directories(fs::path(dest).parent_path());

    std::ofstream file(dest, std::ios::binary);
    if (!file.is_open())
        throw DownloadException(std::format("Failed to open destination file: {}", dest));

    try {
        auto lastModified = download(url, file, maxTryCount);

        // A retried download restarts at offset zero, but a shorter response would leave the
        // tail of the previous attempt behind it, so cut the file down to what we just wrote.
        const auto written = file.tellp();
        file.close();
        if (written >= 0)
            fs::resize_file(dest, static_cast<std::uintmax_t>(written));

        if (lastModified) {
            // Set file times if we have last-modified information
            auto timeT = std::chrono::system_clock::to_time_t(*lastModified);
            auto currentTime = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());

            // Set access and modification times of the source
            struct timespec times[2];
            times[0].tv_sec = currentTime; // access time
            times[0].tv_nsec = 0;
            times[1].tv_sec = timeT; // modification time
            times[1].tv_nsec = 0;

            utimensat(AT_FDCWD, dest.c_str(), times, 0);
        }

    } catch (...) {
        file.close();
        fs::remove(dest);
        throw;
    }
}

std::string Downloader::downloadText(const std::string &url, std::uint32_t maxTryCount)
{
    auto data = download(url, maxTryCount);
    return std::string(data.begin(), data.end());
}

std::vector<std::string> Downloader::downloadTextLines(const std::string &url, std::uint32_t maxTryCount)
{
    auto text = downloadText(url, maxTryCount);
    std::vector<std::string> lines;
    std::stringstream ss(text);
    std::string line;

    while (std::getline(ss, line))
        lines.push_back(line);

    return lines;
}

} // namespace ASGenerator
