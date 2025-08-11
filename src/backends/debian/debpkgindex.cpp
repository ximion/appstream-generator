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

#include "debpkgindex.h"

#include <filesystem>
#include <fstream>
#include <regex>
#include <format>
#include <execution>

#include "../../config.h"
#include "../../logging.h"
#include "../../utils.h"
#include "../../datastore.h"
#include "debutils.h"

namespace ASGenerator
{

DebianPackageIndex::DebianPackageIndex(const std::string &dir)
    : m_rootDir(dir)
{
    m_pkgCache.clear();
    if (!isRemote(dir) && !fs::exists(dir))
        throw std::runtime_error(std::format("Directory '{}' does not exist.", dir));

    const auto &conf = Config::get();
    m_tmpDir = conf.getTmpDir() / fs::path(dir).filename();
}

void DebianPackageIndex::release()
{
    m_pkgCache.clear();
    m_l10nTextIndex.clear();
    m_indexChanged.clear();
}

std::vector<std::string> DebianPackageIndex::findTranslations(const std::string &suite, const std::string &section)
{
    const std::string inRelease = (fs::path(m_rootDir) / "dists" / suite / "InRelease").string();
    const std::regex translationRegex(std::format(R"({}/i18n/Translation-(\w+)$)", section));

    std::unordered_set<std::string> translations;
    try {
        const auto inReleaseContents = getTextFileContents(inRelease);

        for (const auto &entry : inReleaseContents) {
            std::smatch match;
            if (std::regex_search(entry, match, translationRegex))
                translations.insert(match[1].str());
        }
    } catch (const std::exception &ex) {
        logWarning("Could not get {}, will assume 'en' is available.", inRelease);
        return {"en"};
    }

    return std::vector<std::string>(translations.begin(), translations.end());
}

std::string DebianPackageIndex::packageDescToAppStreamDesc(const std::vector<std::string> &lines)
{
    // TODO: We actually need a Markdown-ish parser here if we want
    // to support listings in package descriptions properly.
    std::string description = "<p>";

    bool first = true;
    for (const auto &line : lines) {
        const auto trimmedLine = trimString(line);
        if (trimmedLine == ".") {
            description += "</p>\n<p>";
            first = true;
            continue;
        }

        if (first)
            first = false;
        else
            description += " ";

        description += escapeXml(trimmedLine);
    }
    description += "</p>";

    return description;
}

void DebianPackageIndex::loadPackageLongDescs(
    std::unordered_map<std::string, std::shared_ptr<DebPackage>> &pkgs,
    const std::string &suite,
    const std::string &section)
{
    const auto langs = findTranslations(suite, section);
    logDebug("Found translations for: {}", joinStrings(langs, ", "));

    for (const auto &lang : langs) {
        std::string fname;
        const std::string fullPath =
            (fs::path("dists") / suite / section / "i18n" / std::format("Translation-{}.{}", lang, "{}")).string();

        try {
            fname = downloadIfNecessary(m_rootDir, m_tmpDir, fullPath);
        } catch (const std::exception &ex) {
            logDebug("No translations for {} in {}/{}", lang, suite, section);
            continue;
        }

        TagFile tagf;
        tagf.open(fname);

        do {
            const auto pkgname = tagf.readField("Package");
            const auto rawDesc = tagf.readField(std::format("Description-{}", lang));
            if (pkgname.empty() || rawDesc.empty())
                continue;

            auto it = pkgs.find(pkgname);
            if (it == pkgs.end())
                continue;

            auto pkg = it->second;
            const std::string textPkgId = std::format("{}/{}", pkg->name(), pkg->ver());

            std::shared_ptr<DebPackageLocaleTexts> l10nTexts;
            auto l10nIt = m_l10nTextIndex.find(textPkgId);
            if (l10nIt != m_l10nTextIndex.end()) {
                // we already fetched this information
                l10nTexts = l10nIt->second;
                pkg->setLocalizedTexts(l10nTexts);
            } else {
                // read new localizations
                l10nTexts = pkg->localizedTexts();
                m_l10nTextIndex[textPkgId] = l10nTexts;
            }

            const auto lines = splitString(rawDesc, '\n');
            if (lines.size() < 2)
                continue;

            if (lang == "en")
                l10nTexts->setSummary(lines[0], "C");
            l10nTexts->setSummary(lines[0], lang);

            // Skip the first line (summary) for description
            std::vector<std::string> descLines(lines.begin() + 1, lines.end());
            const std::string description = packageDescToAppStreamDesc(descLines);

            if (lang == "en")
                l10nTexts->setDescription(description, "C");
            l10nTexts->setDescription(description, lang);

            pkg->setLocalizedTexts(l10nTexts);
        } while (tagf.nextSection());
    }
}

std::string DebianPackageIndex::getIndexFile(
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    const std::string path = (fs::path("dists") / suite / section / std::format("binary-{}", arch)).string();
    return downloadIfNecessary(m_rootDir, m_tmpDir, (fs::path(path) / "Packages.{}").string());
}

std::shared_ptr<DebPackage> DebianPackageIndex::newPackage(
    const std::string &name,
    const std::string &ver,
    const std::string &arch)
{
    return std::make_shared<DebPackage>(name, ver, arch);
}

std::vector<std::shared_ptr<DebPackage>> DebianPackageIndex::loadPackages(
    const std::string &suite,
    const std::string &section,
    const std::string &arch,
    bool withLongDescs)
{
    auto indexFname = getIndexFile(suite, section, arch);
    if (!fs::exists(indexFname)) {
        logWarning("Archive package index file '{}' does not exist.", indexFname);
        return {};
    }

    TagFile tagf;
    tagf.open(indexFname);
    logDebug("Opened: {}", indexFname);

    std::unordered_map<std::string, std::shared_ptr<DebPackage>> pkgs;

    do {
        const auto name = tagf.readField("Package");
        const auto ver = tagf.readField("Version");
        const auto fname = tagf.readField("Filename");
        const auto pkgArch = tagf.readField("Architecture");
        const auto rawDesc = tagf.readField("Description");

        if (name.empty())
            continue;

        // sanity check: We only allow arch:all mixed in with packages from other architectures
        std::string actualArch = (pkgArch != "all") ? arch : pkgArch;

        auto pkg = newPackage(name, ver, actualArch);
        pkg->setFilename((fs::path(m_rootDir) / fname).string());
        pkg->setMaintainer(tagf.readField("Maintainer"));

        if (!rawDesc.empty()) {
            // parse old-style descriptions
            const auto dSplit = splitString(rawDesc, '\n');
            if (dSplit.size() >= 2) {
                pkg->setSummary(dSplit[0], "C");

                std::vector<std::string> descLines(dSplit.begin() + 1, dSplit.end());
                const std::string description = packageDescToAppStreamDesc(descLines);
                pkg->setDescription(description, "C");
            }
        }

        // Parse GStreamer information
        auto splitAndTrim = [](const std::string &str) -> std::vector<std::string> {
            if (str.empty())
                return {};
            auto parts = splitString(str, ';');
            for (auto &part : parts) {
                part = trimString(part);
            }
            return parts;
        };

        const auto decoders = splitAndTrim(tagf.readField("Gstreamer-Decoders"));
        const auto encoders = splitAndTrim(tagf.readField("Gstreamer-Encoders"));
        const auto elements = splitAndTrim(tagf.readField("Gstreamer-Elements"));
        const auto uri_sinks = splitAndTrim(tagf.readField("Gstreamer-Uri-Sinks"));
        const auto uri_sources = splitAndTrim(tagf.readField("Gstreamer-Uri-Sources"));

        GStreamer gst(decoders, encoders, elements, uri_sinks, uri_sources);
        if (gst.isNotEmpty())
            pkg->setGst(gst);

        if (!pkg->isValid()) {
            logWarning("Found invalid package ({})! Skipping it.", pkg->toString());
            continue;
        }

        // filter out the most recent package version in the packages list
        auto existingIt = pkgs.find(name);
        if (existingIt != pkgs.end()) {
            if (compareVersions(existingIt->second->ver(), pkg->ver()) > 0)
                continue;
        }

        pkgs[name] = pkg;
    } while (tagf.nextSection());

    // load long descriptions
    if (withLongDescs)
        loadPackageLongDescs(pkgs, suite, section);

    std::vector<std::shared_ptr<DebPackage>> result;
    result.reserve(pkgs.size());
    for (const auto &[name, pkg] : pkgs) {
        result.push_back(pkg);
    }

    return result;
}

std::vector<std::shared_ptr<Package>> DebianPackageIndex::packagesFor(
    const std::string &suite,
    const std::string &section,
    const std::string &arch,
    bool withLongDescs)
{
    const std::string id = std::format("{}/{}/{}", suite, section, arch);
    auto it = m_pkgCache.find(id);
    if (it == m_pkgCache.end()) {
        auto pkgs = loadPackages(suite, section, arch, withLongDescs);
        std::vector<std::shared_ptr<Package>> packagePtrs;
        packagePtrs.reserve(pkgs.size());
        for (const auto &pkg : pkgs) {
            packagePtrs.push_back(std::static_pointer_cast<Package>(pkg));
        }
        m_pkgCache[id] = packagePtrs;
        return packagePtrs;
    }

    return it->second;
}

std::shared_ptr<Package> DebianPackageIndex::packageForFile(
    const std::string &fname,
    const std::string &suite,
    const std::string &section)
{
    auto pkg = newPackage("", "", "");
    pkg->setFilename(fname);

    auto tf = pkg->readControlInformation();
    if (!tf)
        throw std::runtime_error(std::format("Unable to read control information for package {}", fname));

    pkg->setName(tf->readField("Package"));
    pkg->setVersion(tf->readField("Version"));
    pkg->setArch(tf->readField("Architecture"));

    if (pkg->name().empty() || pkg->ver().empty() || pkg->arch().empty())
        throw std::runtime_error(std::format("Unable to get control data for package {}", fname));

    const std::string rawDesc = tf->readField("Description");
    const auto dSplit = splitString(rawDesc, '\n');
    if (dSplit.size() >= 2) {
        pkg->setSummary(dSplit[0], "C");

        std::vector<std::string> descLines(dSplit.begin() + 1, dSplit.end());
        const std::string description = packageDescToAppStreamDesc(descLines);
        pkg->setDescription(description, "C");
    }

    // ensure we have a meaningful temporary directory name
    pkg->updateTmpDirPath();

    return std::static_pointer_cast<Package>(pkg);
}

bool DebianPackageIndex::hasChanges(
    std::shared_ptr<DataStore> dstore,
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    auto indexFname = getIndexFile(suite, section, arch);
    // if the file doesn't exist, we will emit a warning later anyway, so we just ignore this here
    if (!fs::exists(indexFname))
        return true;

    // check our cache on whether the index had changed
    auto cacheIt = m_indexChanged.find(indexFname);
    if (cacheIt != m_indexChanged.end())
        return cacheIt->second;

    const auto mtime = fs::last_write_time(indexFname);
    const auto currentTime = std::chrono::duration_cast<std::chrono::seconds>(mtime.time_since_epoch()).count();

    auto repoInfo = dstore->getRepoInfo(suite, section, arch);

    // Update mtime in repo info when we exit this function
    auto updateRepoInfo = [&]() {
        repoInfo.data["mtime"] = static_cast<std::int64_t>(currentTime);
        dstore->setRepoInfo(suite, section, arch, repoInfo);
    };

    auto mtimeIt = repoInfo.data.find("mtime");
    if (mtimeIt == repoInfo.data.end()) {
        m_indexChanged[indexFname] = true;
        updateRepoInfo();
        return true;
    }

    const auto pastTime = std::get<std::int64_t>(mtimeIt->second);
    if (pastTime != currentTime) {
        m_indexChanged[indexFname] = true;
        updateRepoInfo();
        return true;
    }

    m_indexChanged[indexFname] = false;
    updateRepoInfo();
    return false;
}

} // namespace ASGenerator
