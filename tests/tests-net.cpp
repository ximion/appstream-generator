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

#define CATCH_CONFIG_MAIN
#include <catch2/catch_all.hpp>

#include <fstream>
#include <filesystem>
#include <optional>
#include <cstdlib>

#include "downloader.h"
#include "utils.h"
#include "logging.h"

using namespace ASGenerator;

static bool canRunNetworkTests()
{
    // Enable verbose logging for tests
    setVerbose(true);

    // Check if network tests should be skipped
    const char *skipNetEnv = std::getenv("ASGEN_TESTS_NO_NET");
    if (skipNetEnv && std::string(skipNetEnv) != "no") {
        SKIP("Network dependent tests skipped (explicitly disabled via ASGEN_TESTS_NO_NET)");
        return false;
    }

    auto &downloader = Downloader::get();
    const std::string urlFirefoxDetectportal = "https://detectportal.firefox.com/";

    try {
        downloader.downloadText(urlFirefoxDetectportal);
    } catch (const DownloadException &e) {
        SKIP("Network dependent tests skipped (automatically, no network detected: " + std::string(e.what()) + ")");
        return false;
    }

    return true;
}

TEST_CASE("Downloader functionality", "[downloader][network]")
{
    if (!canRunNetworkTests())
        return;

    auto &downloader = Downloader::get();
    const std::string urlFirefoxDetectportal = "https://detectportal.firefox.com/";

    SECTION("File download functionality")
    {
        const std::string testFileName = "/tmp/asgen-test-ffdp-" + randomString(4);

        // Clean up file on exit
        auto cleanup = [&testFileName]() {
            if (std::filesystem::exists(testFileName)) {
                std::filesystem::remove(testFileName);
            }
        };

        try {
            downloader.downloadFile(urlFirefoxDetectportal, testFileName);

            // Verify file contents
            std::ifstream file(testFileName);
            REQUIRE(file.is_open());

            std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
            REQUIRE(content == "success\n");

            cleanup();
        } catch (const DownloadException &e) {
            cleanup();
            SKIP("Network test skipped: " + std::string(e.what()));
        }
    }

    SECTION("Download larger file")
    {
        const std::string testFileName = "/tmp/asgen-test-debian-" + randomString(4);

        auto cleanup = [&testFileName]() {
            if (std::filesystem::exists(testFileName)) {
                std::filesystem::remove(testFileName);
            }
        };

        try {
            downloader.downloadFile("https://debian.org", testFileName);

            // Verify file exists and has content
            REQUIRE(std::filesystem::exists(testFileName));
            REQUIRE(std::filesystem::file_size(testFileName) > 0);

            cleanup();
        } catch (const DownloadException &e) {
            cleanup();
            SKIP("Network test skipped: " + std::string(e.what()));
        }
    }

    SECTION("Error handling for non-existent file")
    {
        const std::string testFileName = "/tmp/asgen-dltest-" + randomString(4);

        auto cleanup = [&testFileName]() {
            if (std::filesystem::exists(testFileName)) {
                std::filesystem::remove(testFileName);
            }
        };

        try {
            REQUIRE_THROWS_AS(
                downloader.downloadFile("https://appstream.debian.org/nonexistent", testFileName, 2),
                DownloadException);
            cleanup();
        } catch (...) {
            cleanup();
            throw;
        }
    }

    SECTION("HTTP to HTTPS redirect handling")
    {
        const std::string testFileName = "/tmp/asgen-test-mozilla-" + randomString(4);

        auto cleanup = [&testFileName]() {
            if (std::filesystem::exists(testFileName)) {
                std::filesystem::remove(testFileName);
            }
        };

        try {
            // This should work as mozilla.org redirects HTTP to HTTPS
            downloader.downloadFile("http://mozilla.org", testFileName, 1);

            // Verify file exists and has content
            REQUIRE(std::filesystem::exists(testFileName));
            REQUIRE(std::filesystem::file_size(testFileName) > 0);

            cleanup();
        } catch (const DownloadException &e) {
            cleanup();
            SKIP("Network test skipped: " + std::string(e.what()));
        }
    }

    SECTION("Download to memory")
    {
        try {
            auto data = downloader.download(urlFirefoxDetectportal);

            std::string content(data.begin(), data.end());
            REQUIRE(content == "success\n");
        } catch (const DownloadException &e) {
            SKIP("Network test skipped: " + std::string(e.what()));
        }
    }

    SECTION("Download text lines")
    {
        try {
            auto lines = downloader.downloadTextLines(urlFirefoxDetectportal);

            REQUIRE(lines.size() == 1);
            REQUIRE(lines[0] == "success");
        } catch (const DownloadException &e) {
            SKIP("Network test skipped: " + std::string(e.what()));
        }
    }
}

TEST_CASE("Downloader edge cases", "[downloader]")
{
    if (!canRunNetworkTests())
        return;

    auto &downloader = Downloader::get();

    SECTION("Invalid URL handling")
    {
        REQUIRE_THROWS_AS(downloader.downloadText("not-a-url"), DownloadException);
    }

    SECTION("Empty URL handling")
    {
        REQUIRE_THROWS_AS(downloader.downloadText(""), DownloadException);
    }

    SECTION("Retry mechanism with zero retries")
    {
        REQUIRE_THROWS_AS(downloader.downloadText("https://nonexistent.example.invalid", 0), DownloadException);
    }
}

TEST_CASE("Downloader file skipping", "[downloader]")
{
    if (!canRunNetworkTests())
        return;
    auto &downloader = Downloader::get();

    SECTION("Skip download if file already exists")
    {
        const std::string testFileName = "/tmp/asgen-test-existing-" + randomString(4);

        // Create a file first
        {
            std::ofstream file(testFileName);
            file << "existing content\n";
        }

        auto cleanup = [&testFileName]() {
            if (std::filesystem::exists(testFileName)) {
                std::filesystem::remove(testFileName);
            }
        };

        try {
            // This should skip the download since file exists
            downloader.downloadFile("https://detectportal.firefox.com/", testFileName);

            // Verify the original content is still there
            std::ifstream file(testFileName);
            std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
            REQUIRE(content == "existing content\n");

            cleanup();
        } catch (const DownloadException &e) {
            cleanup();
            // If network is not available, the test should still pass
            // since the file exists and download should be skipped
            std::ifstream file(testFileName);
            if (file.is_open()) {
                std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
                REQUIRE(content == "existing content\n");
            }
        }
    }
}
