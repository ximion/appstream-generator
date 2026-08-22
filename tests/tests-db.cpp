/*
 * Copyright (C) 2019-2025 Matthias Klumpp <matthias@tenstral.net>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#include <catch2/catch_all.hpp>

#include <fstream>
#include <filesystem>
#include <algorithm>
#include <optional>
#include <cstdlib>
#include <format>
#include <chrono>
#include <thread>

#include "contentsstore.h"
#include "datastore.h"
#include "config.h"
#include "utils.h"
#include "backends/dummy/dummypkg.h"
#include "result.h"
#include "hintregistry.h"

using namespace ASGenerator;

TEST_CASE("ContentsStore basic operations", "[contentsstore]")
{
    // Create temporary directory for test database
    auto tempDir = fs::temp_directory_path() / std::format("asgen-test-{}", Utils::randomString(8));
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
    auto tempDir = fs::temp_directory_path() / std::format("asgen-test-mt-{}", Utils::randomString(8));
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
    for (auto &thread : threads)
        thread.join();

    // Verify all packages were added
    auto pkgSet = store.getPackageIdSet();
    REQUIRE(pkgSet.size() == numThreads * packagesPerThread);

    store.close();
    fs::remove_all(tempDir);
}

TEST_CASE("DataStore basic operations", "[datastore]")
{
    // Create temporary directory for test database
    auto tempDir = fs::temp_directory_path() / std::format("asgen-datastore-test-{}", Utils::randomString(8));
    auto mediaDir = fs::temp_directory_path() / std::format("asgen-media-test-{}", Utils::randomString(8));
    fs::create_directories(tempDir);
    fs::create_directories(mediaDir);

    SECTION("Constructor and basic lifecycle")
    {
        DataStore store;
        REQUIRE_NOTHROW(store.open(tempDir.string(), mediaDir.string()));
        REQUIRE_NOTHROW(store.close());
    }

    SECTION("Metadata storage and retrieval")
    {
        DataStore store;
        store.open(tempDir.string(), mediaDir.string());

        const std::string gcid = "org.example.test";
        const std::string xmlData = R"(<component type="desktop-application">
    <id>org.example.test</id>
    <name>Test App</name>
  </component>)";

        const std::string yamlData = R"(Type: desktop-application
ID: org.example.test
Name:
  C: Test App
)";

        // Initially, metadata should not exist
        REQUIRE_FALSE(store.metadataExists(DataType::XML, gcid));
        REQUIRE_FALSE(store.metadataExists(DataType::YAML, gcid));

        // Store metadata
        REQUIRE_NOTHROW(store.setMetadata(DataType::XML, gcid, xmlData));
        REQUIRE_NOTHROW(store.setMetadata(DataType::YAML, gcid, yamlData));

        // Metadata should exist now and be retrievable
        REQUIRE(store.metadataExists(DataType::XML, gcid));
        REQUIRE(store.metadataExists(DataType::YAML, gcid));

        auto retrievedXml = store.getMetadata(DataType::XML, gcid);
        auto retrievedYaml = store.getMetadata(DataType::YAML, gcid);

        REQUIRE_FALSE(retrievedXml.empty());
        REQUIRE_FALSE(retrievedYaml.empty());
        REQUIRE(retrievedXml == xmlData);
        REQUIRE(retrievedYaml == yamlData);

        store.close();
    }

    SECTION("Package operations")
    {
        DataStore store;
        store.open(tempDir.string(), mediaDir.string());

        const std::string pkgId = "testpkg/1.0.0/amd64";

        // Initially, package should not exist
        REQUIRE_FALSE(store.packageExists(pkgId));
        REQUIRE_FALSE(store.isIgnored(pkgId));

        // Test package value operations
        std::string pkgValue = store.getPackageValue(pkgId);
        REQUIRE(pkgValue.empty());

        // Mark package as ignored
        REQUIRE_NOTHROW(store.setPackageIgnore(pkgId));
        REQUIRE(store.packageExists(pkgId));
        REQUIRE(store.isIgnored(pkgId));

        // Remove package
        REQUIRE_NOTHROW(store.removePackage(pkgId));
        REQUIRE_FALSE(store.packageExists(pkgId));

        store.close();
    }

    SECTION("Hints storage and retrieval")
    {
        DataStore store;
        store.open(tempDir.string(), mediaDir.string());

        const std::string pkgId = "hintpkg/2.0.0/amd64";
        const std::string hintsJson = R"({
    "hints": {
        "sugar-emulator.desktop": [
            {
                "tag": "no-metainfo",
                "vars": {}
            },
            {
                "tag": "description-missing",
                "vars": {
                    "kind": "desktop-application"
                }
            }
        ]
    },
    "package": "sugar-emulator-0.96\/0.96.1-2.1\/all"
})";

        // Initially, hints should not exist
        REQUIRE_FALSE(store.hasHints(pkgId));

        // Store hints
        REQUIRE_NOTHROW(store.setHints(pkgId, hintsJson));

        // Hints should exist now
        REQUIRE(store.hasHints(pkgId));

        // Retrieve and verify hints
        std::string retrievedHints = store.getHints(pkgId);
        REQUIRE_FALSE(retrievedHints.empty());
        REQUIRE(retrievedHints == hintsJson);

        store.close();
    }

    SECTION("Statistics operations")
    {
        DataStore store;
        store.open(tempDir.string(), mediaDir.string());

        // Create test statistics data to serialize
        std::unordered_map<std::string, std::variant<std::int64_t, std::string, double>> statsData = {
            {"suite",         std::string("testing")},
            {"section",       std::string("main")   },
            {"totalInfos",    123                   },
            {"totalWarnings", 24                    },
            {"totalErrors",   8                     },
            {"totalMetadata", 42                    }
        };

        // Add statistics
        REQUIRE_NOTHROW(store.addStatistics(statsData));

        // Retrieve statistics
        auto allStats = store.getStatistics();
        REQUIRE_FALSE(allStats.empty());
        REQUIRE(allStats.size() >= 1);

        // Verify the data in the first entry
        const auto &firstEntry = allStats[0];
        REQUIRE(firstEntry.data.contains("suite"));
        REQUIRE(firstEntry.data.contains("section"));
        REQUIRE(firstEntry.data.contains("totalInfos"));

        REQUIRE(std::get<std::string>(firstEntry.data.at("suite")) == "testing");
        REQUIRE(std::get<std::string>(firstEntry.data.at("section")) == "main");
        REQUIRE(std::get<std::int64_t>(firstEntry.data.at("totalInfos")) == 123);
        REQUIRE(std::get<std::int64_t>(firstEntry.data.at("totalWarnings")) == 24);
        REQUIRE(std::get<std::int64_t>(firstEntry.data.at("totalErrors")) == 8);
        REQUIRE(std::get<std::int64_t>(firstEntry.data.at("totalMetadata")) == 42);

        store.close();
    }

    SECTION("Repository info operations")
    {
        DataStore store;
        store.open(tempDir.string(), mediaDir.string());

        const std::string suite = "focal";
        const std::string section = "main";
        const std::string arch = "amd64";

        RepoInfo repoInfo;
        repoInfo.data["mtime"] = std::int64_t(1753758538);
        repoInfo.data["last_updated"] = 1643723400.0; // timestamp as double

        // Set repository info
        REQUIRE_NOTHROW(store.setRepoInfo(suite, section, arch, repoInfo));

        // Retrieve repository info
        RepoInfo retrievedRepoInfo = store.getRepoInfo(suite, section, arch);
        REQUIRE_FALSE(retrievedRepoInfo.data.empty());

        // Verify the content
        REQUIRE(retrievedRepoInfo.data.contains("mtime"));
        REQUIRE(retrievedRepoInfo.data.contains("last_updated"));

        REQUIRE(std::get<std::int64_t>(retrievedRepoInfo.data.at("mtime")) == 1753758538);
        REQUIRE(std::get<double>(retrievedRepoInfo.data.at("last_updated")) == 1643723400.0);

        // Remove repository info
        REQUIRE_NOTHROW(store.removeRepoInfo(suite, section, arch));

        // Verify removal - should return empty RepoInfo
        RepoInfo removedRepoInfo = store.getRepoInfo(suite, section, arch);
        REQUIRE(removedRepoInfo.data.empty());

        store.close();
    }

    SECTION("GCID operations")
    {
        DataStore store;
        store.open(tempDir.string(), mediaDir.string());

        const std::string pkgId = "gcidpkg/1.0/amd64";

        // Initially no GCIDs
        auto gcids = store.getGCIDsForPackage(pkgId);
        REQUIRE(gcids.empty());

        // Create a dummy package for testing using the existing DummyPackage class
        auto dummyPkg = std::make_shared<DummyPackage>("gcidpkg", "1.0", "amd64");
        dummyPkg->setMaintainer("Test Maintainer <test@example.org>");
        dummyPkg->setDescription("A test package for GCID operations", "C");

        // Create a GeneratorResult with test components
        GeneratorResult gres(dummyPkg);

        // Create test components manually using AppStream
        g_autoptr(AsComponent) cpt1 = as_component_new();
        as_component_set_kind(cpt1, AS_COMPONENT_KIND_DESKTOP_APP);
        as_component_set_id(cpt1, "org.example.abiword");
        as_component_set_name(cpt1, "AbiWord", "C");
        as_component_set_summary(cpt1, "Word Processor", "C");

        g_autoptr(AsComponent) cpt2 = as_component_new();
        as_component_set_kind(cpt2, AS_COMPONENT_KIND_DESKTOP_APP);
        as_component_set_id(cpt2, "org.kde.ark");
        as_component_set_name(cpt2, "Ark", "C");
        as_component_set_summary(cpt2, "Archive Manager", "C");

        // Add components to the result
        gres.addComponent(cpt1);
        gres.addComponent(cpt2);

        // Verify components were added
        REQUIRE(gres.componentsCount() == 2);

        // Test XML metadata generation and storage
        REQUIRE_NOTHROW(store.addGeneratorResult(DataType::XML, gres, false));

        // Now we should have GCIDs for the package
        auto retrievedGcids = store.getGCIDsForPackage(pkgId);
        REQUIRE_FALSE(retrievedGcids.empty());
        REQUIRE(retrievedGcids.size() == 2);

        // Get the actual GCIDs that were generated
        auto actualGcids = gres.getComponentGcids();
        REQUIRE(actualGcids.size() == 2);

        // Verify that the stored GCIDs match what was generated
        for (const auto &gcid : actualGcids) {
            REQUIRE(std::find(retrievedGcids.begin(), retrievedGcids.end(), gcid) != retrievedGcids.end());
        }

        // Test that metadata was actually stored for each GCID
        for (const auto &gcid : actualGcids) {
            REQUIRE(store.metadataExists(DataType::XML, gcid));
            auto metadata = store.getMetadata(DataType::XML, gcid);
            REQUIRE_FALSE(metadata.empty());

            // Verify the metadata contains expected component information
            if (gcid.find("abiword") != std::string::npos || metadata.find("AbiWord") != std::string::npos) {
                REQUIRE(metadata.find("org.example.abiword") != std::string::npos);
            } else if (gcid.find("ark") != std::string::npos || metadata.find("Ark") != std::string::npos) {
                REQUIRE(metadata.find("org.kde.ark") != std::string::npos);
            }
        }

        // Test YAML metadata generation as well
        GeneratorResult gresYaml(dummyPkg);
        gresYaml.addComponent(cpt1);
        gresYaml.addComponent(cpt2);

        REQUIRE_NOTHROW(store.addGeneratorResult(DataType::YAML, gresYaml, false));

        // Verify YAML metadata was stored
        for (const auto &gcid : gresYaml.getComponentGcids()) {
            REQUIRE(store.metadataExists(DataType::YAML, gcid));
            auto yamlMetadata = store.getMetadata(DataType::YAML, gcid);
            REQUIRE_FALSE(yamlMetadata.empty());
        }

        // Test getMetadataForPackage
        auto xmlMetadataList = store.getMetadataForPackage(DataType::XML, pkgId);
        REQUIRE(xmlMetadataList.size() == 2);

        auto yamlMetadataList = store.getMetadataForPackage(DataType::YAML, pkgId);
        REQUIRE(yamlMetadataList.size() == 2);

        // Test regeneration behavior (alwaysRegenerate = false)
        GeneratorResult gresNoRegen(dummyPkg);
        gresNoRegen.addComponent(cpt1);
        gresNoRegen.addComponent(cpt2);

        // This should not regenerate since metadata already exists
        store.addGeneratorResult(DataType::XML, gresNoRegen, false);

        // Test forced regeneration (alwaysRegenerate = true)
        GeneratorResult gresForceRegen(dummyPkg);
        gresForceRegen.addComponent(cpt1);
        gresForceRegen.addComponent(cpt2);

        // This should regenerate even though metadata exists
        store.addGeneratorResult(DataType::XML, gresForceRegen, true);

        store.close();
    }

    SECTION("Package matching")
    {
        DataStore store;
        store.open(tempDir.string(), mediaDir.string());

        // Add some test packages
        const std::vector<std::string> testPackages = {
            "myapp/1.0/amd64", "myapp/2.0/amd64", "mylib/1.5/amd64", "otherapp/3.0/i386"};

        for (const auto &pkgId : testPackages) {
            store.setPackageIgnore(pkgId);
        }

        // Test prefix matching
        auto matches = store.getPkidsMatching("myapp");
        REQUIRE(matches.size() == 2);
        REQUIRE(std::find(matches.begin(), matches.end(), "myapp/1.0/amd64") != matches.end());
        REQUIRE(std::find(matches.begin(), matches.end(), "myapp/2.0/amd64") != matches.end());

        auto libMatches = store.getPkidsMatching("mylib");
        REQUIRE(libMatches.size() == 1);
        REQUIRE(libMatches[0] == "mylib/1.5/amd64");

        auto noMatches = store.getPkidsMatching("nonexistent");
        REQUIRE(noMatches.empty());

        store.close();
    }

    SECTION("Package ID sets")
    {
        DataStore store;
        store.open(tempDir.string(), mediaDir.string());

        const std::vector<std::string> testPackages = {"pkg1/1.0/amd64", "pkg2/2.0/amd64", "pkg3/3.0/i386"};

        // Add packages
        for (const auto &pkgId : testPackages)
            store.setPackageIgnore(pkgId);

        // Get package ID set
        auto pkgSet = store.getPackageIdSet();
        REQUIRE(pkgSet.size() == testPackages.size());

        for (const auto &pkgId : testPackages)
            REQUIRE(pkgSet.contains(pkgId));

        // Test bulk removal
        std::unordered_set<std::string> toRemove = {testPackages[0], testPackages[2]};
        REQUIRE_NOTHROW(store.removePackages(toRemove));

        // Verify removal
        REQUIRE_FALSE(store.packageExists(testPackages[0]));
        REQUIRE(store.packageExists(testPackages[1])); // Should still exist
        REQUIRE_FALSE(store.packageExists(testPackages[2]));

        store.close();
    }

    // Cleanup
    fs::remove_all(tempDir);
    fs::remove_all(mediaDir);
}

TEST_CASE("DataStore thread safety", "[datastore][threading]")
{
    auto tempDir = fs::temp_directory_path() / std::format("asgen-datastore-test-mt-{}", Utils::randomString(8));
    auto mediaDir = fs::temp_directory_path() / std::format("asgen-media-test-mt-{}", Utils::randomString(8));
    fs::create_directories(tempDir);
    fs::create_directories(mediaDir);

    DataStore store;
    store.open(tempDir.string(), mediaDir.string());

    const int numThreads = 4;
    const int itemsPerThread = 10;
    std::vector<std::thread> threads;

    // Launch multiple threads that store metadata concurrently
    for (int t = 0; t < numThreads; ++t) {
        threads.emplace_back([&store, t, itemsPerThread]() {
            for (int i = 0; i < itemsPerThread; ++i) {
                std::string gcid = std::format("org.example.thread{}.item{}", t, i);
                std::string xmlData = std::format(
                    R"(<?xml version="1.0"?>
<component type="desktop-application">
  <id>{}</id>
  <name>Thread {} Item {}</name>
</component>)",
                    gcid,
                    t,
                    i);

                store.setMetadata(DataType::XML, gcid, xmlData);
            }
        });
    }

    // Wait for all threads
    for (auto &thread : threads)
        thread.join();

    // Verify thread safety by checking a few items
    for (int t = 0; t < 2; ++t) {
        for (int i = 0; i < 2; ++i) {
            std::string gcid = std::format("org.example.thread{}.item{}", t, i);
            REQUIRE(store.metadataExists(DataType::XML, gcid));
        }
    }

    store.close();
    fs::remove_all(tempDir);
    fs::remove_all(mediaDir);
}

TEST_CASE("DataStore component ownership", "[datastore]")
{
    SECTION("Ownership rule")
    {
        // the newer version of the same software wins
        REQUIRE(DataStore::componentOwnerWins("fltk1.3-games/1.3.3/amd64", "fltk1.1-games/1.1.10/amd64"));
        REQUIRE_FALSE(DataStore::componentOwnerWins("fltk1.1-games/1.1.10/amd64", "fltk1.3-games/1.3.3/amd64"));

        // on equal versions, the less qualified name wins
        REQUIRE(DataStore::componentOwnerWins("quassel/0.10.0/amd64", "quassel-kde4/0.10.0/amd64"));
        REQUIRE_FALSE(DataStore::componentOwnerWins("quassel-kde4/0.10.0/amd64", "quassel/0.10.0/amd64"));
        REQUIRE(DataStore::componentOwnerWins("spacefm/1.0.5/amd64", "spacefm-gtk3/1.0.5/amd64"));

        // names of the same length are compared like versions
        REQUIRE(DataStore::componentOwnerWins("roxterm-gtk3/3.3.2/amd64", "roxterm-gtk2/3.3.2/amd64"));
        REQUIRE_FALSE(DataStore::componentOwnerWins("roxterm-gtk2/3.3.2/amd64", "roxterm-gtk3/3.3.2/amd64"));

        // an epoch in the version is handled by the version comparison, not by string sorting
        REQUIRE(DataStore::componentOwnerWins("quassel/1:0.10.0-2.4/amd64", "quassel/0.12.0/amd64"));

        // nobody owning the component means we take it, and we never take it from ourselves
        REQUIRE(DataStore::componentOwnerWins("quassel/0.10.0/amd64", ""));
        REQUIRE_FALSE(DataStore::componentOwnerWins("quassel/0.10.0/amd64", "quassel/0.10.0/amd64"));

        // the rule has to be a total order, or the winner would depend on processing order
        const std::vector<std::string> pkids = {
            "quassel/0.10.0/amd64",
            "quassel-kde4/0.10.0/amd64",
            "fltk1.1-games/1.1.10/amd64",
            "fltk1.3-games/1.3.3/amd64",
            "roxterm-gtk2/3.3.2/amd64",
            "roxterm-gtk3/3.3.2/amd64"};
        for (const auto &a : pkids) {
            for (const auto &b : pkids) {
                if (a == b)
                    continue;
                REQUIRE(DataStore::componentOwnerWins(a, b) != DataStore::componentOwnerWins(b, a));
            }
        }
    }

    SECTION("Ownership of duplicate components")
    {
        // losing a component to another package produces a hint, so we need the templates
        loadHintsRegistry();

        auto tempDir = fs::temp_directory_path() / std::format("asgen-test-{}", Utils::randomString(8));
        auto mediaDir = fs::temp_directory_path() / std::format("asgen-media-{}", Utils::randomString(8));
        fs::create_directories(tempDir);
        fs::create_directories(mediaDir);

        DataStore store;
        store.open(tempDir.string(), mediaDir.string());

        // two packages shipping the exact same component data produce the same global ID
        const auto makeComponent = []() {
            AsComponent *cpt = as_component_new();
            as_component_set_kind(cpt, AS_COMPONENT_KIND_DESKTOP_APP);
            as_component_set_id(cpt, "org.quassel_irc.QuasselClient");
            as_component_set_name(cpt, "Quassel IRC", "C");
            as_component_set_summary(cpt, "Distributed IRC client", "C");
            return cpt;
        };

        // media is rendered into a staging directory and only moved into the pool once the
        // component is ours, so every result gets one of its own
        std::uint32_t stagingCounter = 0;
        const auto addResultFor =
            [&](const std::string &name, const std::string &ver, PackageKind kind = PackageKind::Physical) {
                auto pkg = std::make_shared<DummyPackage>(name, ver, "amd64");
                pkg->setMaintainer("Test Maintainer <test@example.org>");
                pkg->setKind(kind);

                const auto stagingDir = mediaDir / "_staging" / std::to_string(stagingCounter++);
                GeneratorResult gres(pkg, stagingDir);

                g_autoptr(AsComponent) cpt = makeComponent();
                gres.addComponent(cpt);

                const auto gcids = gres.getComponentGcids();
                REQUIRE(gcids.size() == 1);

                // pretend we rendered an icon for the component
                const auto stagedIconDir = gres.mediaStagingDir(cpt) / "icons" / "64x64";
                fs::create_directories(stagedIconDir);
                std::ofstream(stagedIconDir / std::format("{}_test.png", name)) << "icon";

                store.addGeneratorResult(DataType::XML, gres, kind == PackageKind::Fake);

                // committing the result consumes its staging area
                REQUIRE_FALSE(fs::exists(stagingDir));

                return gcids[0];
            };

        const auto poolIcons = [&](const std::string &gcid) {
            std::vector<std::string> names;
            const auto dir = mediaDir / "pool" / gcid / "icons" / "64x64";
            std::error_code ec;
            for (fs::directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec))
                names.push_back(it->path().filename().string());
            std::ranges::sort(names);
            return names;
        };

        // A result owns its staging area, so one that is dropped without ever being
        // committed takes the media rendered for it along.
        {
            const auto orphanedStagingDir = mediaDir / "_staging" / "orphaned";
            fs::create_directories(orphanedStagingDir / "some" / "media");
            {
                auto pkg = std::make_shared<DummyPackage>("dropped", "1.0", "amd64");
                GeneratorResult gres(pkg, orphanedStagingDir);
                REQUIRE(fs::exists(orphanedStagingDir));
            }
            REQUIRE_FALSE(fs::exists(orphanedStagingDir));
        }

        // the first package to show up simply gets the component
        const auto gcid = addResultFor("quassel-kde4", "0.10.0");
        REQUIRE(store.getGcidOwner(gcid) == "quassel-kde4/0.10.0/amd64");
        REQUIRE(store.getMetadata(DataType::XML, gcid).find("<pkgname>quassel-kde4</pkgname>") != std::string::npos);
        REQUIRE(poolIcons(gcid) == std::vector<std::string>{"quassel-kde4_test.png"});

        // ... but a package that wins the ownership rule takes it away again
        REQUIRE(addResultFor("quassel", "0.10.0") == gcid);
        REQUIRE(store.getGcidOwner(gcid) == "quassel/0.10.0/amd64");
        REQUIRE(store.getMetadata(DataType::XML, gcid).find("<pkgname>quassel</pkgname>") != std::string::npos);

        // ... and the media of the package that lost is replaced by ours, rather than both
        // of them ending up in the same directory
        REQUIRE(poolIcons(gcid) == std::vector<std::string>{"quassel_test.png"});

        // The package that lost also loses its reference to the component, so the metadata
        // is exported once rather than once per package providing it. This matters because
        // the loser may well have been processed first, in which case it committed the
        // component before it could know that it was going to lose it.
        REQUIRE(store.getGCIDsForPackage("quassel-kde4/0.10.0/amd64").empty());
        REQUIRE(store.getPackageValue("quassel-kde4/0.10.0/amd64") == "seen");
        REQUIRE(store.getGCIDsForPackage("quassel/0.10.0/amd64") == std::vector<std::string>{gcid});

        // It was committed before the winner and could not know that it was going to lose,
        // so it is told about it here - otherwise the hints would depend on the order in
        // which the two packages happened to be processed.
        const auto kde4Hints = store.getHints("quassel-kde4/0.10.0/amd64");
        REQUIRE(kde4Hints.find("metainfo-duplicate-id") != std::string::npos);
        REQUIRE(kde4Hints.find("\"pkgname\":\"quassel\"") != std::string::npos);

        // The loser does not get it back, no matter how often we process it. This is also the
        // case where a package loses only at commit time: the extractor's early check can not
        // see a winner that was still being processed when it looked, so the package arrives
        // here with its components intact. It has to end up in exactly the same state as one
        // that was dropped early - no reference to the component, and a hint saying why.
        REQUIRE(addResultFor("quassel-kde4", "0.10.0") == gcid);
        REQUIRE(store.getGcidOwner(gcid) == "quassel/0.10.0/amd64");
        REQUIRE(store.getMetadata(DataType::XML, gcid).find("<pkgname>quassel</pkgname>") != std::string::npos);
        REQUIRE(poolIcons(gcid) == std::vector<std::string>{"quassel_test.png"});
        REQUIRE(store.getGCIDsForPackage("quassel-kde4/0.10.0/amd64").empty());
        REQUIRE(store.getHints("quassel-kde4/0.10.0/amd64").find("metainfo-duplicate-id") != std::string::npos);

        // The other way of losing: the extractor saw the winner and dropped the component
        // together with its global ID before any media was rendered. A package arriving here
        // in that state must end up exactly like one that only lost at commit time, or our
        // output would depend on which of the two paths a package happened to take.
        {
            auto pkg = std::make_shared<DummyPackage>("quassel-qt4", "0.10.0", "amd64");
            pkg->setMaintainer("Test Maintainer <test@example.org>");
            GeneratorResult gres(pkg, mediaDir / "_staging" / std::to_string(stagingCounter++));

            g_autoptr(AsComponent) cpt = makeComponent();
            gres.addComponent(cpt);
            REQUIRE(gres.getComponentGcids() == std::vector<std::string>{gcid});

            gres.addHint(
                cpt,
                "metainfo-duplicate-id",
                {
                    {"cid",     as_component_get_id(cpt)},
                    {"pkgname", "quassel"               }
            });
            gres.removeComponent(cpt);
            REQUIRE(gres.getComponentGcids().empty());

            store.addGeneratorResult(DataType::XML, gres);
        }

        REQUIRE(store.getGcidOwner(gcid) == "quassel/0.10.0/amd64");
        REQUIRE(store.getGCIDsForPackage("quassel-qt4/0.10.0/amd64").empty());
        REQUIRE(store.getPackageValue("quassel-qt4/0.10.0/amd64") == "seen");
        REQUIRE(store.getHints("quassel-qt4/0.10.0/amd64").find("metainfo-duplicate-id") != std::string::npos);
        REQUIRE(poolIcons(gcid) == std::vector<std::string>{"quassel_test.png"});

        // a new version of the owner keeps the component, and the registry follows along -
        // a stale version in there could tip the rule the wrong way for the next contender
        REQUIRE(addResultFor("quassel", "0.20.0") == gcid);
        REQUIRE(store.getGcidOwner(gcid) == "quassel/0.20.0/amd64");
        REQUIRE_FALSE(DataStore::componentOwnerWins("quassel-kde4/0.20.0/amd64", store.getGcidOwner(gcid)));

        // injected metadata overrides whatever the archive provides, even though its fake
        // package would lose the contest on both version and name
        REQUIRE(addResultFor(EXTRA_METAINFO_FAKE_PKGNAME, "0~0", PackageKind::Fake) == gcid);
        REQUIRE(store.getGcidOwner(gcid) == std::format("{}/0~0/amd64", EXTRA_METAINFO_FAKE_PKGNAME));

        // the injected data has no package of its own to install, so the real package has to
        // keep providing the component
        REQUIRE(store.getGCIDsForPackage("quassel/0.20.0/amd64") == std::vector<std::string>{gcid});

        store.close();
        fs::remove_all(tempDir);
        fs::remove_all(mediaDir);
    }
}
