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

#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <memory>
#include <cstdint>

#include <appstream.h>
#include <inja/inja.hpp>

#include "config.h"
#include "datastore.h"
#include "backends/interfaces.h"

namespace ASGenerator
{

class ReportGenerator
{
public:
    explicit ReportGenerator(DataStore *db);
    ~ReportGenerator() = default;

    void processFor(
        const std::string &suiteName,
        const std::string &section,
        const std::vector<std::unique_ptr<Package>> &pkgs);
    void updateIndexPages();
    void exportStatistics();

    // Delete copy constructor and assignment operator
    ReportGenerator(const ReportGenerator &) = delete;
    ReportGenerator &operator=(const ReportGenerator &) = delete;

    // Public structs for testing access
    struct HintTag {
        std::string tag;
        std::string message;
    };

    struct HintEntry {
        std::string identifier;
        std::vector<std::string> archs;
        std::vector<HintTag> errors;
        std::vector<HintTag> warnings;
        std::vector<HintTag> infos;
    };

    struct MetadataEntry {
        AsComponentKind kind;
        std::string identifier;
        std::vector<std::string> archs;
        std::string data;
        std::string iconName;
    };

    struct PkgSummary {
        std::string pkgname;
        std::vector<std::string> cpts;
        int infoCount = 0;
        int warningCount = 0;
        int errorCount = 0;
    };

    struct DataSummary {
        // maintainer -> package -> summary
        std::unordered_map<std::string, std::unordered_map<std::string, PkgSummary>> pkgSummaries;
        // package -> component_id -> hint_entry
        std::unordered_map<std::string, std::unordered_map<std::string, HintEntry>> hintEntries;
        // package -> version -> gcid -> entry
        std::unordered_map<std::string, std::unordered_map<std::string, std::unordered_map<std::string, MetadataEntry>>>
            mdataEntries;

        int64_t totalMetadata = 0;
        int64_t totalInfos = 0;
        int64_t totalWarnings = 0;
        int64_t totalErrors = 0;
    };

    // Public methods for testing access
    void setupInjaContext(inja::json &context);
    void renderPage(const std::string &pageID, const std::string &exportName, const inja::json &context);
    void renderPagesFor(const std::string &suiteName, const std::string &section, const DataSummary &dsum);
    DataSummary preprocessInformation(
        const std::string &suiteName,
        const std::string &section,
        const std::vector<std::unique_ptr<Package>> &pkgs);
    void saveStatistics(const std::string &suiteName, const std::string &section, const DataSummary &dsum);

private:
    DataStore *m_dstore;
    Config *m_conf;

    fs::path m_htmlExportDir;
    fs::path m_templateDir;
    fs::path m_defaultTemplateDir;

    fs::path m_mediaPoolDir;
    std::string m_mediaPoolUrl;

    std::string m_versionInfo;

    inja::Environment m_injaEnv;
};

} // namespace ASGenerator
