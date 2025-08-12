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

#include "ubupkg.h"

#include <filesystem>
#include <fstream>
#include <format>
#include <algorithm>
#include <execution>
#include <clocale>
#include <cstring>
#include <libintl.h>
#include <unordered_set>

#include <tbb/parallel_for.h>
#include <tbb/blocked_range.h>

#include "../../logging.h"
#include "../../utils.h"

namespace ASGenerator
{

LanguagePackProvider::LanguagePackProvider(const fs::path &globalTmpDir)
    : m_globalTmpDir(globalTmpDir),
      m_langpackDir(globalTmpDir / "langpacks"),
      m_localeDir(m_langpackDir / "locales")
{
    g_autofree gchar *localedefExe = g_find_program_in_path("localedef");
    if (localedefExe)
        m_localedefExe = localedefExe;
    if (m_localedefExe.empty())
        logWarning("localedef executable not found in PATH");
}

void LanguagePackProvider::addLanguagePacks(const std::vector<std::shared_ptr<UbuntuPackage>> &langpacks)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_langpacks.insert(m_langpacks.end(), langpacks.begin(), langpacks.end());
}

void LanguagePackProvider::clear()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_langpacks.clear();
}

void LanguagePackProvider::extractLangpacks()
{
    if (fs::exists(m_langpackDir))
        return; // Already extracted

    std::unordered_set<std::string> extracted;

    fs::create_directories(m_langpackDir);

    for (auto &pkg : m_langpacks) {
        if (extracted.contains(pkg->name()))
            continue;

        logDebug("Extracting {}", pkg->name());
        pkg->extractPackage(m_langpackDir);
        extracted.insert(pkg->name());
    }

    fs::create_directories(m_localeDir);

    if (extracted.empty()) {
        logWarning("We have extracted no language packs for this repository!");
        m_langpackLocales.clear();
        m_langpacks.clear();
        return;
    }

    // Process supported locales
    const auto supportedDir = m_langpackDir / "var" / "lib" / "locales" / "supported.d";
    if (!fs::exists(supportedDir)) {
        logWarning("No supported locales directory found in language packs");
        return;
    }

    // Collect all locale files first
    std::vector<fs::path> localeFiles;
    for (const auto &entry : fs::directory_iterator(supportedDir)) {
        if (entry.is_regular_file())
            localeFiles.push_back(entry.path());
    }

    // Process locale files in parallel (batch size of 5)
    tbb::parallel_for(
        tbb::blocked_range<std::size_t>(0, localeFiles.size(), 5),
        [&](const tbb::blocked_range<std::size_t> &range) {
            for (std::size_t i = range.begin(); i != range.end(); ++i) {
                const auto &localeFile = localeFiles[i];
                std::ifstream file(localeFile);
                std::string line;

                while (std::getline(file, line)) {
                    line = Utils::trimString(line);
                    if (line.empty())
                        continue;

                    const auto components = Utils::splitString(line, ' ');
                    if (components.size() < 2)
                        continue;

                    const auto localeCharset = Utils::splitString(components[0], '.');
                    if (localeCharset.empty())
                        continue;

                    const auto outdir = fs::path(m_localeDir) / components[0];
                    if (m_localedefExe.empty()) {
                        logWarning("Not generating locale {}: The localedef binary is missing.", components[0]);
                        continue;
                    }
                    logDebug("Generating locale in {}", outdir.string());

                    // Execute localedef to generate locale
                    std::vector<std::string> args = {
                        m_localedefExe,
                        "--no-archive",
                        "-i",
                        localeCharset[0],
                        "-c",
                        "-f",
                        components[1],
                        outdir.string()};

                    // Convert to char* array for g_spawn_sync
                    std::vector<char *> argv;
                    argv.reserve(args.size() + 1);
                    for (auto &arg : args)
                        argv.push_back(arg.data());
                    argv.push_back(nullptr);

                    g_autoptr(GError) error = nullptr;
                    gint exit_status = 0;
                    gboolean success = g_spawn_sync(
                        nullptr,         // working_directory
                        argv.data(),     // argv
                        nullptr,         // envp
                        G_SPAWN_DEFAULT, // flags
                        nullptr,         // child_setup
                        nullptr,         // user_data
                        nullptr,         // standard_output
                        nullptr,         // standard_error
                        &exit_status,    // exit_status
                        &error           // error
                    );

                    if (!success || exit_status != 0) {
                        if (error)
                            logDebug(
                                "Failed to generate locale for {}: {}", components[0], std::string{error->message});
                        else
                            logDebug(
                                "Failed to generate locale for {} (exit status: {})",
                                components[0],
                                static_cast<int>(exit_status));
                    }
                }
            }
        },
        tbb::static_partitioner{});

    // Clear langpacks as we don't need them in memory anymore after extraction
    m_langpacks.clear();

    // Collect available locales
    if (m_langpackLocales.empty() && fs::exists(m_localeDir)) {
        for (const auto &entry : fs::directory_iterator(m_localeDir)) {
            if (entry.is_directory())
                m_langpackLocales.push_back(entry.path().filename().string());
        }
    }
}

std::unordered_map<std::string, std::string> LanguagePackProvider::getTranslationsPrivate(
    const std::string &domain,
    const std::string &text)
{
    // Store original environment variables
    std::unordered_map<std::string, std::string> originalEnv;
    static const std::vector<std::string> envVars = {"LC_ALL", "LANG", "LANGUAGE", "LC_MESSAGES"};

    for (const auto &var : envVars) {
        const char *value = std::getenv(var.c_str());
        if (value) {
            originalEnv[var] = value;
            unsetenv(var.c_str());
        }
    }

    // Restore environment on exit
    auto restoreEnv = [&originalEnv]() {
        for (const auto &[key, value] : originalEnv)
            setenv(key.c_str(), value.c_str(), 1);
    };

    // Set locale path
    setenv("LOCPATH", m_localeDir.c_str(), 1);

    // Store original locale
    const char *originalLocale = setlocale(LC_ALL, "");
    std::string origLocaleStr = originalLocale ? originalLocale : "C";

    const auto translationDir = m_langpackDir / "usr" / "share" / "locale-langpack";
    std::unordered_map<std::string, std::string> result;

    for (const auto &locale : m_langpackLocales) {
        setlocale(LC_ALL, locale.c_str());
        bindtextdomain(domain.c_str(), translationDir.c_str());

        const char *translatedText = dgettext(domain.c_str(), text.c_str());

        if (translatedText && text != translatedText)
            result[locale] = translatedText;
    }

    // Restore original locale
    setlocale(LC_ALL, origLocaleStr.c_str());

    // Restore environment
    restoreEnv();

    return result;
}

std::unordered_map<std::string, std::string> LanguagePackProvider::getTranslations(
    const std::string &domain,
    const std::string &text)
{
    // this functions does nasty things like changing environment variables and
    // messing with other global state. We therefore need to ensure that nothing
    // else is running in parallel
    static std::mutex global_translation_mutex;
    std::lock_guard<std::mutex> globalLock(global_translation_mutex);

    // Also lock the instance to prevent concurrent modification of langpacks
    std::lock_guard<std::mutex> instanceLock(m_mutex);

    extractLangpacks();
    return getTranslationsPrivate(domain, text);
}

UbuntuPackage::UbuntuPackage(
    const std::string &pname,
    const std::string &pver,
    const std::string &parch,
    std::shared_ptr<DebPackageLocaleTexts> l10nTexts)
    : DebPackage(pname, pver, parch, std::move(l10nTexts))
{
}

void UbuntuPackage::setLanguagePackProvider(std::shared_ptr<LanguagePackProvider> provider)
{
    m_langpackProvider = std::move(provider);
}

bool UbuntuPackage::hasDesktopFileTranslations() const
{
    return m_langpackProvider != nullptr;
}

std::unordered_map<std::string, std::string> UbuntuPackage::getDesktopFileTranslations(
    GKeyFile *desktopFile,
    const std::string &text)
{
    if (!m_langpackProvider)
        return {};

    std::string langpackDomain;

    // Try X-Ubuntu-Gettext-Domain first, then X-GNOME-Gettext-Domain as fallback
    g_autoptr(GError) error = nullptr;
    g_autofree gchar *domain = g_key_file_get_string(desktopFile, "Desktop Entry", "X-Ubuntu-Gettext-Domain", &error);

    if (!domain || error) {
        g_clear_error(&error);
        domain = g_key_file_get_string(desktopFile, "Desktop Entry", "X-GNOME-Gettext-Domain", &error);

        if (!domain || error)
            return {};
    }

    langpackDomain = domain;
    logDebug("{} has langpack domain {}", name(), langpackDomain);
    return m_langpackProvider->getTranslations(langpackDomain, text);
}

} // namespace ASGenerator
