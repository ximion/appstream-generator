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
#include <format>
#include <chrono>
#include <thread>

#include "contentsstore.h"
#include "config.h"
#include "utils.h"

using namespace ASGenerator;

TEST_CASE("ContentsStore basic operations", "[contentsstore]")
{
    // Create temporary directory for test database
    auto tempDir = fs::temp_directory_path() / std::format("asgen-test-{}", randomString(8));
    fs::create_directories(tempDir);

    SECTION("Constructor and basic lifecycle")
    {
        ContentsStore store;
        REQUIRE_NOTHROW(store.open(tempDir.string()));
        REQUIRE_NOTHROW(store.close());
    }

    SECTION("Package operations")
    {
        ContentsStore store;
        store.open(tempDir.string());

        const std::string testPkgId = "testpkg/1.0.0/amd64";

        // Initially package should not exist
        REQUIRE_FALSE(store.packageExists(testPkgId));

        // Add contents to package
        std::vector<std::string> contents = {
            "/usr/bin/testapp",
            "/usr/share/applications/testapp.desktop",
            "/usr/share/icons/hicolor/48x48/apps/testapp.png",
            "/usr/share/icons/hicolor/64x64/apps/testapp.png",
            "/usr/share/pixmaps/testapp.png",
            "/usr/share/locale/de/LC_MESSAGES/testapp.mo",
            "/usr/share/locale/fr/LC_MESSAGES/testapp.mo",
            "/usr/lib/testapp/plugin.so"};

        REQUIRE_NOTHROW(store.addContents(testPkgId, contents));

        // Now package should exist
        REQUIRE(store.packageExists(testPkgId));

        // Retrieve and verify contents
        auto retrievedContents = store.getContents(testPkgId);
        REQUIRE(retrievedContents.size() == contents.size());

        // Check that all original contents are present
        for (const auto &item : contents) {
            REQUIRE(std::find(retrievedContents.begin(), retrievedContents.end(), item) != retrievedContents.end());
        }

        store.close();
    }

    SECTION("Icon and locale filtering")
    {
        ContentsStore store;
        store.open(tempDir.string());

        const std::string testPkgId = "iconpkg/2.0.0/amd64";
        std::vector<std::string> contents = {
            "/usr/bin/app",
            "/usr/share/icons/hicolor/32x32/apps/app.png",
            "/usr/share/icons/hicolor/48x48/apps/app.svg",
            "/usr/share/pixmaps/app.xpm",
            "/usr/share/locale/en/LC_MESSAGES/app.mo",
            "/usr/share/locale/es/LC_MESSAGES/app.mo",
            "/usr/share/doc/app/README",
            "/usr/lib/qt5/translations/app_de.qm"};

        store.addContents(testPkgId, contents);

        // Test icon retrieval
        auto icons = store.getIcons(testPkgId);
        REQUIRE(icons.size() == 3); // 2 hicolor icons + 1 pixmap

        std::vector<std::string> expectedIcons = {
            "/usr/share/icons/hicolor/32x32/apps/app.png",
            "/usr/share/icons/hicolor/48x48/apps/app.svg",
            "/usr/share/pixmaps/app.xpm"};

        for (const auto &icon : expectedIcons) {
            REQUIRE(std::find(icons.begin(), icons.end(), icon) != icons.end());
        }

        // Test locale file retrieval
        auto localeFiles = store.getLocaleFiles(testPkgId);
        REQUIRE(localeFiles.size() == 3); // 2 .mo files + 1 .qm file

        std::vector<std::string> expectedLocaleFiles = {
            "/usr/share/locale/en/LC_MESSAGES/app.mo",
            "/usr/share/locale/es/LC_MESSAGES/app.mo",
            "/usr/lib/qt5/translations/app_de.qm"};

        for (const auto &locale : expectedLocaleFiles) {
            REQUIRE(std::find(localeFiles.begin(), localeFiles.end(), locale) != localeFiles.end());
        }

        store.close();
    }

    SECTION("Maps generation")
    {
        ContentsStore store;
        store.open(tempDir.string());

        // Add multiple packages
        std::vector<std::string> pkgIds = {"pkg1/1.0/amd64", "pkg2/2.0/amd64", "pkg3/3.0/amd64"};

        // Package 1: has icons and regular files
        store.addContents(
            pkgIds[0],
            {"/usr/bin/app1", "/usr/share/icons/hicolor/48x48/apps/app1.png", "/usr/share/applications/app1.desktop"});

        // Package 2: has locale files
        store.addContents(pkgIds[1], {"/usr/bin/app2", "/usr/share/locale/de/LC_MESSAGES/app2.mo"});

        // Package 3: mixed content
        store.addContents(
            pkgIds[2],
            {"/usr/lib/libtest.so", "/usr/share/pixmaps/test.png", "/usr/share/locale/fr/LC_MESSAGES/test.mo"});

        // Test contents map
        auto contentsMap = store.getContentsMap(pkgIds);
        REQUIRE(contentsMap.size() == 8); // All files from all packages
        REQUIRE(contentsMap["/usr/bin/app1"] == pkgIds[0]);
        REQUIRE(contentsMap["/usr/bin/app2"] == pkgIds[1]);
        REQUIRE(contentsMap["/usr/lib/libtest.so"] == pkgIds[2]);

        // Test icon files map
        auto iconMap = store.getIconFilesMap(pkgIds);
        REQUIRE(iconMap.size() == 2); // 2 icon files total
        REQUIRE(iconMap["/usr/share/icons/hicolor/48x48/apps/app1.png"] == pkgIds[0]);
        REQUIRE(iconMap["/usr/share/pixmaps/test.png"] == pkgIds[2]);

        // Test locale map
        auto localeMap = store.getLocaleMap(pkgIds);
        REQUIRE(localeMap.size() == 2); // 2 locale files total
        REQUIRE(localeMap["/usr/share/locale/de/LC_MESSAGES/app2.mo"] == pkgIds[1]);
        REQUIRE(localeMap["/usr/share/locale/fr/LC_MESSAGES/test.mo"] == pkgIds[2]);

        store.close();
    }

    SECTION("Package removal")
    {
        ContentsStore store;
        store.open(tempDir.string());

        const std::string pkgId = "removeme/1.0/amd64";
        std::vector<std::string> contents = {"/usr/bin/removeme", "/usr/share/doc/removeme"};

        store.addContents(pkgId, contents);
        REQUIRE(store.packageExists(pkgId));

        store.removePackage(pkgId);
        REQUIRE_FALSE(store.packageExists(pkgId));

        // Contents should be empty after removal
        auto retrievedContents = store.getContents(pkgId);
        REQUIRE(retrievedContents.empty());

        store.close();
    }

    SECTION("Package ID set operations")
    {
        ContentsStore store;
        store.open(tempDir.string());

        std::vector<std::string> pkgIds = {"pkg-a/1.0/amd64", "pkg-b/2.0/amd64", "pkg-c/3.0/i386"};

        // Add packages
        for (const auto &pkgId : pkgIds) {
            store.addContents(pkgId, {std::format("/usr/bin/{}", pkgId.substr(0, 5))});
        }

        // Get package ID set
        auto pkgIdSet = store.getPackageIdSet();
        REQUIRE(pkgIdSet.size() == 3);

        for (const auto &pkgId : pkgIds) {
            REQUIRE(pkgIdSet.find(pkgId) != pkgIdSet.end());
        }

        // Test bulk removal
        std::unordered_set<std::string> toRemove = {pkgIds[0], pkgIds[2]};
        store.removePackages(toRemove);

        // Only pkg-b should remain
        REQUIRE(store.packageExists(pkgIds[1]));
        REQUIRE_FALSE(store.packageExists(pkgIds[0]));
        REQUIRE_FALSE(store.packageExists(pkgIds[2]));

        store.close();
    }

    SECTION("Sync operation")
    {
        ContentsStore store;
        store.open(tempDir.string());

        store.addContents("sync-test/1.0/amd64", {"/usr/bin/synctest"});

        // Sync should not throw
        REQUIRE_NOTHROW(store.sync());

        store.close();
    }

    // Cleanup
    fs::remove_all(tempDir);
}

TEST_CASE("ContentsStore thread safety", "[contentsstore][threading]")
{
    auto tempDir = fs::temp_directory_path() / std::format("asgen-test-mt-{}", randomString(8));
    fs::create_directories(tempDir);

    ContentsStore store;
    store.open(tempDir.string());

    const int numThreads = 4;
    const int packagesPerThread = 10;
    std::vector<std::thread> threads;

    // Launch multiple threads that add packages concurrently
    for (int t = 0; t < numThreads; ++t) {
        threads.emplace_back([&store, t, packagesPerThread]() {
            for (int i = 0; i < packagesPerThread; ++i) {
                std::string pkgId = std::format("thread{}-pkg{}/1.0/amd64", t, i);
                std::vector<std::string> contents = {
                    std::format("/usr/bin/app-{}-{}", t, i), std::format("/usr/share/doc/app-{}-{}/README", t, i)};
                store.addContents(pkgId, contents);
            }
        });
    }

    // Wait for all threads
    for (auto &thread : threads) {
        thread.join();
    }

    // Verify all packages were added
    auto pkgSet = store.getPackageIdSet();
    REQUIRE(pkgSet.size() == numThreads * packagesPerThread);

    store.close();
    fs::remove_all(tempDir);
}
