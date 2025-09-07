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

#include "debpkg.h"

#include <filesystem>
#include <fstream>
#include <regex>
#include <format>
#include <cassert>

#include "../../config.h"
#include "../../logging.h"
#include "../../zarchive.h"
#include "../../downloader.h"
#include "../../utils.h"

namespace ASGenerator
{

void DebPackageLocaleTexts::setDescription(const std::string &text, const std::string &locale)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    description[locale] = text;
}

void DebPackageLocaleTexts::setSummary(const std::string &text, const std::string &locale)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    summary[locale] = text;
}

DebPackage::DebPackage(
    const std::string &pname,
    const std::string &pver,
    const std::string &parch,
    std::shared_ptr<DebPackageLocaleTexts> l10nTexts)
    : m_pkgname(pname),
      m_pkgver(pver),
      m_pkgarch(parch),
      m_contentsRead(false),
      m_controlArchive(std::make_unique<ArchiveDecompressor>()),
      m_dataArchive(std::make_unique<ArchiveDecompressor>())
{
    if (l10nTexts)
        m_descTexts = l10nTexts;
    else
        m_descTexts = std::make_shared<DebPackageLocaleTexts>();

    updateTmpDirPath();
}

DebPackage::~DebPackage()
{
    finish();
}

std::string DebPackage::name() const
{
    return m_pkgname;
}

std::string DebPackage::ver() const
{
    return m_pkgver;
}

std::string DebPackage::arch() const
{
    return m_pkgarch;
}

std::string DebPackage::maintainer() const
{
    return m_pkgmaintainer;
}

const std::unordered_map<std::string, std::string> &DebPackage::description() const
{
    return m_descTexts->description;
}

const std::unordered_map<std::string, std::string> &DebPackage::summary() const
{
    return m_descTexts->summary;
}

void DebPackage::setName(const std::string &s)
{
    m_pkgname = s;
}

void DebPackage::setVersion(const std::string &s)
{
    m_pkgver = s;
}

void DebPackage::setArch(const std::string &s)
{
    m_pkgarch = s;
}

void DebPackage::setMaintainer(const std::string &maint)
{
    m_pkgmaintainer = maint;
}

void DebPackage::setFilename(const std::string &fname)
{
    m_debFname = fname;
    m_localDebFname.clear();
}

void DebPackage::setGst(const GStreamer &gst)
{
    m_gstreamer = gst;
}

std::optional<GStreamer> DebPackage::gst() const
{
    return m_gstreamer;
}

std::string DebPackage::getFilename()
{
    if (!m_localDebFname.empty())
        return m_localDebFname;

    if (Utils::isRemote(m_debFname)) {
        std::lock_guard<std::mutex> lock(m_mutex);
        auto &dl = Downloader::get();
        const fs::path path = m_tmpDir / fs::path(m_debFname).filename();
        dl.downloadFile(m_debFname, path.string());
        m_localDebFname = path;

        return m_localDebFname;
    } else {
        m_localDebFname = m_debFname;

        return m_debFname;
    }
}

void DebPackage::updateTmpDirPath()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    const auto &conf = Config::get();
    m_tmpDir = conf.getTmpDir() / std::format("{}-{}_{}", name(), ver(), arch());
}

void DebPackage::setDescription(const std::string &text, const std::string &locale)
{
    m_descTexts->setDescription(text, locale);
}

void DebPackage::setSummary(const std::string &text, const std::string &locale)
{
    m_descTexts->setSummary(text, locale);
}

void DebPackage::setLocalizedTexts(std::shared_ptr<DebPackageLocaleTexts> l10nTexts)
{
    assert(l10nTexts != nullptr);
    m_descTexts = l10nTexts;
}

std::shared_ptr<DebPackageLocaleTexts> DebPackage::localizedTexts()
{
    return m_descTexts;
}

ArchiveDecompressor &DebPackage::openPayloadArchive()
{
    if (m_dataArchive->isOpen())
        return *m_dataArchive;

    ArchiveDecompressor ad;
    // extract the payload to a temporary location first
    ad.open(getFilename());
    fs::create_directories(m_tmpDir);

    const std::regex dataRegex(R"(data\.*)");
    auto files = ad.extractFilesByRegex(dataRegex, m_tmpDir);
    if (files.empty()) {
        throw std::runtime_error(
            std::format("Unable to find the payload tarball in Debian package: {}", getFilename()));
    }
    const std::string dataArchiveFname = files[0];

    m_dataArchive->open(dataArchiveFname, m_tmpDir / "data");
    m_dataArchive->setOptimizeRepeatedReads(true);
    return *m_dataArchive;
}

void DebPackage::extractPackage(const std::string &dest)
{
    std::lock_guard<std::mutex> lock(m_mutex);

    fs::path extractPath = dest;
    if (extractPath.empty())
        extractPath = m_tmpDir / name();

    if (!fs::exists(extractPath))
        fs::create_directories(extractPath);

    auto &pa = openPayloadArchive();
    pa.extractArchive(extractPath);
}

ArchiveDecompressor &DebPackage::openControlArchive()
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_controlArchive->isOpen())
            return *m_controlArchive;
    }

    const auto fname = getFilename();
    std::lock_guard<std::mutex> lock(m_mutex);

    ArchiveDecompressor ad;
    // extract the payload to a temporary location first
    ad.open(fname);
    fs::create_directories(m_tmpDir);

    const std::regex controlRegex(R"(control\.*)");
    auto files = ad.extractFilesByRegex(controlRegex, m_tmpDir);
    if (files.empty()) {
        throw std::runtime_error(std::format("Unable to find control data in Debian package: {}", getFilename()));
    }
    const std::string controlArchiveFname = files[0];

    m_controlArchive->open(controlArchiveFname);
    return *m_controlArchive;
}

std::vector<std::uint8_t> DebPackage::getFileData(const std::string &fname)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    auto &pa = openPayloadArchive();
    return pa.readData(fname);
}

const std::vector<std::string> &DebPackage::contents()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_contentsRead)
        return m_contentsL;

    if (m_pkgname.ends_with("icon-theme")) {
        // the md5sums file does not contain symbolic links - while that is okay-ish for regular
        // packages, it is not acceptable for icon themes, since those rely on symlinks to provide
        // aliases for certain icons. So, use the slow method for reading contents information here.

        auto &pa = openPayloadArchive();
        m_contentsL = pa.readContents();
        m_contentsRead = true;
        return m_contentsL;
    }

    // use the md5sums file of the .deb control archive to determine
    // the contents of this package.
    // this is way faster than going through the payload directly, and
    // has the same accuracy.
    auto &ca = openControlArchive();
    std::vector<std::uint8_t> md5sumsData;
    try {
        md5sumsData = ca.readData("./md5sums");
    } catch (const std::exception &e) {
        logWarning("Could not read md5sums file for package {}: {}", id(), e.what());
        return m_contentsL;
    }

    std::string md5sums(md5sumsData.begin(), md5sumsData.end());
    m_contentsL.clear();
    m_contentsL.reserve(20);

    const auto lines = Utils::splitString(md5sums, '\n');
    for (const auto &line : lines) {
        // Split on double space - need to use a different approach since Utils::splitString only takes char
        const auto doublespace = line.find("  ");
        if (doublespace == std::string::npos || doublespace == 0)
            continue;

        // The filename is everything after the first double space
        const std::string filename = line.substr(doublespace + 2);
        if (!filename.empty()) {
            m_contentsL.push_back("/" + filename);
        }
    }

    m_contentsRead = true;
    return m_contentsL;
}

std::unique_ptr<TagFile> DebPackage::readControlInformation()
{
    auto &ca = openControlArchive();
    std::vector<std::uint8_t> controlData;
    try {
        controlData = ca.readData("./control");
    } catch (const std::exception &e) {
        logError("Could not read control file for package {}: {}", id(), e.what());
        return nullptr;
    }

    std::string controlStr(controlData.begin(), controlData.end());

    auto tf = std::make_unique<TagFile>();
    tf->load(controlStr);
    return tf;
}

void DebPackage::cleanupTemp()
{
    std::lock_guard<std::mutex> lock(m_mutex);

    if (m_controlArchive->isOpen())
        m_controlArchive->close();
    if (m_dataArchive->isOpen())
        m_dataArchive->close();

    if (m_tmpDir.empty())
        return;

    try {
        if (fs::exists(m_tmpDir)) {
            /* Whenever we delete the temporary directory, we need to
             * forget about the local file too, since (if it's remote) that
             * was downloaded into there. */
            m_localDebFname.clear();
            fs::remove_all(m_tmpDir);
        }
    } catch (const std::exception &e) {
        // we ignore any error
        logWarning("Unable to remove temporary directory: {} ({})", m_tmpDir.string(), e.what());
    }
}

void DebPackage::finish()
{
    cleanupTemp();
}

} // namespace ASGenerator
