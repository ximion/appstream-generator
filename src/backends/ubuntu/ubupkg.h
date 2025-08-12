/*
 * Copyright (C) 2016-2020 Canonical Ltd
 * Author: Iain Lane <iain.lane@canonical.com>
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
#include <glib.h>

#include "../debian/debpkg.h"

namespace ASGenerator
{

class UbuntuPackage;

/**
 * A helper class that provides functions to work with language packs
 * used in Ubuntu.
 */
class LanguagePackProvider
{
public:
    explicit LanguagePackProvider(const fs::path &globalTmpDir);

    void addLanguagePacks(const std::vector<std::shared_ptr<UbuntuPackage>> &langpacks);
    void clear();
    std::unordered_map<std::string, std::string> getTranslations(const std::string &domain, const std::string &text);

private:
    std::vector<std::shared_ptr<UbuntuPackage>> m_langpacks;
    fs::path m_globalTmpDir;
    fs::path m_langpackDir;
    fs::path m_localeDir;
    std::string m_localedefExe;
    std::vector<std::string> m_langpackLocales;

    mutable std::mutex m_mutex;

    void extractLangpacks();
    std::unordered_map<std::string, std::string> getTranslationsPrivate(
        const std::string &domain,
        const std::string &text);
};

/**
 * Ubuntu package - extends Debian package with language pack support
 */
class UbuntuPackage : public DebPackage
{
public:
    UbuntuPackage(
        const std::string &pname,
        const std::string &pver,
        const std::string &parch,
        std::shared_ptr<DebPackageLocaleTexts> l10nTexts = nullptr);

    void setLanguagePackProvider(std::shared_ptr<LanguagePackProvider> provider);

    std::unordered_map<std::string, std::string> getDesktopFileTranslations(
        GKeyFile *desktopFile,
        const std::string &text) override;

    bool hasDesktopFileTranslations() const override;

private:
    std::shared_ptr<LanguagePackProvider> m_langpackProvider;
};

} // namespace ASGenerator
