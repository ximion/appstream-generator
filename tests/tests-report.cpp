/*
 * Copyright (C) 2019-2025 Matthias Klumpp <matthias@tenstral.net>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#include <catch2/catch_all.hpp>

#include <algorithm>
#include <fstream>
#include <filesystem>
#include <regex>
#include <cstdlib>
#include <format>
#include <chrono>
#include <thread>
#include <memory>
#include <vector>

#include "reportgenerator.h"
#include "datastore.h"
#include "statsstore.h"
#include "config.h"
#include "backends/interfaces.h"
#include "backends/dummy/dummypkg.h"
#include "result.h"
#include "hintregistry.h"
#include "zarchive.h"

#include <nlohmann/json.hpp>

using namespace ASGenerator;

// Test fixture for report generator tests
class ReportGeneratorTestFixture
{
public:
    ReportGeneratorTestFixture()
    {
        // Create temporary directories for testing
        m_tempDir = fs::temp_directory_path() / "asgen_test"
                    / std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
        fs::create_directories(m_tempDir);

        m_dbDir = m_tempDir / "db";
        m_statsDbDir = m_tempDir / "stats-db";
        m_htmlDir = m_tempDir / "html";
        m_mediaDir = m_tempDir / "media";

        fs::create_directories(m_dbDir);
        fs::create_directories(m_statsDbDir);
        fs::create_directories(m_htmlDir);
        fs::create_directories(m_mediaDir);

        // Use the default templates
        m_templateDir = Utils::getDataPath("templates/default");

        // Create a test configuration file and load configuration
        auto configFile = createTestConfig();
        Config::get().loadFromFile(configFile.string(), m_tempDir.string(), (m_tempDir / "data").string());

        // Initialize datastore
        m_dstore = std::make_unique<DataStore>();
        m_dstore->open(m_dbDir.string(), m_mediaDir.string());

        // Initialize statistics database
        m_sstore = std::make_unique<StatsStore>();
        m_sstore->open(m_statsDbDir.string());

        // Load the hints registry to avoid hint tag errors
        loadHintsRegistry();

        // Create report generator
        m_reportGen = std::make_unique<ReportGenerator>(m_dstore.get(), m_sstore.get());
    }

    ~ReportGeneratorTestFixture()
    {
        m_reportGen.reset();
        m_sstore.reset();
        m_dstore.reset();

        // Clean up temporary directory
        std::error_code ec;
        fs::remove_all(m_tempDir, ec);
    }

protected:
    std::vector<std::shared_ptr<Package>> createTestPackages()
    {
        std::vector<std::shared_ptr<Package>> packages;

        auto pkg1 = std::make_shared<DummyPackage>("testpkg1", "1.0.0", "amd64");
        pkg1->setMaintainer("Test Maintainer <test@example.com>");
        pkg1->setFilename("testpkg1_1.0.0_amd64.deb");
        packages.push_back(std::move(pkg1));

        auto pkg2 = std::make_shared<DummyPackage>("testpkg2", "2.0.0", "amd64");
        pkg2->setMaintainer("Another Maintainer <another@example.com>");
        pkg2->setFilename("testpkg2_2.0.0_amd64.deb");
        packages.push_back(std::move(pkg2));

        auto pkg3 = std::make_shared<DummyPackage>("testpkg3", "1.5.0", "riscv64");
        pkg3->setMaintainer("Test Maintainer <test@example.com>");
        pkg3->setFilename("testpkg3_1.5.0_i386.deb");
        packages.push_back(std::move(pkg3));

        return packages;
    }

    void addTestData()
    {
        // Add some test metadata to the datastore
        m_dstore->setMetadata(DataType::YAML, "test.gcid.1", R"(
Type: desktop-application
ID: test.app.1
Name:
  C: Test Application 1
Summary:
  C: A test application
)");

        // Add some test hints for testpkg1
        m_dstore->setHints("testpkg1/1.0.0/amd64", R"({
  "hints": {
    "test.app.1": [
      {
        "tag": "missing-desktop-file",
        "vars": {
          "filename": "test.desktop"
        }
      }
    ]
  }
})");

        // Add test hints for testpkg2 so it gets processed by preprocessInformation
        m_dstore->setHints("testpkg2/2.0.0/amd64", R"({
  "hints": {
    "test.app.2": [
      {
        "tag": "icon-not-found",
        "vars": {
          "icon_fname": "test-icon.png"
        }
      }
    ]
  }
})");
    }

    fs::path createTestConfig()
    {
        // Create a minimal test configuration
        auto configFile = m_tempDir / "test-config.json";
        std::ofstream configStream(configFile);

        configStream << R"({
    "ProjectName": "Test Project",
    "ArchiveRoot": "/tmp/archive",
    "WorkspaceDir": ")"
                     << m_tempDir.string() << R"(",
    "MediaBaseUrl": "https://example.com/media",
    "HtmlBaseUrl": "https://example.com/html",
    "TemplateDir": ")"
                     << m_templateDir.string() << R"(",
    "ExportDirs": {
        "Html": ")" << m_htmlDir.string()
                     << R"(",
        "Media": ")" << m_mediaDir.string()
                     << R"("
    },
    "Backend": "dummy",
    "Suites": {
        "testsuite": {
            "sections": ["main"],
            "architectures": ["amd64", "i386"]
        }
    }
})";
        configStream.close();

        return configFile;
    }

protected:
    fs::path m_tempDir;
    fs::path m_dbDir;
    fs::path m_statsDbDir;
    fs::path m_htmlDir;
    fs::path m_mediaDir;
    fs::path m_templateDir;

    std::unique_ptr<DataStore> m_dstore;
    std::unique_ptr<StatsStore> m_sstore;
    std::unique_ptr<ReportGenerator> m_reportGen;
};

TEST_CASE_METHOD(ReportGeneratorTestFixture, "ReportGenerator::preprocessInformation")
{
    addTestData();

    auto packages = createTestPackages();

    SECTION("Data preprocessing")
    {
        auto dsum = m_reportGen->preprocessInformation("testsuite", "main", packages);

        REQUIRE(!dsum.pkgSummaries.empty());
        REQUIRE(!dsum.hintEntries.empty());

        // Check that we have the expected maintainer
        REQUIRE(dsum.pkgSummaries.count("Test Maintainer <test@example.com>") > 0);
        REQUIRE(dsum.pkgSummaries.count("Another Maintainer <another@example.com>") > 0);

        // Check hints are processed
        REQUIRE(dsum.hintEntries.count("testpkg1") > 0);
        REQUIRE(dsum.hintEntries.count("testpkg2") > 0);
    }
}

TEST_CASE_METHOD(ReportGeneratorTestFixture, "ReportGenerator::preprocessInformation - component counting")
{
    // The same package can be at a different version on every architecture (think binNMUs),
    // while providing the very same components. A component is counted once, no matter how
    // many package versions and architectures we run into it in.
    const std::vector<std::pair<std::string, std::string>> pkgVariants = {
        {"2.4.1-1",    "amd64"},
        {"2.4.1-1+b1", "arm64"},
        {"2.4.1-1",    "i386" },
    };
    const std::vector<std::string> componentIds = {"org.example.one", "org.example.two", "org.example.three"};

    std::vector<std::shared_ptr<Package>> packages;
    for (const auto &[version, arch] : pkgVariants) {
        auto pkg = std::make_shared<DummyPackage>("multicpt", version, arch);
        pkg->setMaintainer("Test Maintainer <test@example.com>");

        GeneratorResult gres(pkg);
        for (const auto &cid : componentIds) {
            g_autoptr(AsComponent) cpt = as_component_new();
            as_component_set_kind(cpt, AS_COMPONENT_KIND_DESKTOP_APP);
            as_component_set_id(cpt, cid.c_str());
            as_component_set_name(cpt, cid.c_str(), "C");
            as_component_set_summary(cpt, "A test application", "C");
            gres.addComponent(cpt);
        }
        m_dstore->addGeneratorResult(DataType::YAML, gres, false);
        REQUIRE(m_dstore->getGCIDsForPackage(gres.pkid()).size() == componentIds.size());

        packages.push_back(std::move(pkg));
    }

    // one component gains an issue only on the last architecture we look at, the other two
    // have the very same issues everywhere
    for (const auto &[version, arch] : pkgVariants) {
        std::string hints = R"({"hints": {
            "org.example.one": [{"tag": "icon-not-found", "vars": {"icon_fname": "one.png"}},
                                {"tag": "icon-scaled-up", "vars": {"icon_name": "one.png"}}],
            "org.example.two": [{"tag": "description-from-package"}])";
        if (arch == "i386")
            hints += R"(, "org.example.three": [{"tag": "icon-too-small", "vars": {"icon_name": "three.png"}}])";
        hints += "}}";
        m_dstore->setHints(std::format("multicpt/{}/{}", version, arch), hints);
    }

    auto dsum = m_reportGen->preprocessInformation("testsuite", "main", packages);

    REQUIRE(dsum.totalMetadata == static_cast<std::int64_t>(componentIds.size()));
    REQUIRE(dsum.countedGcids.size() == componentIds.size());

    // 2 errors (icon-not-found, icon-too-small), 1 warning (icon-scaled-up) and
    // 1 info (description-from-package), each counted exactly once
    REQUIRE(dsum.totalErrors == 2);
    REQUIRE(dsum.totalWarnings == 1);
    REQUIRE(dsum.totalInfos == 1);

    // the section totals are the sum of what the individual package pages show
    const auto &summary = dsum.pkgSummaries.at("Test Maintainer <test@example.com>").at("multicpt");
    REQUIRE(summary.errorCount == dsum.totalErrors);
    REQUIRE(summary.warningCount == dsum.totalWarnings);
    REQUIRE(summary.infoCount == dsum.totalInfos);

    // hints found on several architectures list all of them, and only once each
    const auto &hintEntries = dsum.hintEntries.at("multicpt");
    REQUIRE(hintEntries.size() == componentIds.size());
    auto sharedArchs = hintEntries.at("org.example.one").archs;
    std::ranges::sort(sharedArchs);
    REQUIRE(sharedArchs == std::vector<std::string>{"amd64", "arm64", "i386"});
    REQUIRE(hintEntries.at("org.example.three").archs == std::vector<std::string>{"i386"});

    // every component is known once, and lists all architectures it was found on
    const auto &entries = dsum.mdataEntries.at("multicpt");
    REQUIRE(entries.size() == componentIds.size());
    for (const auto &[gcid, entry] : entries) {
        auto archs = entry.archs;
        std::ranges::sort(archs);
        REQUIRE(archs == std::vector<std::string>{"amd64", "arm64", "i386"});
        REQUIRE(entry.version == "2.4.1-1");
    }

    // Every component ends up in exactly one bucket. All three made it into the metadata
    // here, so nothing is rejected: "two" only has an info, which leaves it perfectly
    // usable and therefore clean, while "one" and "three" are counted with the warnings.
    REQUIRE(dsum.cptsClean == 1);
    REQUIRE(dsum.cptsWarning == 2);
    REQUIRE(dsum.cptsRejected == 0);
    REQUIRE(dsum.cptsClean + dsum.cptsWarning == dsum.totalMetadata);
}

TEST_CASE_METHOD(ReportGeneratorTestFixture, "ReportGenerator::preprocessInformation - component classification")
{
    std::vector<std::shared_ptr<Package>> packages;

    // a package whose component came out without any issue at all
    {
        auto pkg = std::make_shared<DummyPackage>("cleanpkg", "1.0", "amd64");
        pkg->setMaintainer("Test Maintainer <test@example.com>");

        GeneratorResult gres(pkg);
        g_autoptr(AsComponent) cpt = as_component_new();
        as_component_set_kind(cpt, AS_COMPONENT_KIND_DESKTOP_APP);
        as_component_set_id(cpt, "org.example.clean");
        as_component_set_name(cpt, "Clean", "C");
        as_component_set_summary(cpt, "A test application", "C");
        gres.addComponent(cpt);
        m_dstore->addGeneratorResult(DataType::YAML, gres, false);

        packages.push_back(std::move(pkg));
    }

    // a package whose component only has a warning, but was still exported
    {
        auto pkg = std::make_shared<DummyPackage>("warnpkg", "1.0", "amd64");
        pkg->setMaintainer("Test Maintainer <test@example.com>");

        GeneratorResult gres(pkg);
        g_autoptr(AsComponent) cpt = as_component_new();
        as_component_set_kind(cpt, AS_COMPONENT_KIND_DESKTOP_APP);
        as_component_set_id(cpt, "org.example.warn");
        as_component_set_name(cpt, "Warn", "C");
        as_component_set_summary(cpt, "A test application", "C");
        gres.addComponent(cpt);
        m_dstore->addGeneratorResult(DataType::YAML, gres, false);
        m_dstore->setHints(
            gres.pkid(),
            R"({"hints": {"org.example.warn": [{"tag": "icon-scaled-up", "vars": {"icon_name": "w.png"}}]}})");

        packages.push_back(std::move(pkg));
    }

    // a package which produced no metadata at all: its component hit an error and was
    // dropped, so it is counted as an error even though it has no metadata entry
    {
        auto pkg = std::make_shared<DummyPackage>("brokenpkg", "1.0", "amd64");
        pkg->setMaintainer("Test Maintainer <test@example.com>");

        m_dstore->setHints(
            pkg->id(),
            R"({"hints": {"org.example.broken": [{"tag": "icon-not-found", "vars": {"icon_fname": "b.png"}}]}})");

        packages.push_back(std::move(pkg));
    }

    auto dsum = m_reportGen->preprocessInformation("testsuite", "main", packages);

    REQUIRE(dsum.totalMetadata == 2);
    REQUIRE(dsum.cptsClean == 1);
    REQUIRE(dsum.cptsWarning == 1);
    REQUIRE(dsum.cptsRejected == 1);

    // an error means we got no component, so the rejected one is not part of the metadata
    // count - together they are everything we attempted
    REQUIRE(dsum.cptsClean + dsum.cptsWarning == dsum.totalMetadata);
    REQUIRE(dsum.cptsClean + dsum.cptsWarning + dsum.cptsRejected == 3);
}

TEST_CASE_METHOD(ReportGeneratorTestFixture, "ReportGenerator::renderPage")
{
    SECTION("Basic page rendering")
    {
        inja::json context;
        context["suite"] = "testsuite";
        context["section"] = "main";

        // Add the suites array that the main template expects
        inja::json suites = inja::json::array();
        inja::json suite;
        suite["suite"] = "testsuite";
        suites.push_back(suite);
        context["suites"] = suites;

        // Add empty oldsuites array
        context["oldsuites"] = inja::json::array();

        REQUIRE_NOTHROW(m_reportGen->renderPage("main", "test_main", context));

        // Check that the file was created
        auto outputFile = m_htmlDir / "test_main.html";
        REQUIRE(fs::exists(outputFile));

        // Read and verify basic content
        std::ifstream file(outputFile);
        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        REQUIRE(content.find("Test Project") != std::string::npos);
    }

    SECTION("Page rendering with complex context")
    {
        inja::json context;
        context["suite"] = "testsuite";
        context["section"] = "main";
        context["package_name"] = "testpkg";

        inja::json entries = inja::json::array();
        inja::json entry;
        entry["component_id"] = "test.app.1";
        entry["has_errors"] = true;
        entry["has_warnings"] = false;
        entry["has_infos"] = false;

        // Add the architectures field that the template expects
        inja::json architectures = inja::json::array();
        inja::json arch;
        arch["arch"] = "amd64";
        architectures.push_back(arch);
        entry["architectures"] = architectures;

        inja::json errors = inja::json::array();
        inja::json error;
        error["error_tag"] = "test-error";
        error["error_description"] = "Test error description";
        errors.push_back(error);
        entry["errors"] = errors;

        entries.push_back(entry);
        context["entries"] = entries;

        REQUIRE_NOTHROW(m_reportGen->renderPage("issues_page", "test_issues", context));

        auto outputFile = m_htmlDir / "test_issues.html";
        REQUIRE(fs::exists(outputFile));
    }
}

TEST_CASE_METHOD(ReportGeneratorTestFixture, "ReportGenerator Statistics")
{
    SECTION("Export statistics")
    {
        // Add some test statistics first
        std::unordered_map<std::string, std::variant<std::int64_t, std::string, double>> statsData = {
            {"suite",         std::string("testsuite")},
            {"section",       std::string("main")     },
            {"totalInfos",    std::int64_t(5)         },
            {"totalWarnings", std::int64_t(3)         },
            {"totalErrors",   std::int64_t(1)         },
            {"totalMetadata", std::int64_t(10)        }
        };
        m_sstore->addStatistics(statsData);

        REQUIRE_NOTHROW(m_reportGen->exportStatistics(m_reportGen->collectStatistics()));

        auto statsFile = m_htmlDir / "testsuite" / "main" / "statistics.json.gz";
        REQUIRE(fs::exists(statsFile));
        const auto content = decompressFile(statsFile.string());

        REQUIRE(content.find("errors") != std::string::npos);
        REQUIRE(content.find("warnings") != std::string::npos);
        REQUIRE(content.find("infos") != std::string::npos);
        REQUIRE(content.find("metadata") != std::string::npos);
    }

    SECTION("Export per-section statistics")
    {
        // The section pages only ever draw their own data, so each of them gets its own
        // file instead of everyone downloading the history of the whole archive.
        std::unordered_map<std::string, std::variant<std::int64_t, std::string, double>> statsData = {
            {"suite",         std::string("testsuite")},
            {"section",       std::string("main")     },
            {"totalInfos",    std::int64_t(5)         },
            {"totalWarnings", std::int64_t(3)         },
            {"totalErrors",   std::int64_t(1)         },
            {"totalMetadata", std::int64_t(10)        },
            {"cptsClean",     std::int64_t(8)         },
            {"cptsWarning",   std::int64_t(2)         },
            {"cptsRejected",  std::int64_t(2)         }
        };
        m_sstore->addStatistics(statsData);

        REQUIRE_NOTHROW(m_reportGen->exportStatistics(m_reportGen->collectStatistics()));

        auto sectionStatsFile = m_htmlDir / "testsuite" / "main" / "statistics.json.gz";
        REQUIRE(fs::exists(sectionStatsFile));

        const auto data = nlohmann::json::parse(decompressFile(sectionStatsFile.string()));

        // the timestamps are shared by all series and only stored once
        REQUIRE(data.contains("time"));
        REQUIRE(data["time"].is_array());
        REQUIRE(data["time"].size() >= 1);

        for (const auto &key : {"metadata", "errors", "warnings", "infos", "cpts_rejected"}) {
            REQUIRE(data.contains(key));
            REQUIRE(data[key].size() == data["time"].size());
        }

        REQUIRE(data["metadata"].back() == 10);
        REQUIRE(data["errors"].back() == 1);
        REQUIRE(data["warnings"].back() == 3);
        REQUIRE(data["infos"].back() == 5);
        REQUIRE(data["cpts_clean"].back() == 8);
        REQUIRE(data["cpts_rejected"].back() == 2);
    }
}

TEST_CASE_METHOD(ReportGeneratorTestFixture, "ReportGenerator render pages with mock data")
{
    SECTION("Process packages for suite/section")
    {
        auto packages = createTestPackages();

        REQUIRE_NOTHROW(m_reportGen->processFor("testsuite", "main", packages));

        // Check that the section directory structure was created
        auto sectionDir = m_htmlDir / "testsuite" / "main";
        REQUIRE(fs::exists(sectionDir));
    }

    SECTION("Render pages with hint entries")
    {
        ReportGenerator::DataSummary dsum;

        // Create mock hint entry
        ReportGenerator::HintEntry hentry;
        hentry.identifier = "test.component.1";
        hentry.archs = {"amd64", "i386"};
        hentry.errors = {
            {"error-tag", "Error message"}
        };
        hentry.warnings = {
            {"warning-tag", "Warning message"}
        };
        hentry.infos = {
            {"info-tag", "Info message"}
        };

        dsum.hintEntries["testpkg1"]["test.component.1"] = std::move(hentry);

        // Create mock package summary
        ReportGenerator::PkgSummary summary;
        summary.pkgname = "testpkg1";
        summary.errorCount = 1;
        summary.warningCount = 1;
        summary.infoCount = 1;

        dsum.pkgSummaries["Test Maintainer"]["testpkg1"] = std::move(summary);

        REQUIRE_NOTHROW(m_reportGen->renderPagesFor("testsuite", "main", dsum));

        // Check that issue pages were created
        auto issuesIndex = m_htmlDir / "testsuite" / "main" / "issues" / "index.html";
        REQUIRE(fs::exists(issuesIndex));

        auto issuesPage = m_htmlDir / "testsuite" / "main" / "issues" / "testpkg1.html";
        REQUIRE(fs::exists(issuesPage));

        // Verify content
        std::ifstream file(issuesPage);
        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());

        REQUIRE(content.find("test.component.1") != std::string::npos);
        REQUIRE(content.find("Error message") != std::string::npos);
        REQUIRE(content.find("Warning message") != std::string::npos);
        REQUIRE(content.find("Info message") != std::string::npos);
    }

    SECTION("Render pages with metadata entries")
    {
        ReportGenerator::DataSummary dsum;

        // Create mock metadata entry
        ReportGenerator::MetadataEntry mentry;
        mentry.kind = AS_COMPONENT_KIND_DESKTOP_APP;
        mentry.identifier = "test.app.1";
        mentry.version = "1.0.0";
        mentry.archs = {"amd64"};
        mentry.data = "Type: desktop-application\nID: test.app.1\n";
        mentry.iconName = "test-icon.png";

        dsum.mdataEntries["testpkg1"]["test.gcid.1"] = std::move(mentry);

        // Create mock package summary with components
        ReportGenerator::PkgSummary summary;
        summary.pkgname = "testpkg1";
        summary.cpts = {"test.app.1 - 1.0.0"};

        dsum.pkgSummaries["Test Maintainer"]["testpkg1"] = std::move(summary);

        REQUIRE_NOTHROW(m_reportGen->renderPagesFor("testsuite", "main", dsum));

        // Check that metainfo pages were created
        auto metainfoIndex = m_htmlDir / "testsuite" / "main" / "metainfo" / "index.html";
        REQUIRE(fs::exists(metainfoIndex));

        auto metainfoPage = m_htmlDir / "testsuite" / "main" / "metainfo" / "testpkg1.html";
        REQUIRE(fs::exists(metainfoPage));

        // Verify content
        std::ifstream file(metainfoPage);
        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());

        REQUIRE(content.find("test.app.1 - 1.0.0") != std::string::npos);
        REQUIRE(content.find("Type: desktop-application") != std::string::npos);
    }

    SECTION("Render section index page")
    {
        ReportGenerator::DataSummary dsum;
        dsum.totalMetadata = 10;
        dsum.totalInfos = 5;
        dsum.totalWarnings = 3;
        dsum.totalErrors = 1;

        REQUIRE_NOTHROW(m_reportGen->renderPagesFor("testsuite", "main", dsum));

        auto sectionIndex = m_htmlDir / "testsuite" / "main" / "index.html";
        REQUIRE(fs::exists(sectionIndex));

        // Verify statistics are rendered
        std::ifstream file(sectionIndex);
        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());

        // Check for text that's actually in the section_page.html template
        REQUIRE(
            content.find("valid components")
            != std::string::npos); // From the template: "{{metainfo_count}} valid components"
        REQUIRE(content.find("errors") != std::string::npos);   // From the template
        REQUIRE(content.find("warnings") != std::string::npos); // From the template
    }

    SECTION("Update index pages")
    {
        REQUIRE_NOTHROW(m_reportGen->updateIndexPages(m_reportGen->collectStatistics()));

        // Check that main index was created
        auto mainIndex = m_htmlDir / "index.html";
        REQUIRE(fs::exists(mainIndex));

        // Verify content contains expected elements
        std::ifstream file(mainIndex);
        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());

        // Check for text that's actually in the templates
        REQUIRE(content.find("Generated by") != std::string::npos);        // From base.html footer
        REQUIRE(content.find("appstream-generator") != std::string::npos); // From base.html footer
    }
}
