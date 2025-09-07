/*
 * Copyright (C) 2019-2025 Matthias Klumpp <matthias@tenstral.net>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#define CATCH_CONFIG_MAIN
#include <catch2/catch_all.hpp>

#include <fstream>
#include <filesystem>
#include <regex>
#include <cstdlib>
#include <format>
#include <chrono>
#include <thread>
#include <memory>
#include <vector>

#include "logging.h"
#include "reportgenerator.h"
#include "datastore.h"
#include "config.h"
#include "backends/interfaces.h"
#include "backends/dummy/dummypkg.h"
#include "result.h"
#include "hintregistry.h"

using namespace ASGenerator;

static struct TestSetup {
    TestSetup()
    {
        setVerbose(true);
    }
} testSetup;

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
        m_htmlDir = m_tempDir / "html";
        m_mediaDir = m_tempDir / "media";

        fs::create_directories(m_dbDir);
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

        // Load the hints registry to avoid hint tag errors
        loadHintsRegistry();

        // Create report generator
        m_reportGen = std::make_unique<ReportGenerator>(m_dstore.get());
    }

    ~ReportGeneratorTestFixture()
    {
        m_reportGen.reset();
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
    fs::path m_htmlDir;
    fs::path m_mediaDir;
    fs::path m_templateDir;

    std::unique_ptr<DataStore> m_dstore;
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
        m_dstore->addStatistics(statsData);

        REQUIRE_NOTHROW(m_reportGen->exportStatistics());

        auto statsFile = m_htmlDir / "statistics.json";
        REQUIRE(fs::exists(statsFile));

        std::ifstream file(statsFile);
        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());

        REQUIRE(content.find("testsuite") != std::string::npos);
        REQUIRE(content.find("main") != std::string::npos);
        REQUIRE(content.find("errors") != std::string::npos);
        REQUIRE(content.find("warnings") != std::string::npos);
        REQUIRE(content.find("infos") != std::string::npos);
        REQUIRE(content.find("metadata") != std::string::npos);

        // Verify the actual numeric values are present
        REQUIRE(content.find(",1]") != std::string::npos);  // totalErrors: 1
        REQUIRE(content.find(",3]") != std::string::npos);  // totalWarnings: 3
        REQUIRE(content.find(",5]") != std::string::npos);  // totalInfos: 5
        REQUIRE(content.find(",10]") != std::string::npos); // totalMetadata: 10
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

        dsum.pkgSummaries["Test Maintainer"]["testpkg1"] = summary;

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
        mentry.archs = {"amd64"};
        mentry.data = "Type: desktop-application\nID: test.app.1\n";
        mentry.iconName = "test-icon.png";

        dsum.mdataEntries["testpkg1"]["1.0.0"]["test.gcid.1"] = mentry;

        // Create mock package summary with components
        ReportGenerator::PkgSummary summary;
        summary.pkgname = "testpkg1";
        summary.cpts = {"test.app.1 - 1.0.0"};

        dsum.pkgSummaries["Test Maintainer"]["testpkg1"] = summary;

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
        REQUIRE_NOTHROW(m_reportGen->updateIndexPages());

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
