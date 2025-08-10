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

#include "utils.h"
#include "logging.h"
#include "iconhandler.h"

using namespace ASGenerator;

static struct TestSetup {
    TestSetup()
    {
        setVerbose(true);
    }
} testSetup;

TEST_CASE("IconHandler", "[IconHandler]")
{
    auto hicolorThemeIndex = getDataPath("hicolor-theme-index.theme");

    // Read theme index data
    std::vector<std::uint8_t> indexData;
    std::ifstream f(hicolorThemeIndex, std::ios::binary);
    REQUIRE(f.is_open());

    f.seekg(0, std::ios::end);
    indexData.resize(f.tellg());
    f.seekg(0, std::ios::beg);
    f.read(reinterpret_cast<char *>(indexData.data()), indexData.size());

    auto theme = std::make_unique<Theme>("hicolor", indexData);

    // Test matching icon filenames for accessories-calculator 48x48
    for (const auto &fname : theme->matchingIconFilenames("accessories-calculator", ImageSize(48))) {
        bool valid = false;
        if (fname.starts_with("/usr/share/icons/hicolor/48x48/"))
            valid = true;
        if (fname.starts_with("/usr/share/icons/hicolor/scalable/"))
            valid = true;
        REQUIRE(valid);

        // Check if icon is allowed format
        bool formatAllowed = IconHandler::iconAllowed(fname);
        if (fname.ends_with(".ico"))
            REQUIRE_FALSE(formatAllowed);
        else
            REQUIRE(formatAllowed);
    }

    // Test matching icon filenames for accessories-text-editor 192x192
    for (const auto &fname : theme->matchingIconFilenames("accessories-text-editor", ImageSize(192))) {
        bool validPath = false;
        if (fname.starts_with("/usr/share/icons/hicolor/192x192/"))
            validPath = true;
        if (fname.starts_with("/usr/share/icons/hicolor/256x256/"))
            validPath = true;
        if (fname.starts_with("/usr/share/icons/hicolor/512x512/"))
            validPath = true;
        if (fname.starts_with("/usr/share/icons/hicolor/scalable/"))
            validPath = true;

        REQUIRE(validPath);
    }
}

TEST_CASE("Theme parsing", "[Theme]")
{
    auto hicolorThemeIndex = getDataPath("hicolor-theme-index.theme");
    REQUIRE(std::filesystem::exists(hicolorThemeIndex));

    std::vector<std::uint8_t> indexData;
    std::ifstream f(hicolorThemeIndex, std::ios::binary);
    REQUIRE(f.is_open());

    f.seekg(0, std::ios::end);
    indexData.resize(f.tellg());
    f.seekg(0, std::ios::beg);
    f.read(reinterpret_cast<char *>(indexData.data()), indexData.size());

    auto theme = std::make_unique<Theme>("hicolor", indexData);

    REQUIRE(theme->name() == "hicolor");
    REQUIRE_FALSE(theme->directories().empty());

    // Test that we can find directories that match various sizes
    bool found16x16Match = false;
    bool found48x48Match = false;

    for (const auto &dir : theme->directories()) {
        // Check if we can find a directory that matches 16x16 (base size)
        if (theme->directoryMatchesSize(dir, ImageSize(16), false)) {
            found16x16Match = true;
        }
        // Check if we can find a directory that matches 48x48
        if (theme->directoryMatchesSize(dir, ImageSize(48), false)) {
            found48x48Match = true;
        }
    }

    REQUIRE(found16x16Match);
    REQUIRE(found48x48Match);
}
