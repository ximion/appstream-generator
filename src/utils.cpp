/*
 * Copyright (C) 2016-2022 Matthias Klumpp <matthias@tenstral.net>
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

#include "defines.h"
#include "utils.h"

#include <algorithm>
#include <random>
#include <regex>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <ranges>
#include <string_view>
#include <filesystem>
#include <cstring>
#include <cerrno>

#include <unistd.h>
#include <sys/stat.h>

#include <tbb/parallel_for_each.h>

#include "logging.h"
#include "downloader.h"

namespace ASGenerator
{

inline constexpr const char *DESKTOP_GROUP = "Desktop Entry";

ImageSize::ImageSize(const std::string &str)
    : width(0),
      height(0),
      scale(0)
{
    auto sep = str.find('x');
    if (sep == std::string::npos || sep == 0)
        return;

    auto scaleSep = str.find('@');
    width = std::stoul(str.substr(0, sep));

    if (scaleSep == std::string::npos) {
        scale = 1;
        height = std::stoul(str.substr(sep + 1));
    } else {
        if (scaleSep == str.length() - 1)
            throw std::runtime_error("Image size string must not end with '@'.");
        height = std::stoul(str.substr(sep + 1, scaleSep - sep - 1));
        scale = std::stoul(str.substr(scaleSep + 1));
    }
}

std::string ImageSize::toString() const
{
    if (scale == 1)
        return std::format("{}x{}", width, height);
    else
        return std::format("{}x{}@{}", width, height, scale);
}

std::uint32_t ImageSize::toInt() const
{
    if (width > height)
        return width * scale;
    return height * scale;
}

namespace Utils
{
std::string randomString(std::uint32_t len)
{
    if (len == 0)
        len = 1;

    const std::string chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<> dis(0, chars.size() - 1);

    std::string result;
    result.reserve(len);

    for (std::uint32_t i = 0; i < len; ++i) {
        result += chars[dis(gen)];
    }

    return result;
}

bool localeValid(const std::string &locale)
{
    return locale != "x-test" && locale != "xx";
}

bool isTopLevelDomain(const std::string &value)
{
    if (value.empty())
        return false;

    return as_utils_is_tld(value.c_str());
}

std::optional<std::string> getCidFromGlobalID(const std::string &gcid)
{
    std::vector<std::string> parts;
    std::stringstream ss(gcid);
    std::string item;

    while (std::getline(ss, item, '/'))
        parts.push_back(item);

    if (parts.size() != 4)
        return std::nullopt;

    if (isTopLevelDomain(parts[0])) {
        return std::format("{}.{}.{}", parts[0], parts[1], parts[2]);
    }

    return parts[2];
}

void hardlink(const std::string &srcFname, const std::string &destFname)
{
    if (::link(srcFname.c_str(), destFname.c_str()) != 0)
        throw std::runtime_error(std::format("Unable to create link: {}", std::strerror(errno)));
}

void copyDir(const std::string &srcDir, const std::string &destDir, bool useHardlinks)
{
    fs::path srcPath(srcDir);
    fs::path destPath(destDir);

    if (!fs::exists(destPath))
        fs::create_directories(destPath);

    if (!fs::is_directory(destPath))
        throw std::runtime_error(std::format("{} is not a directory", destPath.string()));

    if (!fs::is_directory(srcPath)) {
        if (useHardlinks) {
            hardlink(srcPath.string(), destPath.string());
        } else {
            fs::copy_file(srcPath, destPath);
        }

        return;
    }

    std::vector<fs::path> files;

    // Create directory structure and collect files
    for (const auto &entry : fs::recursive_directory_iterator(srcPath)) {
        const auto relativePath = fs::relative(entry.path(), srcPath);
        const auto destFile = destPath / relativePath;

        if (entry.is_directory()) {
            fs::create_directories(destFile);
        } else if (entry.is_regular_file()) {
            files.push_back(entry.path());
        }
    }

    // Copy or hardlink files
    tbb::parallel_for_each(files.begin(), files.end(), [&](const fs::path &file) {
        const auto relativePath = fs::relative(file, srcPath);
        const auto destFile = destPath / relativePath;

        if (useHardlinks) {
            hardlink(file.string(), destFile.string());
        } else {
            fs::copy_file(file, destFile);
        }
    });
}

fs::path getExecutableDir()
{
    char result[PATH_MAX];
    ssize_t count = readlink("/proc/self/exe", result, PATH_MAX);
    if (count == -1)
        throw std::runtime_error("Failed to get executable path");

    std::string exePath(result, count);
    return fs::path(exePath).parent_path();
}

fs::path getDataPath(const std::string &fname)
{
    static const auto exeDirName = getExecutableDir();

    // useful for testing
    if (!exeDirName.string().starts_with("/usr")) {
        auto resPath = exeDirName / ".." / ".." / "data" / fname;
        if (fs::exists(resPath))
            return fs::canonical(resPath);

        resPath = exeDirName / ".." / ".." / ".." / "data" / fname;
        if (fs::exists(resPath))
            return fs::canonical(resPath);

        resPath = exeDirName / ".." / ".." / ".." / ".." / "data" / fname;
        if (fs::exists(resPath))
            return fs::canonical(resPath);
    }

    auto resPath = fs::path(DATADIR) / fname;
    if (fs::exists(resPath))
        return resPath;

    resPath = exeDirName / ".." / "data" / fname;
    if (fs::exists(resPath))
        return resPath;

    resPath = fs::path("data") / fname;
    if (fs::exists(resPath))
        return resPath;

    // Uh, let's just give up
    return fs::path("/usr") / "share" / "appstream" / fname;
}

bool existsAndIsDir(const std::string &path)
{
    return fs::exists(path) && fs::is_directory(path);
}

std::vector<std::uint8_t> stringArrayToByteArray(const std::vector<std::string> &strArray)
{
    std::vector<std::uint8_t> result;
    result.reserve(strArray.size() * 2); // make a guess, we will likely need much more space

    for (const auto &s : strArray) {
        const auto *data = reinterpret_cast<const std::uint8_t *>(s.data());
        result.insert(result.end(), data, data + s.size());
    }

    return result;
}

bool isRemote(const std::string &uri)
{
    static const std::regex uriRegex(R"(^(https?|ftps?)://)");
    return std::regex_search(uri, uriRegex);
}

static std::vector<std::string> splitLines(const std::string &text)
{
    std::vector<std::string> lines;
    std::stringstream ss(text);
    std::string line;

    while (std::getline(ss, line))
        lines.push_back(line);

    return lines;
}

std::vector<std::string> getTextFileContents(const std::string &path, std::uint32_t maxTryCount, Downloader *downloader)
{
    if (isRemote(path)) {
        Downloader *dl = downloader;
        if (dl == nullptr)
            dl = &Downloader::get();

        return dl->downloadTextLines(path, maxTryCount);
    } else {
        if (!fs::exists(path))
            throw std::runtime_error(std::format("No such file '{}'", path));

        std::ifstream file(path);
        if (!file.is_open())
            throw std::runtime_error(std::format("Failed to open file '{}'", path));

        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());

        return splitLines(content);
    }
}

std::vector<std::uint8_t> getFileContents(const std::string &path, std::uint32_t maxTryCount, Downloader *downloader)
{
    if (isRemote(path)) {
        Downloader *dl = downloader;
        if (dl == nullptr)
            dl = &Downloader::get();

        return dl->download(path, maxTryCount);
    } else {
        if (!fs::exists(path))
            throw std::runtime_error(std::format("No such file '{}'", path));

        std::ifstream file(path, std::ios::binary);
        if (!file.is_open())
            throw std::runtime_error(std::format("Failed to open file '{}'", path));

        std::vector<std::uint8_t> data;

        file.seekg(0, std::ios::end);
        data.resize(file.tellg());
        file.seekg(0, std::ios::beg);

        file.read(reinterpret_cast<char *>(data.data()), data.size());

        return data;
    }
}

fs::path getTestSamplesDir()
{
    auto path = fs::path(__FILE__).parent_path().parent_path() / "tests" / "samples";
    return path;
}

std::optional<AsIcon *> componentGetRawIcon(AsComponent *cpt)
{
    AsIcon *iconLocal = nullptr;
    GPtrArray *iconsArr = as_component_get_icons(cpt);

    for (guint i = 0; i < iconsArr->len; i++) {
        AsIcon *icon = AS_ICON(g_ptr_array_index(iconsArr, i));
        if (as_icon_get_kind(icon) == AS_ICON_KIND_STOCK)
            return icon;

        if (as_icon_get_kind(icon) == AS_ICON_KIND_LOCAL)
            iconLocal = icon;
    }

    // only return local icon if we had no stock icon
    if (iconLocal)
        return iconLocal;

    return std::nullopt;
}

std::string filenameFromURI(const std::string &uri)
{
    fs::path path(uri);
    std::string bname = path.filename().string();

    auto qInd = bname.find('?');
    if (qInd != std::string::npos)
        bname = bname.substr(0, qInd);

    auto hInd = bname.find('#');
    if (hInd != std::string::npos)
        bname = bname.substr(0, hInd);

    return bname;
}

std::string escapeXml(const std::string &s) noexcept
{
    g_autofree gchar *escapedStr = g_markup_escape_text(s.c_str(), s.size());
    return std::string(escapedStr);
}

std::string toLower(const std::string &s)
{
    std::string out;
    out.resize(s.size());
    std::ranges::transform(s, out.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });

    return out;
}

std::string rtrimString(const std::string &s)
{
    std::string result = s;
    result.erase(
        std::find_if(
            result.rbegin(),
            result.rend(),
            [](unsigned char ch) {
                return !std::isspace(ch);
            })
            .base(),
        result.end());

    return result;
}

std::string trimString(std::string_view s) noexcept
{
    const char *b = s.data();
    const char *e = b + s.size();

    auto is_space = [](unsigned char c) constexpr noexcept {
        return c == ' ' || (c >= '\t' && c <= '\r');
    };

    while (b != e && is_space(static_cast<unsigned char>(*b)))
        ++b;
    while (e != b && is_space(static_cast<unsigned char>(e[-1])))
        --e;

    return std::string(b, e);
}

std::string joinStrings(const std::vector<std::string> &strings, const std::string &delimiter)
{
    if (strings.empty())
        return "";

    if (strings.size() == 1)
        return strings[0];

    std::string result = strings[0];
    for (size_t i = 1; i < strings.size(); ++i) {
        result += delimiter + strings[i];
    }

    return result;
}

std::vector<std::string> splitString(const std::string &s, char delimiter)
{
    std::vector<std::string> result;
    std::stringstream ss(s);
    std::string item;

    while (std::getline(ss, item, delimiter)) {
        result.push_back(item);
    }

    return result;
}

bool dirEmpty(const std::string &dir)
{
    if (!fs::exists(dir))
        return true;

    for (const auto &entry : fs::directory_iterator(dir)) {
        (void)entry;  // Suppress unused variable warning
        return false; // Found at least one entry
    }

    return true;
}
} // namespace Utils

} // namespace ASGenerator
