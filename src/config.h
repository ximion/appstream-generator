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
#include <filesystem>
#include <memory>
#include <mutex>

#include <appstream.h>

#include "utils.h"

typedef struct _AscIconPolicy AscIconPolicy;

namespace ASGenerator
{

/**
 * A list of valid icon sizes that we recognize in AppStream.
 */
inline constexpr std::array<ImageSize, 6> AllowedIconSizes =
    {ImageSize(48), ImageSize(48, 48, 2), ImageSize(64), ImageSize(64, 64, 2), ImageSize(128), ImageSize(128, 128, 2)};

/**
 * Fake package name AppStream Generator uses internally to inject additional metainfo on users' request
 */
inline constexpr std::string EXTRA_METAINFO_FAKE_PKGNAME = "+extra-metainfo";

/**
 * Describes a suite in a software repository.
 */
struct Suite {
    std::string name;
    int dataPriority = 0;
    std::string baseSuite;
    std::string iconTheme;
    std::vector<std::string> sections;
    std::vector<std::string> architectures;
    fs::path extraMetainfoDir;
    bool isImmutable = false;
};

/**
 * The AppStream metadata type we want to generate.
 */
enum class DataType {
    XML,
    YAML
};

/**
 * Distribution-specific backends.
 */
enum class Backend {
    Unknown,
    Dummy,
    Debian,
    Ubuntu,
    Archlinux,
    RpmMd,
    Alpinelinux,
    FreeBSD,
    Nix
};

/**
 * Generator features that can be toggled by the user.
 */
struct GeneratorFeatures {
    bool processDesktop = true;
    bool validate = true;
    bool noDownloads = false;
    bool storeScreenshots = true;
    bool optipng = true;
    bool metadataTimestamps = true;
    bool immutableSuites = true;
    bool processFonts = true;
    bool allowIconUpscale = true;
    bool processGStreamer = true;
    bool processLocale = true;
    bool screenshotVideos = true;
    bool propagateMetaInfoArtifacts = false;
};

/// Fake package name AppStream Generator uses internally to inject additional metainfo on users' request
extern const std::string EXTRA_METAINFO_FAKE_PKGNAME;

/**
 * The global configuration for the metadata generator.
 */
class Config
{
public:
    ~Config();

    // Singleton access
    static Config &get();

    // Configuration properties
    AsFormatVersion formatVersion;
    std::string projectName;
    std::string archiveRoot;
    std::string mediaBaseUrl;
    std::string htmlBaseUrl;

    std::string backendName;
    Backend backend;
    std::vector<Suite> suites;
    std::vector<std::string> oldsuites;
    DataType metadataType;
    GeneratorFeatures feature;

    std::string optipngBinary;
    std::string ffprobeBinary;

    std::unordered_map<std::string, bool> allowedCustomKeys;

    fs::path dataExportDir;
    fs::path hintsExportDir;
    fs::path mediaExportDir;
    fs::path htmlExportDir;

    int64_t maxScrFileSize;
    std::string caInfo;

    std::string formatVersionStr() const;
    fs::path databaseDir() const;
    fs::path cacheRootDir() const;
    fs::path templateDir() const;
    AscIconPolicy *iconPolicy() const;

    void loadFromFile(
        const std::string &fname,
        const std::string &enforcedWorkspaceDir = "",
        const std::string &enforcedExportDir = "");

    bool isValid() const;
    fs::path getTmpDir() const;

    void setWorkspaceDir(const fs::path &dir);

    // Delete copy constructor and assignment operator for singleton
    Config(const Config &) = delete;
    Config &operator=(const Config &) = delete;

private:
    static std::unique_ptr<Config> instance_;
    static std::once_flag initialized_;
    Config();

    fs::path m_workspaceDir;
    fs::path m_exportDir;
    mutable fs::path m_tmpDir;

    AscIconPolicy *m_iconPolicy;

    fs::path getVendorTemplateDir(const std::string &dir, bool allowRoot = false) const;
};

} // namespace ASGenerator
