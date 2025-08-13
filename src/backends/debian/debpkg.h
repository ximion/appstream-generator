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

#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <memory>
#include <mutex>
#include <optional>

#include "../interfaces.h"
#include "../../utils.h"
#include "tagfile.h"

namespace ASGenerator
{

class ArchiveDecompressor;

/**
 * Helper class for simple deduplication of package descriptions
 * between packages of different architectures in memory.
 */
class DebPackageLocaleTexts
{
public:
    std::unordered_map<std::string, std::string> summary;     ///< map of localized package short summaries
    std::unordered_map<std::string, std::string> description; ///< map of localized package descriptions

    void setDescription(const std::string &text, const std::string &locale);
    void setSummary(const std::string &text, const std::string &locale);

private:
    mutable std::mutex m_mutex;
};

/**
 * Representation of a Debian binary package
 */
class DebPackage : public Package
{
public:
    DebPackage(
        const std::string &pname,
        const std::string &pver,
        const std::string &parch,
        std::shared_ptr<DebPackageLocaleTexts> l10nTexts = nullptr);
    ~DebPackage() override;

    // Package interface implementation
    std::string name() const override;
    std::string ver() const override;
    std::string arch() const override;
    std::string maintainer() const override;

    const std::unordered_map<std::string, std::string> &description() const override;
    const std::unordered_map<std::string, std::string> &summary() const override;

    std::string getFilename() override;
    const std::vector<std::string> &contents() override;
    std::vector<std::uint8_t> getFileData(const std::string &fname) override;

    void cleanupTemp() override;
    void finish() override;

    std::optional<GStreamer> gst() const override;

    // Debian-specific methods
    void setName(const std::string &s);
    void setVersion(const std::string &s);
    void setArch(const std::string &s);
    void setMaintainer(const std::string &maint);
    void setFilename(const std::string &fname);
    void setGst(const GStreamer &gst);

    void updateTmpDirPath();
    void setDescription(const std::string &text, const std::string &locale);
    void setSummary(const std::string &text, const std::string &locale);
    void setLocalizedTexts(std::shared_ptr<DebPackageLocaleTexts> l10nTexts);

    std::shared_ptr<DebPackageLocaleTexts> localizedTexts();

    void extractPackage(const std::string &dest = "");
    std::unique_ptr<TagFile> readControlInformation();

private:
    std::string m_pkgname;
    std::string m_pkgver;
    std::string m_pkgarch;
    std::string m_pkgmaintainer;
    std::shared_ptr<DebPackageLocaleTexts> m_descTexts;
    std::optional<GStreamer> m_gstreamer;

    bool m_contentsRead;
    std::vector<std::string> m_contentsL;

    fs::path m_tmpDir;
    std::unique_ptr<ArchiveDecompressor> m_controlArchive;
    std::unique_ptr<ArchiveDecompressor> m_dataArchive;

    std::string m_debFname;
    fs::path m_localDebFname;

    mutable std::mutex m_mutex;

    ArchiveDecompressor &openPayloadArchive();
    ArchiveDecompressor &openControlArchive();
};

} // namespace ASGenerator
