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

DownloadException::DownloadException(const std::string &message)
    : m_message(message)
{
}

const char *DownloadException::what() const noexcept
{
    return m_message.c_str();
}

struct WriteCallbackData {
    std::ofstream *file;
    std::vector<std::uint8_t> *buffer;
};

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
        if (pos != std::string::npos)
            throw DownloadException("HTTPS URL tried to redirect to a less secure HTTP URL.");
    }

    // Parse Last-Modified header
    if (header.starts_with("last-modified:")) {
        auto colonPos = header.find(':');
        if (colonPos != std::string::npos) {
            std::string dateStr = header.substr(colonPos + 1);
            // Trim whitespace
            dateStr.erase(0, dateStr.find_first_not_of(" \t"));
            dateStr.erase(dateStr.find_last_not_of(" \t\r\n") + 1);

            // Parse RFC822 date format using strptime
            std::tm tm = {};
            if (strptime(dateStr.c_str(), "%a, %d %b %Y %H:%M:%S %Z", &tm)) {
                auto timeT = std::mktime(&tm);
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
    : userAgent(std::format("appstream-generator/{}", std::string(ASGEN_VERSION))),
      caInfo(Config::get().caInfo)
{
    // Initialize curl globally (should be done once per process)
    static bool curlInitialized = false;
    if (!curlInitialized) {
        curl_global_init(CURL_GLOBAL_DEFAULT);
        curlInitialized = true;
    }
}

std::optional<std::chrono::system_clock::time_point> Downloader::downloadInternal(
    const std::string &url,
    std::ofstream &dest,
    std::uint32_t maxTryCount)
{
    if (!Utils::isRemote(url))
        throw DownloadException("URL is not remote");

    std::optional<std::chrono::system_clock::time_point> lastModified;

    /* the curl library is stupid; you can't make an AutoProtocol set timeouts */
    logDebug("Downloading {}", url);

    CURL *curl = curl_easy_init();
    if (!curl) {
        throw DownloadException("Failed to initialize curl");
    }

    try {
        WriteCallbackData writeData{&dest, nullptr};
        HeaderCallbackData headerData{url.starts_with("https"), &lastModified};

        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &writeData);
        curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, headerCallback);
        curl_easy_setopt(curl, CURLOPT_HEADERDATA, &headerData);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, userAgent.c_str());
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 300L);

        if (!caInfo.empty())
            curl_easy_setopt(curl, CURLOPT_CAINFO, caInfo.c_str());

        CURLcode res = curl_easy_perform(curl);

        if (res != CURLE_OK) {
            if (maxTryCount > 0) {
                logDebug(
                    "Failed to download {}, will retry {} more {}",
                    url,
                    maxTryCount,
                    maxTryCount > 1 ? "times" : "time");
                // Reset file position to beginning before retry to avoid appending to partial data
                dest.seekp(0);

                curl_easy_cleanup(curl);
                return downloadInternal(url, dest, maxTryCount - 1);
            } else {
                curl_easy_cleanup(curl);
                throw DownloadException(std::format("curl_easy_perform() failed: {}", curl_easy_strerror(res)));
            }
        }

        long responseCode;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &responseCode);

        if (responseCode != 200 && responseCode != 301 && responseCode != 302) {
            if (responseCode == 0) {
                // just to be safe, check whether we received data before assuming everything went fine
                if (dest.tellp() == 0) {
                    curl_easy_cleanup(curl);
                    throw DownloadException(
                        std::format("No data was received from the remote end (Code: {}).", responseCode));
                }
            } else {
                curl_easy_cleanup(curl);
                throw DownloadException(std::format("HTTP request returned status code {}", responseCode));
            }
        }

        curl_easy_cleanup(curl);
        logDebug("Downloaded {}", url);

    } catch (const DownloadException &) {
        curl_easy_cleanup(curl);
        throw;
    } catch (const std::exception &e) {
        if (maxTryCount > 0) {
            logDebug(
                "Failed to download {}, will retry {} more {}", url, maxTryCount, maxTryCount > 1 ? "times" : "time");
            // Reset file position to beginning before retry to avoid appending to partial data
            dest.seekp(0);

            curl_easy_cleanup(curl);
            return downloadInternal(url, dest, maxTryCount - 1);
        } else {
            curl_easy_cleanup(curl);
            throw DownloadException(e.what());
        }
    }

    return lastModified;
}

std::optional<std::chrono::system_clock::time_point> Downloader::download(
    const std::string &url,
    std::ofstream &dFile,
    std::uint32_t maxTryCount)
{
    return downloadInternal(url, dFile, maxTryCount);
}

std::vector<std::uint8_t> Downloader::download(const std::string &url, std::uint32_t maxTryCount)
{
    if (!Utils::isRemote(url))
        throw DownloadException("URL is not remote");

    std::vector<std::uint8_t> buffer;
    std::optional<std::chrono::system_clock::time_point> lastModified;

    logDebug("Downloading {}", url);

    CURL *curl = curl_easy_init();
    if (!curl)
        throw DownloadException("Failed to initialize curl");

    try {
        WriteCallbackData writeData{nullptr, &buffer};
        HeaderCallbackData headerData{url.starts_with("https"), &lastModified};

        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &writeData);
        curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, headerCallback);
        curl_easy_setopt(curl, CURLOPT_HEADERDATA, &headerData);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, userAgent.c_str());
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 30L);

        if (!caInfo.empty()) {
            curl_easy_setopt(curl, CURLOPT_CAINFO, caInfo.c_str());
        }

        CURLcode res = curl_easy_perform(curl);

        if (res != CURLE_OK) {
            if (maxTryCount > 0) {
                logDebug(
                    "Failed to download {}, will retry {} more {}",
                    url,
                    maxTryCount,
                    maxTryCount > 1 ? "times" : "time");

                curl_easy_cleanup(curl);
                return download(url, maxTryCount - 1);
            } else {
                curl_easy_cleanup(curl);
                throw DownloadException(std::format("curl_easy_perform() failed: {}", curl_easy_strerror(res)));
            }
        }

        long responseCode;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &responseCode);

        if (responseCode != 200 && responseCode != 301 && responseCode != 302) {
            if (responseCode == 0) {
                if (buffer.empty()) {
                    curl_easy_cleanup(curl);
                    throw DownloadException(
                        std::format("No data was received from the remote end (Code: {}).", responseCode));
                }
            } else {
                curl_easy_cleanup(curl);
                throw DownloadException(std::format("HTTP request returned status code {}", responseCode));
            }
        }

        curl_easy_cleanup(curl);
        logDebug("Downloaded {}", url);

    } catch (const DownloadException &) {
        curl_easy_cleanup(curl);
        throw;
    } catch (const std::exception &e) {
        if (maxTryCount > 0) {
            logDebug(
                "Failed to download {}, will retry {} more {}", url, maxTryCount, maxTryCount > 1 ? "times" : "time");

            curl_easy_cleanup(curl);
            return download(url, maxTryCount - 1);
        } else {
            curl_easy_cleanup(curl);
            throw DownloadException(e.what());
        }
    }

    return buffer;
}

void Downloader::downloadFile(const std::string &url, const std::string &dest, std::uint32_t maxTryCount)
{
    if (!Utils::isRemote(url))
        throw DownloadException("URL is not remote");

    if (fs::exists(dest)) {
        logDebug("File '{}' already exists, re-download of '{}' skipped.", dest, url);
        return;
    }

    fs::create_directories(fs::path(dest).parent_path());

    std::ofstream file(dest, std::ios::binary);
    if (!file.is_open())
        throw DownloadException(std::format("Failed to open destination file: {}", dest));

    try {
        auto lastModified = downloadInternal(url, file, maxTryCount);
        file.close();

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
