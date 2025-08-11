/*
 * Copyright (C) 2019-2025 Matthias Klumpp <matthias@tenstral.net>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#define CATCH_CONFIG_MAIN
#include <catch2/catch_all.hpp>

#include <filesystem>
#include <algorithm>
#include <fstream>
#include <memory>

#include "logging.h"
#include "utils.h"
#include "backends/debian/debpkgindex.h"
#include "backends/debian/debpkg.h"
#include "backends/debian/tagfile.h"
#include "backends/debian/debutils.h"

using namespace ASGenerator;
namespace fs = std::filesystem;

static struct TestSetup {
    TestSetup()
    {
        setVerbose(true);
    }
} testSetup;

// Test-friendly wrapper class that exposes protected methods for testing
class TestableDebianPackageIndex : public DebianPackageIndex
{
public:
    TestableDebianPackageIndex(const std::string &dir)
        : DebianPackageIndex(dir)
    {
    }

    // Expose protected methods for testing
    using DebianPackageIndex::findTranslations;
    using DebianPackageIndex::getIndexFile;
    using DebianPackageIndex::packageDescToAppStreamDesc;
};

TEST_CASE("DebianPackageIndex: findTranslations", "[debian][debpkgindex]")
{
    auto samplesDir = getTestSamplesDir();
    auto debianSamplesDir = samplesDir / "debian";

    SECTION("Find translations for existing suite and section")
    {
        TestableDebianPackageIndex pi(debianSamplesDir.string());

        auto translations = pi.findTranslations("sid", "main");
        std::sort(translations.begin(), translations.end());

        // Expected translations
        std::vector<std::string> expected = {"en", "ca", "cs", "da", "de", "de_DE", "el",    "eo",    "es",
                                             "eu", "fi", "fr", "hr", "hu", "id",    "it",    "ja",    "km",
                                             "ko", "ml", "nb", "nl", "pl", "pt",    "pt_BR", "ro",    "ru",
                                             "sk", "sr", "sv", "tr", "uk", "vi",    "zh",    "zh_CN", "zh_TW"};
        std::sort(expected.begin(), expected.end());

        REQUIRE(translations == expected);
    }

    SECTION("Non-existent suite returns default translation")
    {
        TestableDebianPackageIndex pi(debianSamplesDir.string());
        auto translations = pi.findTranslations("nonexistent", "main");

        // Should return default "en" when InRelease is not found
        REQUIRE(translations.size() == 1);
        REQUIRE(translations[0] == "en");
    }
}

TEST_CASE("DebianPackageIndex: packageDescToAppStreamDesc", "[debian][debpkgindex]")
{
    auto samplesDir = getTestSamplesDir();
    auto debianSamplesDir = samplesDir / "debian";

    TestableDebianPackageIndex pi(debianSamplesDir.string());

    SECTION("Convert simple description")
    {
        std::vector<std::string> lines = {"This is a simple description.", "With a second line."};

        auto result = pi.packageDescToAppStreamDesc(lines);
        REQUIRE(result == "<p>This is a simple description. With a second line.</p>");
    }

    SECTION("Convert description with paragraph breaks")
    {
        std::vector<std::string> lines = {"First paragraph.", ".", "Second paragraph."};

        auto result = pi.packageDescToAppStreamDesc(lines);
        REQUIRE(result == "<p>First paragraph.</p>\n<p>Second paragraph.</p>");
    }

    SECTION("Convert description with markup escaping")
    {
        std::vector<std::string> lines = {"This has <special> & 'characters'."};

        auto result = pi.packageDescToAppStreamDesc(lines);
        REQUIRE(result == "<p>This has &lt;special&gt; &amp; &apos;characters&apos;.</p>");
    }
}

TEST_CASE("DebPackage: Basic operations", "[debian][debpkg]")
{
    SECTION("Package construction and basic properties")
    {
        DebPackage pkg("test-package", "1.0.0", "amd64");

        REQUIRE(pkg.name() == "test-package");
        REQUIRE(pkg.ver() == "1.0.0");
        REQUIRE(pkg.arch() == "amd64");
        REQUIRE(pkg.id() == "test-package/1.0.0/amd64");

        // Test property setters
        pkg.setName("new-package");
        pkg.setVersion("2.0.0");
        pkg.setArch("i386");

        REQUIRE(pkg.name() == "new-package");
        REQUIRE(pkg.ver() == "2.0.0");
        REQUIRE(pkg.arch() == "i386");
    }

    SECTION("Package maintainer")
    {
        DebPackage pkg("test-package", "1.0.0", "amd64");
        pkg.setMaintainer("Test User <test@example.com>");

        REQUIRE(pkg.maintainer() == "Test User <test@example.com>");
    }

    SECTION("Package filename handling")
    {
        DebPackage pkg("test-package", "1.0.0", "amd64");
        pkg.setFilename("/path/to/package.deb");

        // For local files, getFilename should return the same path
        REQUIRE(pkg.getFilename() == "/path/to/package.deb");
    }

    SECTION("GStreamer codec information")
    {
        DebPackage pkg("test-package", "1.0.0", "amd64");

        // Initially no GStreamer info
        REQUIRE_FALSE(pkg.gst().has_value());

        // Set GStreamer info
        std::vector<std::string> decoders = {"mp3", "ogg"};
        std::vector<std::string> encoders = {"wav"};
        GStreamer gst(decoders, encoders, {}, {}, {});

        pkg.setGst(gst);
        auto retrievedGst = pkg.gst();
        REQUIRE(retrievedGst.has_value());
        REQUIRE(retrievedGst->isNotEmpty());
    }
}

TEST_CASE("DebPackageLocaleTexts: Thread safety and functionality", "[debian][debpkg]")
{
    auto l10nTexts = std::make_shared<DebPackageLocaleTexts>();

    SECTION("Set and retrieve descriptions")
    {
        l10nTexts->setDescription("English description", "en");
        l10nTexts->setDescription("Deutsche Beschreibung", "de");

        REQUIRE(l10nTexts->description.at("en") == "English description");
        REQUIRE(l10nTexts->description.at("de") == "Deutsche Beschreibung");
    }

    SECTION("Set and retrieve summaries")
    {
        l10nTexts->setSummary("English summary", "en");
        l10nTexts->setSummary("Deutsche Zusammenfassung", "de");

        REQUIRE(l10nTexts->summary.at("en") == "English summary");
        REQUIRE(l10nTexts->summary.at("de") == "Deutsche Zusammenfassung");
    }

    SECTION("Shared localized texts between packages")
    {
        DebPackage pkg1("test-package", "1.0.0", "amd64", l10nTexts);
        DebPackage pkg2("test-package", "1.0.0", "i386", l10nTexts);

        l10nTexts->setDescription("Shared description", "en");

        // Both packages should have the same description
        REQUIRE(pkg1.description().at("en") == "Shared description");
        REQUIRE(pkg2.description().at("en") == "Shared description");
    }
}

TEST_CASE("TagFile: Debian control file parsing", "[debian][tagfile]")
{
    SECTION("Parse simple control data")
    {
        std::string controlData =
            "Package: test-package\n"
            "Version: 1.0.0\n"
            "Architecture: amd64\n"
            "Description: A test package\n"
            " This is a longer description\n"
            " that spans multiple lines.\n"
            "\n"
            "Package: another-package\n"
            "Version: 2.0.0\n";

        TagFile tf;
        tf.load(controlData);

        // First section
        REQUIRE(tf.readField("Package") == "test-package");
        REQUIRE(tf.readField("Version") == "1.0.0");
        REQUIRE(tf.readField("Architecture") == "amd64");

        auto description = tf.readField("Description");
        REQUIRE(description.find("A test package") != std::string::npos);
        REQUIRE(description.find("longer description") != std::string::npos);

        // Move to next section
        REQUIRE(tf.nextSection());
        REQUIRE(tf.readField("Package") == "another-package");
        REQUIRE(tf.readField("Version") == "2.0.0");

        // No more sections
        REQUIRE_FALSE(tf.nextSection());
    }

    SECTION("Handle missing fields gracefully")
    {
        std::string controlData = "Package: test-package\n";

        TagFile tf;
        tf.load(controlData);

        REQUIRE(tf.readField("Package") == "test-package");
        REQUIRE(tf.readField("NonExistent").empty());
    }

    SECTION("Parse empty control data")
    {
        TagFile tf;
        tf.load("");

        REQUIRE(tf.readField("Package").empty());
        REQUIRE_FALSE(tf.nextSection());
    }
}

TEST_CASE("Debian version comparison", "[debian][debutils]")
{
    SECTION("Simple version comparisons")
    {
        REQUIRE(compareVersions("1.0", "2.0") < 0);
        REQUIRE(compareVersions("2.0", "1.0") > 0);
        REQUIRE(compareVersions("1.0", "1.0") == 0);
    }

    SECTION("Version with epochs")
    {
        REQUIRE(compareVersions("1:1.0", "2.0") > 0);
        REQUIRE(compareVersions("2:1.0", "1:2.0") > 0);
        REQUIRE(compareVersions("1:1.0", "1:1.0") == 0);
    }

    SECTION("Version with revisions")
    {
        REQUIRE(compareVersions("1.0-1", "1.0-2") < 0);
        REQUIRE(compareVersions("1.0-2", "1.0-1") > 0);
        REQUIRE(compareVersions("1.0-1", "1.0-1") == 0);
    }

    SECTION("Complex version strings")
    {
        REQUIRE(compareVersions("1.0~beta1", "1.0") < 0);
        REQUIRE(compareVersions("1.0", "1.0+build1") < 0);
        REQUIRE(compareVersions("1.0-1ubuntu1", "1.0-1ubuntu2") < 0);
    }

    SECTION("Real-world examples")
    {
        REQUIRE(compareVersions("2.7.2-linux-1", "2.7.3-linux-1") < 0);
        REQUIRE(compareVersions("1:7.4.052-1ubuntu3", "1:7.4.052-1ubuntu3.1") < 0);
        REQUIRE(compareVersions("0.8.15-1", "0.8.15-1+deb8u1") < 0);
    }
}

TEST_CASE("DebianPackageIndex: Package loading and caching", "[debian][debpkgindex]")
{
    auto samplesDir = getTestSamplesDir();
    auto debianSamplesDir = samplesDir / "debian";
    auto chromodorisMainDir = debianSamplesDir / "dists" / "chromodoris" / "main" / "binary-amd64";

    SECTION("Load packages from index")
    {
        DebianPackageIndex pi(debianSamplesDir.string());

        // This should work if we have the proper structure
        REQUIRE_NOTHROW([&]() {
            auto packages = pi.packagesFor("chromodoris", "main", "amd64", false);
            INFO("Loaded " << packages.size() << " packages");
        }());
    }

    SECTION("Package caching works")
    {
        DebianPackageIndex pi(debianSamplesDir.string());

        // Load packages twice - second call should use cache
        auto packages1 = pi.packagesFor("chromodoris", "main", "amd64", false);
        auto packages2 = pi.packagesFor("chromodoris", "main", "amd64", false);

        // Should return the same packages (from cache)
        REQUIRE(packages1.size() == packages2.size());
    }

    SECTION("Release clears cache")
    {
        DebianPackageIndex pi(debianSamplesDir.string());

        auto packages1 = pi.packagesFor("chromodoris", "main", "amd64", false);
        pi.release();
        auto packages2 = pi.packagesFor("chromodoris", "main", "amd64", false);

        // Should still work after release
        REQUIRE(packages1.size() == packages2.size());
    }
}

TEST_CASE("DebianPackageIndex: Index file handling", "[debian][debpkgindex]")
{
    auto samplesDir = getTestSamplesDir();
    auto debianSamplesDir = samplesDir / "debian";

    SECTION("Get index file path")
    {
        TestableDebianPackageIndex pi(debianSamplesDir.string());

        REQUIRE_NOTHROW([&]() {
            auto indexPath = pi.getIndexFile("chromodoris", "main", "amd64");
            INFO("Index file path: " << indexPath);
        }());
    }
}

TEST_CASE("DebPackage: Package validation", "[debian][debpkg]")
{
    SECTION("Valid package")
    {
        DebPackage pkg("test-package", "1.0.0", "amd64");
        pkg.setMaintainer("Test User <test@example.com>");

        REQUIRE(pkg.isValid());
    }

    SECTION("Package with empty name is invalid")
    {
        DebPackage pkg("", "1.0.0", "amd64");
        REQUIRE_FALSE(pkg.isValid());
    }

    SECTION("Package with empty version is invalid")
    {
        DebPackage pkg("test-package", "", "amd64");
        REQUIRE_FALSE(pkg.isValid());
    }

    SECTION("Package with empty architecture is invalid")
    {
        DebPackage pkg("test-package", "1.0.0", "");
        REQUIRE_FALSE(pkg.isValid());
    }
}

TEST_CASE("DebPackage: Temporary directory handling", "[debian][debpkg]")
{
    SECTION("Temporary directory path generation")
    {
        DebPackage pkg("test-package", "1.0.0", "amd64");
        pkg.updateTmpDirPath();

        // Can't easily test the exact path without knowing the config,
        // but we can ensure it doesn't crash
        REQUIRE_NOTHROW(pkg.updateTmpDirPath());
    }

    SECTION("Cleanup operations don't crash")
    {
        DebPackage pkg("test-package", "1.0.0", "amd64");

        REQUIRE_NOTHROW(pkg.cleanupTemp());
        REQUIRE_NOTHROW(pkg.finish());
    }
}

TEST_CASE("DebPackage: Package string representation", "[debian][debpkg]")
{
    SECTION("toString method")
    {
        DebPackage pkg("test-package", "1.0.0", "amd64");

        auto str = pkg.toString();
        REQUIRE(str.find("test-package") != std::string::npos);
        REQUIRE(str.find("1.0.0") != std::string::npos);
        REQUIRE(str.find("amd64") != std::string::npos);
    }
}
