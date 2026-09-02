/*
 * Copyright (C) 2019-2025 Matthias Klumpp <matthias@tenstral.net>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#include <catch2/catch_all.hpp>

#include <fstream>
#include <filesystem>
#include <optional>
#include <cstdlib>

#include <atomic>
#include <chrono>
#include <format>
#include <string>
#include <thread>
#include <vector>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include "downloader.h"
#include "utils.h"
#include "scopeguard.h"

using namespace ASGenerator;

/**
 * A minimal HTTP server on loopback that hands out scripted responses, so the retry
 * behaviour can be tested. A response of std::nullopt makes it drop the connection
 * instead of answering, which is what curl reports as a failed transfer.
 */
class MockHttpServer
{
public:
    explicit MockHttpServer(std::vector<std::optional<std::string>> responses)
        : m_responses(std::move(responses))
    {
        m_listenFd = ::socket(AF_INET, SOCK_STREAM, 0);
        REQUIRE(m_listenFd >= 0);

        int one = 1;
        ::setsockopt(m_listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = ::htonl(INADDR_LOOPBACK);
        addr.sin_port = 0; // let the kernel pick a free port for us

        REQUIRE(::bind(m_listenFd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0);
        REQUIRE(::listen(m_listenFd, 8) == 0);

        socklen_t addrLen = sizeof(addr);
        REQUIRE(::getsockname(m_listenFd, reinterpret_cast<sockaddr *>(&addr), &addrLen) == 0);
        m_port = ::ntohs(addr.sin_port);

        m_thread = std::thread([this] {
            serve();
        });
    }

    ~MockHttpServer()
    {
        ::shutdown(m_listenFd, SHUT_RDWR);
        ::close(m_listenFd);
        if (m_thread.joinable())
            m_thread.join();
    }

    MockHttpServer(const MockHttpServer &) = delete;
    MockHttpServer &operator=(const MockHttpServer &) = delete;

    [[nodiscard]] std::string url() const
    {
        return std::format("http://127.0.0.1:{}/file", m_port);
    }

    [[nodiscard]] int requestCount() const
    {
        return m_requestCount.load();
    }

    static std::string response(const std::string &body)
    {
        return std::format("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}", body.size(), body);
    }

    /**
     * An empty response with the given HTTP status code.
     */
    static std::string statusResponse(int code)
    {
        return std::format("HTTP/1.1 {} Whatever\r\nContent-Length: 0\r\n\r\n", code);
    }

    /**
     * A response that announces more data than it delivers, then goes away - curl fails
     * this transfer after it has already written the truncated body out.
     */
    static std::string truncatedResponse(const std::string &body, std::size_t announcedLength)
    {
        return std::format("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}", announcedLength, body);
    }

private:
    void serve()
    {
        while (true) {
            const int fd = ::accept(m_listenFd, nullptr, nullptr);
            if (fd < 0)
                return; // the listening socket was closed, we are done

            // Read the request. Its content does not matter, we only need to know it arrived.
            std::string request;
            char buffer[4096];
            while (request.find("\r\n\r\n") == std::string::npos) {
                const auto received = ::recv(fd, buffer, sizeof(buffer), 0);
                if (received <= 0)
                    break;
                request.append(buffer, static_cast<std::size_t>(received));
            }

            const auto index = static_cast<std::size_t>(m_requestCount.fetch_add(1));
            const auto &scripted = index < m_responses.size() ? m_responses[index] : m_responses.back();
            if (scripted)
                ::send(fd, scripted->data(), scripted->size(), MSG_NOSIGNAL);

            ::close(fd);
        }
    }

    std::vector<std::optional<std::string>> m_responses;
    int m_listenFd = -1;
    std::uint16_t m_port = 0;
    std::atomic_int m_requestCount{0};
    std::thread m_thread;
};

TEST_CASE("Downloader retries", "[downloader]")
{
    auto &downloader = Downloader::get();
    const auto destFor = [](const char *tag) {
        return std::format("/tmp/asgen-test-{}-{}", tag, Utils::randomString(6));
    };

    SECTION("A failed transfer is retried and can still succeed")
    {
        // the remote end drops the first connection, then serves the file
        MockHttpServer server({std::nullopt, MockHttpServer::response("hello\n")});
        const auto dest = destFor("retry");
        auto cleanup = Utils::scopeGuard([&] {
            std::filesystem::remove(dest);
        });

        REQUIRE_NOTHROW(downloader.downloadFile(server.url(), dest, 4));
        REQUIRE(server.requestCount() == 2);

        std::ifstream file(dest);
        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        REQUIRE(content == "hello\n");
    }

    SECTION("A retry does not leave the previous attempt's data behind")
    {
        // The first attempt writes 40 bytes before the connection dies, the retry only has
        // 2 bytes to deliver. The result must be the short file, not the short file with
        // the tail of the long one still attached to it.
        MockHttpServer server(
            {MockHttpServer::truncatedResponse(std::string(40, 'x'), 4096), MockHttpServer::response("hi")});
        const auto dest = destFor("trunc");
        auto cleanup = Utils::scopeGuard([&] {
            std::filesystem::remove(dest);
        });

        REQUIRE_NOTHROW(downloader.downloadFile(server.url(), dest, 4));
        REQUIRE(server.requestCount() == 2);
        REQUIRE(std::filesystem::file_size(dest) == 2);

        std::ifstream file(dest);
        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        REQUIRE(content == "hi");
    }

    SECTION("Attempts are capped and a partial file is not left behind")
    {
        MockHttpServer server({std::nullopt});
        const auto dest = destFor("giveup");
        auto cleanup = Utils::scopeGuard([&] {
            std::filesystem::remove(dest);
        });

        REQUIRE_THROWS_AS(downloader.downloadFile(server.url(), dest, 2), DownloadException);
        REQUIRE(server.requestCount() == 2);
        REQUIRE_FALSE(std::filesystem::exists(dest));
    }

    SECTION("A definitive HTTP error is not retried")
    {
        // Backends probe for optional files (e.g. Packages.xz before Packages.gz) and rely
        // on a missing one being reported quickly, rather than after several backoff sleeps.
        MockHttpServer server({MockHttpServer::statusResponse(404)});
        const auto dest = destFor("notfound");
        auto cleanup = Utils::scopeGuard([&] {
            std::filesystem::remove(dest);
        });

        const auto start = std::chrono::steady_clock::now();
        REQUIRE_THROWS_AS(downloader.downloadFile(server.url(), dest, 4), DownloadException);
        REQUIRE(std::chrono::steady_clock::now() - start < std::chrono::milliseconds(500));
        REQUIRE(server.requestCount() == 1);
        REQUIRE_FALSE(std::filesystem::exists(dest));
    }

    SECTION("A server error is retried")
    {
        // an overloaded remote end may recover by the time we ask again
        MockHttpServer server({MockHttpServer::statusResponse(503), MockHttpServer::response("ok")});

        REQUIRE(downloader.downloadText(server.url(), 4) == "ok");
        REQUIRE(server.requestCount() == 2);
    }
}

static bool canRunNetworkTests()
{
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
        const std::string testFileName = "/tmp/asgen-test-ffdp-" + Utils::randomString(4);

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
        const std::string testFileName = "/tmp/asgen-test-debian-" + Utils::randomString(4);

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
        const std::string testFileName = "/tmp/asgen-dltest-" + Utils::randomString(4);

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
        const std::string testFileName = "/tmp/asgen-test-mozilla-" + Utils::randomString(4);

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
        const std::string testFileName = "/tmp/asgen-test-existing-" + Utils::randomString(4);

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
