/*
 * Copyright (C) 2019-2025 Matthias Klumpp <matthias@tenstral.net>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#define CATCH_CONFIG_MAIN
#include <catch2/catch_all.hpp>

#include <filesystem>
#include <string>

#include "logging.h"
#include "utils.h"
#include "config.h"
#include "engine.h"

using namespace ASGenerator;

static struct TestSetup {
    TestSetup()
    {
        setVerbose(true);
    }
} testSetup;

TEST_CASE("Engine with test data", "[engine][integration]")
{
    auto tempDir = fs::temp_directory_path() / std::format("asgen-test-{}", randomString(8));
    fs::create_directories(tempDir);
    auto samplesDir = getTestSamplesDir();

    SECTION("Test init with Debian backend")
    {
        auto debianSamplesDir = samplesDir / "debian";

        auto &config = Config::get();
        config.setWorkspaceDir("/tmp");
        config.backend = Backend::Debian;
        config.archiveRoot = debianSamplesDir.string();

        REQUIRE_NOTHROW([]() {
            Engine engine;
        }());
    }

    fs::remove_all(tempDir);
}

TEST_CASE("Engine package info functionality", "[engine]")
{
    auto tempDir = fs::temp_directory_path() / std::format("asgen-test-{}", randomString(8));
    fs::create_directories(tempDir);

    auto &config = Config::get();
    config.backend = Backend::Dummy;
    config.setWorkspaceDir("/tmp");
    config.archiveRoot = (getTestSamplesDir() / "debian").string();

    Engine engine;

    SECTION("Print package info with invalid ID format")
    {
        // Test with malformed package ID (should return false)
        REQUIRE_FALSE(engine.printPackageInfo("invalid-package-id"));
        REQUIRE_FALSE(engine.printPackageInfo("too/many/slashes/here"));
        REQUIRE_FALSE(engine.printPackageInfo("notEnoughSlashes"));
    }

    SECTION("Print package info with valid ID format")
    {
        // Test with properly formatted package ID (even if package doesn't exist)
        // This should return true as the format is correct, even if no data is found
        REQUIRE(engine.printPackageInfo("package/1.0.0/amd64"));
        REQUIRE(engine.printPackageInfo("test-pkg/2.1.0/i386"));
    }

    fs::remove_all(tempDir);
}
