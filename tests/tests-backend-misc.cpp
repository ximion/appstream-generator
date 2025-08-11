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
#include <string>
#include <unordered_map>
#include <string_view>

#include "logging.h"
#include "utils.h"

#include "backends/archlinux/listfile.h"
#include "backends/rpmmd/rpmpkgindex.h"

using namespace ASGenerator;

static struct TestSetup {
    TestSetup()
    {
        setVerbose(true);
    }
} testSetup;

TEST_CASE("ListFile parsing", "[backend][archlinux]")
{
    SECTION("Parse Arch Linux package format")
    {
        const std::string testData = R"(%FILENAME%
a2ps-4.14-6-x86_64.pkg.tar.xz

%NAME%
a2ps

%VERSION%
4.14-6

%DESC%
An Any to PostScript filter

%CSIZE%
629320

%MULTILINE%
Blah1
BLUBB2
EtcEtcEtc3

%SHA256SUM%
a629a0e0eca0d96a97eb3564f01be495772439df6350600c93120f5ac7f3a1b5)";

        ListFile lf;
        std::vector<std::uint8_t> testDataBytes(testData.begin(), testData.end());
        lf.loadData(testDataBytes);

        // Test single-line entries
        REQUIRE(lf.getEntry("FILENAME") == "a2ps-4.14-6-x86_64.pkg.tar.xz");
        REQUIRE(lf.getEntry("VERSION") == "4.14-6");
        REQUIRE(lf.getEntry("NAME") == "a2ps");
        REQUIRE(lf.getEntry("DESC") == "An Any to PostScript filter");
        REQUIRE(lf.getEntry("CSIZE") == "629320");

        // Test multiline entry
        REQUIRE(lf.getEntry("MULTILINE") == "Blah1\nBLUBB2\nEtcEtcEtc3");

        // Test SHA256SUM entry
        REQUIRE(lf.getEntry("SHA256SUM") == "a629a0e0eca0d96a97eb3564f01be495772439df6350600c93120f5ac7f3a1b5");

        // Test non-existent entry
        REQUIRE(lf.getEntry("NONEXISTENT").empty());
    }
}

TEST_CASE("RPMPackageIndex", "[backend][rpmmd]")
{
    SECTION("Load RPM packages from test repository")
    {
        auto samplesDir = getTestSamplesDir();
        auto rpmmdDir = samplesDir / "rpmmd";

        RPMPackageIndex pi(rpmmdDir.string());
        auto pkgs = pi.packagesFor("26", "Workstation", "x86_64");

        REQUIRE(pkgs.size() == 4);
    }
}
