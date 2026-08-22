/*
 * Copyright (C) 2025-2026 Matthias Klumpp <matthias@tenstral.net>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#include <catch2/catch_all.hpp>

#include <fstream>
#include <filesystem>
#include <string>
#include <algorithm>
#include <chrono>

#include "config.h"
#include "scopeguard.h"

using namespace ASGenerator;

/**
 * Write a configuration file with the given extra toplevel settings and suites
 * into a fresh workspace and load it into the global configuration.
 */
static void loadConfig(const fs::path &workspace, const std::string &extraToplevel, const std::string &suites)
{
    fs::create_directories(workspace);

    const auto configFile = workspace / "asgen-config.json";
    std::ofstream configStream(configFile);
    REQUIRE(configStream.is_open());

    configStream << R"({
    "ProjectName": "Test Project",
    "ArchiveRoot": "/tmp/archive",
    "Backend": "dummy",
    "WorkspaceDir": ")"
                 << workspace.string() << R"(",)" << extraToplevel << R"(
    "Suites": {)" << suites
                 << R"(}
})";
    configStream.close();

    Config::get().loadFromFile(configFile.string(), workspace.string());
}

/**
 * Fetch the image format that the loaded configuration selected for the given suite.
 */
static AscImageFormat suiteImageFormat(const std::string &name)
{
    const auto &suites = Config::get().suites;
    const auto it = std::ranges::find(suites, name, &Suite::name);
    REQUIRE(it != suites.end());
    return it->imageFormat;
}

TEST_CASE("Config: ImageFormat", "[config]")
{
    const auto tmpDir = fs::temp_directory_path() / "asgen_test_config"
                        / std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
    const auto cleanup = Utils::scopeGuard([&tmpDir]() {
        std::error_code ec;
        fs::remove_all(tmpDir, ec);
    });

    const std::string suites = R"(
        "inherit": {"sections": ["main"], "architectures": ["amd64"]},
        "override": {"imageFormat": "png", "sections": ["main"], "architectures": ["amd64"]})";

    SECTION("defaults to JPEG-XL")
    {
        loadConfig(tmpDir / "default", "", suites);

        REQUIRE(Config::get().imageFormat == ASC_IMAGE_FORMAT_JXL);
        REQUIRE(suiteImageFormat("inherit") == ASC_IMAGE_FORMAT_JXL);
        REQUIRE(suiteImageFormat("override") == ASC_IMAGE_FORMAT_PNG);
    }

    SECTION("suites inherit the global setting, but may override it")
    {
        loadConfig(tmpDir / "global-png", R"("ImageFormat": "png",)", suites);

        REQUIRE(Config::get().imageFormat == ASC_IMAGE_FORMAT_PNG);
        REQUIRE(suiteImageFormat("inherit") == ASC_IMAGE_FORMAT_PNG);
        REQUIRE(suiteImageFormat("override") == ASC_IMAGE_FORMAT_PNG);
    }

    SECTION("a suite may select JPEG-XL while the global default is PNG")
    {
        loadConfig(
            tmpDir / "suite-jxl",
            R"("ImageFormat": "png",)",
            R"(
        "modern": {"imageFormat": "jxl", "sections": ["main"], "architectures": ["amd64"]})");

        REQUIRE(Config::get().imageFormat == ASC_IMAGE_FORMAT_PNG);
        REQUIRE(suiteImageFormat("modern") == ASC_IMAGE_FORMAT_JXL);
    }

    SECTION("formats that we can not write are rejected")
    {
        // media can only ever be written as PNG or JPEG-XL, so anything else has to fall
        // back to the value it would have had otherwise instead of being passed on
        loadConfig(
            tmpDir / "bad-values",
            R"("ImageFormat": "webp",)",
            R"(
        "bad": {"imageFormat": "nonsense", "sections": ["main"], "architectures": ["amd64"]})");

        REQUIRE(Config::get().imageFormat == ASC_IMAGE_FORMAT_JXL);
        REQUIRE(suiteImageFormat("bad") == ASC_IMAGE_FORMAT_JXL);
    }
}
