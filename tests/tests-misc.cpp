/*
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#define CATCH_CONFIG_MAIN
#include <catch2/catch_all.hpp>

#include <fstream>
#include <filesystem>
#include <optional>
#include <thread>
#include <appstream-compose.h>

#include "logging.h"
#include "utils.h"
#include "zarchive.h"
#include "hintregistry.h"
#include "result.h"
#include "backends/dummy/dummypkg.h"
#include "cptmodifiers.h"

using namespace ASGenerator;
using namespace ASGenerator::Utils;

static struct TestSetup {
    TestSetup()
    {
        // Enable verbose logging for tests
        setVerbose(true);
    }
} testSetup;

TEST_CASE("Compressed empty file decompresses to empty string", "[zarchive]")
{
    // gzip-compressed empty file
    std::vector<uint8_t> emptyGz = {
        0x1f, 0x8b, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x65, 0x6d, 0x70,
        0x74, 0x79, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    REQUIRE(decompressData(emptyGz) == "");
}

TEST_CASE("Extracting a tarball", "[zarchive]")
{
    std::string archive = fs::path(Utils::getTestSamplesDir()) / "test.tar.xz";
    REQUIRE(fs::exists(archive));
    ArchiveDecompressor ar;

    // Create a temporary directory
    std::string tmpdir = fs::temp_directory_path() / fs::path("asgenXXXXXX");
    std::vector<char> ctmpdir(tmpdir.begin(), tmpdir.end());
    ctmpdir.push_back('\0');
    char *mkdtemp_result = mkdtemp(ctmpdir.data());
    REQUIRE(mkdtemp_result != nullptr);
    tmpdir = std::string(mkdtemp_result);
    auto cleanup = [&tmpdir](void *) {
        fs::remove_all(tmpdir);
    };
    std::unique_ptr<void, decltype(cleanup)> guard((void *)1, cleanup);

    ar.open(archive);
    ar.extractArchive(tmpdir);

    std::string path = fs::path(tmpdir) / "b" / "a";
    REQUIRE(fs::exists(path));
    std::ifstream f(path);
    REQUIRE(f);
    std::string content;
    std::getline(f, content);
    // Remove trailing newline if present
    if (!content.empty() && content.back() == '\n')
        content.pop_back();
    REQUIRE(content == "hello");

    // Read regular file which has a hardlink pointing to it
    std::string test_path = fs::path(tmpdir) / "test.txt";
    REQUIRE(fs::exists(test_path));
    std::ifstream f2(test_path);
    REQUIRE(f2);
    std::string test_content;
    std::getline(f2, test_content);
    // Remove trailing newline if present
    if (!test_content.empty() && test_content.back() == '\n')
        test_content.pop_back();
    REQUIRE(test_content == "Wow!");

    // Verify the hardlink contents matches the original file
    std::string hardlink_path = fs::path(tmpdir) / "e" / "f";
    REQUIRE(fs::exists(hardlink_path));
    std::ifstream f3(hardlink_path);
    REQUIRE(f3);
    std::string hardlink_content;
    std::getline(f3, hardlink_content);
    // Remove trailing newline if present
    if (!hardlink_content.empty() && hardlink_content.back() == '\n')
        hardlink_content.pop_back();
    REQUIRE(test_content == hardlink_content);
}

TEST_CASE("Reading data from tarball using readData", "[zarchive]")
{
    std::string archive = fs::path(Utils::getTestSamplesDir()) / "test.tar.xz";
    REQUIRE(fs::exists(archive));
    ArchiveDecompressor ar;
    ar.open(archive);

    SECTION("Read specific files directly from archive")
    {
        // Test reading a known file from the test archive
        auto data = ar.readData("b/a");
        REQUIRE(!data.empty());

        std::string content(data.begin(), data.end());
        // Remove trailing newline if present
        if (!content.empty() && content.back() == '\n')
            content.pop_back();
        REQUIRE(content == "hello");

        // Test reading another file
        auto data2 = ar.readData("c/d");
        REQUIRE(!data2.empty());

        std::string content2(data2.begin(), data2.end());
        // Remove trailing newline if present
        if (!content2.empty() && content2.back() == '\n')
            content2.pop_back();
        REQUIRE(content2 == "world");

        // Read with starting slash
        auto data3 = ar.readData("/c/d");
        REQUIRE(!data3.empty());

        // Ensure we follow hardlinks
        auto data4 = ar.readData("e/f");
        REQUIRE(!data4.empty());
    }

    SECTION("Read with path variations")
    {
        // Test that paths with leading slash work the same
        auto data1 = ar.readData("b/a");
        auto data2 = ar.readData("/b/a");

        REQUIRE(data1 == data2);
    }

    SECTION("Read non-existent file throws exception")
    {
        REQUIRE_THROWS_AS(ar.readData("non/existent/file"), std::runtime_error);
    }

    ar.close();
}

TEST_CASE("Utils: getCidFromGlobalID", "[utils]")
{
    REQUIRE(getCidFromGlobalID("f/fo/foobar.desktop/DEADBEEF").value() == "foobar.desktop");
    REQUIRE(getCidFromGlobalID("org/gnome/yelp.desktop/DEADBEEF").value() == "org.gnome.yelp.desktop");
    REQUIRE_FALSE(getCidFromGlobalID("invalid/only/three").has_value());
    REQUIRE_FALSE(getCidFromGlobalID("").has_value());
}

TEST_CASE("Utils: localeValid returns false for x-test and xx, true otherwise", "[utils]")
{
    REQUIRE_FALSE(localeValid("x-test"));
    REQUIRE_FALSE(localeValid("xx"));
    REQUIRE(localeValid("en_US"));
    REQUIRE(localeValid("de"));
}

TEST_CASE("Utils: getTextFileContents and getFileContents read file data", "[utils]")
{
    auto tmpfile = fs::temp_directory_path() / "asgen_testfile.txt";
    {
        std::ofstream f(tmpfile);
        f << "line1\nline2\n";
    }
    auto lines = getTextFileContents(tmpfile.string());
    REQUIRE(lines.size() == 2);
    REQUIRE(lines[0] == "line1");
    REQUIRE(lines[1] == "line2");
    auto bytes = getFileContents(tmpfile.string());
    REQUIRE(bytes.size() == 12); // 6+6 including newlines
    fs::remove(tmpfile);
}

TEST_CASE("Utils: normalizePath", "[utils]")
{
    REQUIRE(normalizePath("/usr") == "/usr");
    REQUIRE(normalizePath("/usr/") == "/usr");
    REQUIRE(normalizePath("/usr//") == "/usr");
    REQUIRE(normalizePath("/usr/test/..//") == "/usr");
}

TEST_CASE("Selectively reading tarball", "[zarchive]")
{
    std::string archive = fs::path(getTestSamplesDir()) / "test.tar.xz";
    REQUIRE(fs::exists(archive));
    ArchiveDecompressor ar;
    ar.open(archive);

    SECTION("Full iteration through all entries")
    {
        std::vector<std::string> filenames;
        std::vector<std::vector<uint8_t>> fileData;

        for (const auto &entry : ar.read()) {
            filenames.push_back(entry.fname);
            fileData.push_back(entry.data);
        }

        // Should have found files from the test archive
        REQUIRE(!filenames.empty());

        // Check that we got the expected file
        auto it = std::find(filenames.begin(), filenames.end(), "/b/a");
        REQUIRE(it != filenames.end());

        // Get the data for file "/b/a" and verify content
        size_t index = std::distance(filenames.begin(), it);
        std::string content(fileData[index].begin(), fileData[index].end());
        // Remove trailing newline if present
        if (!content.empty() && content.back() == '\n')
            content.pop_back();
        REQUIRE(content == "hello");
    }

    SECTION("Early termination when finding specific file")
    {
        int entriesProcessed = 0;
        bool foundTargetFile = false;
        std::string targetContent;

        for (const auto &entry : ar.read()) {
            entriesProcessed++;

            if (entry.fname == "/c/d") {
                foundTargetFile = true;
                targetContent = std::string(entry.data.begin(), entry.data.end());
                // Remove trailing newline if present
                if (!targetContent.empty() && targetContent.back() == '\n')
                    targetContent.pop_back();
                break; // Early termination
            }
        }

        REQUIRE(foundTargetFile);
        REQUIRE(targetContent == "world");
        // Should have processed fewer entries than total (early termination worked)
        REQUIRE(entriesProcessed > 0);
        REQUIRE(entriesProcessed <= 10); // Reasonable upper bound for test archive
    }

    SECTION("Multiple iterations over same archive")
    {
        // Test that we can iterate multiple times
        int firstCount = 0;
        for (const auto &entry : ar.read()) {
            firstCount++;
            (void)entry; // Suppress unused variable warning
        }

        int secondCount = 0;
        for (const auto &entry : ar.read()) {
            secondCount++;
            (void)entry;
        }

        // Both iterations should yield the same number of entries
        REQUIRE(firstCount > 0);
        REQUIRE(firstCount == secondCount);
    }

    ar.close();
}

TEST_CASE("Image size operations", "[utils][imagesize]")
{
    SECTION("ImageSize construction and comparison")
    {
        ImageSize size1(64);
        ImageSize size2(64, 64, 1);
        ImageSize size3(64, 64, 2); // HiDPI
        ImageSize size4(128);

        REQUIRE(size1 == size2);
        REQUIRE(size1 != size3);
        REQUIRE(size1 != size4);
        REQUIRE(size3 != size4);

        // Test scale differences
        REQUIRE(size1.scale == 1);
        REQUIRE(size3.scale == 2);
    }

    SECTION("ImageSize string representation")
    {
        ImageSize size1(64);
        ImageSize size2(128, 128, 2);

        REQUIRE(size1.toString() == "64x64");
        REQUIRE(size2.toString() == "128x128@2");

        ImageSize size3("64x64");
        REQUIRE(size3.width == 64);
        REQUIRE(size3.height == 64);
        REQUIRE(size3.scale == 1);

        ImageSize size4("128x128@2");
        REQUIRE(size4.width == 128);
        REQUIRE(size4.height == 128);
        REQUIRE(size4.scale == 2);
    }

    SECTION("ImageSize ordering")
    {
        ImageSize small(48);
        ImageSize medium(64);
        ImageSize large(128);
        ImageSize mediumHiDPI(64, 64, 2);
        ImageSize largeHiDPI(128, 128, 2);

        REQUIRE(small < medium);
        REQUIRE(medium < large);
        REQUIRE(medium < mediumHiDPI); // Same size but higher scale

        REQUIRE(medium < largeHiDPI);
        REQUIRE(medium == ImageSize(64, 64, 1));
        REQUIRE_FALSE(medium == largeHiDPI);
    }
}

TEST_CASE("HintRegistry functionality", "[hintregistry]")
{
    using namespace ASGenerator;

    SECTION("Load hints registry")
    {
        g_autoptr(AscHint) hint = nullptr;
        g_autoptr(GError) error = nullptr;

        // tag must not exist at this point
        hint = asc_hint_new_for_tag("description-from-package", &error);
        REQUIRE(error != nullptr);
        REQUIRE(hint == nullptr);
        g_error_free(g_steal_pointer(&error));

        // Test loading the hints registry
        REQUIRE_NOTHROW(loadHintsRegistry());

        // after loading the registry, the tag should exist
        hint = asc_hint_new_for_tag("description-from-package", &error);
        if (error != nullptr)
            FAIL(std::format("Error creating hint: {}", error->message));
        REQUIRE(hint != nullptr);

        // Test that some common hint tags are loaded
        REQUIRE(asc_globals_hint_tag_severity("icon-not-found") != AS_ISSUE_SEVERITY_UNKNOWN);
        REQUIRE(asc_globals_hint_tag_severity("no-metainfo") != AS_ISSUE_SEVERITY_UNKNOWN);
        REQUIRE(asc_globals_hint_tag_severity("internal-error") != AS_ISSUE_SEVERITY_UNKNOWN);

        // Test severity retrieval
        auto severity = asc_globals_hint_tag_severity("icon-not-found");
        REQUIRE(severity != AS_ISSUE_SEVERITY_UNKNOWN);

        // Test explanation retrieval
        std::string explanation = asc_globals_hint_tag_explanation("icon-not-found");
        REQUIRE_FALSE(explanation.empty());
    }

    SECTION("Retrieve hint definition")
    {
        auto hdef = retrieveHintDef("icon-not-found");
        REQUIRE(hdef.tag == "icon-not-found");
        REQUIRE(hdef.severity == AS_ISSUE_SEVERITY_ERROR);
        REQUIRE_FALSE(hdef.explanation.empty());

        // Test non-existent hint
        auto emptyHdef = retrieveHintDef("non-existent-hint");
        REQUIRE(emptyHdef.tag.empty());
        REQUIRE(emptyHdef.severity == AS_ISSUE_SEVERITY_UNKNOWN);
        REQUIRE(emptyHdef.explanation.empty());
    }

    SECTION("Hint to JSON conversion")
    {
        std::unordered_map<std::string, std::string> vars = {
            {"test_key",    "test_value"   },
            {"another_key", "another_value"}
        };

        auto jsonStr = hintToJsonString("test-tag", vars);
        REQUIRE_FALSE(jsonStr.empty());
        REQUIRE(jsonStr != "{}");

        // Basic JSON validation - should contain our data
        REQUIRE(jsonStr.find("test-tag") != std::string::npos);
        REQUIRE(jsonStr.find("test_key") != std::string::npos);
        REQUIRE(jsonStr.find("test_value") != std::string::npos);
    }

    SECTION("Save hints registry to JSON file")
    {
        auto tempFile = fs::temp_directory_path() / "test-hints-registry.json";

        REQUIRE_NOTHROW(saveHintsRegistryToJsonFile(tempFile.string()));
        REQUIRE(fs::exists(tempFile));

        // Verify file has content
        auto fileSize = fs::file_size(tempFile);
        REQUIRE(fileSize > 0);

        // Clean up
        fs::remove(tempFile);
    }
}

TEST_CASE("GeneratorResult functionality", "[result]")
{
    using namespace ASGenerator;

    auto pkg = std::make_shared<DummyPackage>("foobar", "1.0.0", "amd64");

    SECTION("Basic GeneratorResult operations")
    {
        GeneratorResult result(pkg);

        // Test package ID
        REQUIRE(result.pkid() == "foobar/1.0.0/amd64");

        // Test package retrieval
        REQUIRE(result.getPackage() == pkg);
        REQUIRE(result.getResult() != nullptr);
    }

    SECTION("Add hints to result")
    {
        GeneratorResult result(pkg);

        // Ensure hints registry is loaded
        loadHintsRegistry();

        // Add a hint with component ID
        std::unordered_map<std::string, std::string> vars = {
            {"icon_fname",      "test.png" },
            {"additional_info", "test data"}
        };

        bool stillValid = result.addHint("org.test.Component", "icon-not-found", vars);
        REQUIRE(stillValid == false);

        // Add a hint with simple message
        stillValid = result.addHint("org.test.Component2", "no-metainfo", "Test message");
        REQUIRE(stillValid);

        // Verify hints were added
        REQUIRE(result.hintsCount() > 0);
        REQUIRE(result.hasHint("org.test.Component", "icon-not-found"));
        REQUIRE(result.hasHint("org.test.Component2", "no-metainfo"));
    }

    SECTION("Generate hints JSON")
    {
        GeneratorResult result(pkg);
        loadHintsRegistry();

        // Add some hints
        const std::unordered_map<std::string, std::string> &vars = {
            {"rainbows", "yes"  },
            {"unicorns", "no"   },
            {"storage",  "towel"}
        };
        result.addHint("org.freedesktop.foobar.desktop", "desktop-entry-hidden-set", vars);
        result.addHint(
            "org.freedesktop.awesome-bar.desktop",
            "metainfo-validation-error",
            "Nothing is good without chocolate. Add some.");
        result.addHint(
            "org.freedesktop.awesome-bar.desktop",
            "screenshot-video-check-failed",
            "Frobnicate functionality is missing.");

        // Generate JSON
        auto jsonStr = result.hintsToJson();
        REQUIRE_FALSE(jsonStr.empty());

        // Basic validation
        INFO(jsonStr);
        REQUIRE(jsonStr.find("foobar/1.0.0/amd64") != std::string::npos);
        REQUIRE(jsonStr.find("org.freedesktop.awesome-bar.desktop") != std::string::npos);
        REQUIRE(jsonStr.find("screenshot-video-check-failed") != std::string::npos);
        REQUIRE(jsonStr.find("desktop-entry-hidden-set") != std::string::npos);
    }

    SECTION("Move semantics")
    {
        GeneratorResult result1(pkg);
        loadHintsRegistry();
        result1.addHint("test.component", "icon-not-found");

        // Test move constructor
        GeneratorResult result2 = std::move(result1);
        REQUIRE(result2.pkid() == "foobar/1.0.0/amd64");
        REQUIRE(result2.hintsCount() > 0);

        // Test move assignment
        GeneratorResult result3(pkg);
        result3 = std::move(result2);
        REQUIRE(result3.pkid() == "foobar/1.0.0/amd64");
        REQUIRE(result3.hintsCount() > 0);
    }
}

TEST_CASE("InjectedModifications", "[cptmodifiers]")
{
    auto dummySuite = std::make_shared<Suite>();
    dummySuite->name = "dummy";
    dummySuite->extraMetainfoDir = getTestSamplesDir() / "extra-metainfo";

    auto injMods = std::make_unique<InjectedModifications>();
    injMods->loadForSuite(std::move(dummySuite));

    REQUIRE(injMods->isComponentRemoved("com.example.removed"));
    REQUIRE_FALSE(injMods->isComponentRemoved("com.example.not_removed"));

    REQUIRE_FALSE(injMods->injectedCustomData("org.example.nodata").has_value());

    auto customData = injMods->injectedCustomData("org.example.newdata");
    REQUIRE(customData.has_value());
    REQUIRE(customData->at("earth") == "moon");
    REQUIRE(customData->at("mars") == "phobos");
    REQUIRE(customData->at("saturn") == "thrym");
}

TEST_CASE("Utils: UTF-8 sanitization", "[utils]")
{
    SECTION("Remove invalid characters")
    {
        std::string input = "Zipper est un outil\x14 pour extraire";
        std::string sanitized = Utils::sanitizeUtf8(input);

        REQUIRE(sanitized == "Zipper est un outil pour extraire");
        REQUIRE(sanitized.length() == input.length() - 1); // One character removed
    }

    SECTION("Preserve valid UTF-8 characters")
    {
        std::string input = "Café résumé naïve";
        std::string sanitized = Utils::sanitizeUtf8(input);

        REQUIRE(sanitized == input); // Should be unchanged
    }

    SECTION("Preserve valid control characters")
    {
        std::string input = "Valid text with tab\t, newline\n, and carriage return\r.";
        std::string sanitized = Utils::sanitizeUtf8(input);

        REQUIRE(sanitized == input); // Should be unchanged
    }

    SECTION("Remove multiple invalid control characters")
    {
        std::string input =
            "Text\x01with\x14invalid\x1F"
            "characters";
        std::string sanitized = Utils::sanitizeUtf8(input);

        REQUIRE(sanitized == "Textwithinvalidcharacters");
    }

    SECTION("Handle invalid UTF-8 sequences")
    {
        std::string input = "Valid text \xFF\xFE invalid UTF-8";
        std::string sanitized = Utils::sanitizeUtf8(input);

        REQUIRE(sanitized == "Valid text  invalid UTF-8");

        // Should be shorter due to removed invalid bytes
        REQUIRE(sanitized.length() < input.length());
    }

    SECTION("Preserve 4-byte UTF-8 emoji")
    {
        std::string input = "Hello 🌍 World! 😀";
        std::string sanitized = Utils::sanitizeUtf8(input);

        REQUIRE(sanitized == input); // Should preserve emoji characters
    }
}
