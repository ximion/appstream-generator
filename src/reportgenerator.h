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
#include <unordered_set>
#include <map>
#include <memory>
#include <optional>
#include <cstdint>

#include <appstream.h>
#include <inja/inja.hpp>

#include "config.h"
#include "datastore.h"
#include "statsstore.h"
#include "backends/interfaces.h"

namespace ASGenerator
{

class ReportGenerator
{
public:
    ReportGenerator(DataStore *db, StatsStore *sdb);
    ~ReportGenerator() = default;

    void processFor(
        const std::string &suiteName,
        const std::string &section,
        const std::vector<std::shared_ptr<Package>> &pkgs);

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

        // the most severe issue we found for this entry
        AsIssueSeverity worstSeverity = AS_ISSUE_SEVERITY_UNKNOWN;
    };

    struct MetadataEntry {
        AsComponentKind kind;
        std::string identifier;
        std::string version;
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
        // package -> gcid -> entry
        std::unordered_map<std::string, std::unordered_map<std::string, MetadataEntry>> mdataEntries;
        // every global component ID we have counted towards @totalMetadata already
        std::unordered_set<std::string> countedGcids;

        int64_t totalMetadata = 0;
        int64_t totalInfos = 0;
        int64_t totalWarnings = 0;
        int64_t totalErrors = 0;

        // What became of the components of this section. Unlike the totals above - which
        // count how often an issue occurred - every component is counted exactly once here,
        // so these can be compared to each other. An error drops the component, so
        // @cptsClean + @cptsWarning is @totalMetadata, and adding @cptsRejected gives every
        // component we tried to generate. An info does not make a component any less usable,
        // so one that only has those counts as clean.
        int64_t cptsClean = 0;
        int64_t cptsWarning = 0;
        int64_t cptsRejected = 0;
    };

    /**
     * One recorded set of counters for a suite/section, at the time we recorded it.
     */
    struct StatsPoint {
        int64_t time = 0;

        // how often an issue of each kind occurred
        std::optional<int64_t> metadata;
        std::optional<int64_t> errors;
        std::optional<int64_t> warnings;
        std::optional<int64_t> infos;

        // how the components themselves ended up, each counted once
        std::optional<int64_t> cptsClean;
        std::optional<int64_t> cptsWarning;
        std::optional<int64_t> cptsRejected;
    };

    // suite -> section -> timeline, oldest entry first
    using StatsHistory = std::map<std::string, std::map<std::string, std::vector<StatsPoint>>>;

    // Public methods for testing access
    void setupInjaContext(inja::json &context);
    void renderPage(const std::string &pageID, const std::string &exportName, const inja::json &context);
    void renderPagesFor(const std::string &suiteName, const std::string &section, const DataSummary &dsum);
    DataSummary preprocessInformation(
        const std::string &suiteName,
        const std::string &section,
        const std::vector<std::shared_ptr<Package>> &pkgs);
    void saveStatistics(const std::string &suiteName, const std::string &section, const DataSummary &dsum);
    static void classifyComponents(DataSummary &dsum);

    /**
     * Read the recorded statistics, grouped by suite and section.
     */
    StatsHistory collectStatistics();

    void updateIndexPages(const StatsHistory &history);
    void exportStatistics(const StatsHistory &history);

private:
    void copyStaticData(const fs::path &templateDir, const fs::path &staticDestDir);

    quill::Logger *m_log;
    DataStore *m_dstore;
    StatsStore *m_sstore;
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
