/*
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
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

#include "logging.h"
#include "zarchive.h"
#include "utils.h"

using namespace ASGenerator;
namespace fs = std::filesystem;

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
    std::string archive = fs::path(getTestSamplesDir()) / "test.tar.xz";
    REQUIRE(fs::exists(archive));
    ArchiveDecompressor ar;

    // Create a temporary directory
    std::string tmpdir = fs::temp_directory_path() / fs::path("asgenXXXXXX");
    std::vector<char> ctmpdir(tmpdir.begin(), tmpdir.end());
    ctmpdir.push_back('\0');
    char *mkdtemp_result = mkdtemp(ctmpdir.data());
    REQUIRE(mkdtemp_result != nullptr);
    tmpdir = std::string(mkdtemp_result);
    auto cleanup = [&tmpdir](void*) {
        fs::remove_all(tmpdir);
    };
    std::unique_ptr<void, decltype(cleanup)> guard((void*)1, cleanup);

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
