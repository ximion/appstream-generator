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
#include <tbb/task_arena.h>

#include "config.h"
#include "datastore.h"
#include "contentsstore.h"
#include "backends/interfaces.h"
#include "iconhandler.h"
#include "reportgenerator.h"
#include "cptmodifiers.h"

namespace ASGenerator
{

/**
 * Structure to represent the result of checking a suite's usability.
 */
struct SuiteUsabilityResult {
    Suite suite;
    bool suiteUsable = false;
};

/**
 * Class orchestrating the whole metadata extraction
 * and publication process.
 */
class Engine
{
public:
    Engine();
    ~Engine() = default;

    // Delete copy constructor and assignment operator
    Engine(const Engine &) = delete;
    Engine &operator=(const Engine &) = delete;

    bool forced() const;
    void setForced(bool v);

    bool processFile(
        const std::string &suiteName,
        const std::string &sectionName,
        const std::vector<std::string> &files);

    /**
     * Run the metadata extractor on a suite and all of its sections.
     */
    void run(const std::string &suiteName);

    /**
     * Run the metadata extractor on a single section of a suite.
     */
    void run(const std::string &suiteName, const std::string &sectionName);

    /**
     * Run the metadata publishing step only, for a suite and all of its sections.
     */
    void publish(const std::string &suiteName);

    /**
     * Run the metadata publishing step only, on a single section of a suite.
     */
    void publish(const std::string &suiteName, const std::string &sectionName);

    void runCleanup();

    /**
     * Drop all packages which contain valid components or hints
     * from the database.
     * This is useful when big generator changes have been done, which
     * require reprocessing of all components.
     */
    void removeHintsComponents(const std::string &suiteName);

    void forgetPackage(const std::string &identifier);

    /**
     * Print all information we have on a package to stdout.
     */
    bool printPackageInfo(const std::string &identifier);

private:
    Config *m_conf;
    std::unique_ptr<PackageIndex> m_pkgIndex;
    std::shared_ptr<DataStore> m_dstore;
    std::shared_ptr<ContentsStore> m_cstore;
    bool m_forced;

    std::unique_ptr<tbb::task_arena> m_taskArena;
    mutable std::mutex m_mutex;

    void logVersionInfo();

    /**
     * Extract metadata from a software container (usually a distro package).
     * The result is automatically stored in the database.
     */
    void processPackages(
        const std::vector<std::shared_ptr<Package>> &pkgs,
        std::shared_ptr<IconHandler> iconh,
        std::shared_ptr<InjectedModifications> injMods);

    /**
     * Populate the contents index with new contents data. While we are at it, we can also mark
     * some uninteresting packages as to-be-ignored, so we don't waste time on them
     * during the following metadata extraction.
     *
     * Returns: True in case we have new interesting packages, false otherwise.
     */
    bool seedContentsData(
        const Suite &suite,
        const std::string &section,
        const std::string &arch,
        const std::vector<std::shared_ptr<Package>> &pkgs = {});

    std::string getMetadataHead(const Suite &suite, const std::string &section);

    /**
     * Export metadata and issue hints from the database and store them as files.
     */
    void exportMetadata(
        const Suite &suite,
        const std::string &section,
        const std::string &arch,
        const std::vector<std::shared_ptr<Package>> &pkgs);

    /**
     * Export all icons for the given set of packages and publish them in the selected suite/section.
     * Package icon duplicates will be eliminated automatically.
     */
    void exportIconTarballs(
        const Suite &suite,
        const std::string &section,
        const std::vector<std::shared_ptr<Package>> &pkgs);

    std::unordered_map<std::string, std::shared_ptr<Package>> getIconCandidatePackages(
        const Suite &suite,
        const std::string &section,
        const std::string &arch);

    /**
     * Read metainfo and auxiliary data injected by the person running the data generator.
     */
    std::shared_ptr<Package> processExtraMetainfoData(
        const Suite &suite,
        std::shared_ptr<IconHandler> iconh,
        const std::string &section,
        const std::string &arch,
        std::shared_ptr<InjectedModifications> injMods);

    /**
     * Scan and export data and hints for a specific section in a suite.
     */
    bool processSuiteSection(const Suite &suite, const std::string &section, std::shared_ptr<ReportGenerator> rgen);

    /**
     * Fetch a suite definition from a suite name and test whether we can process it.
     */
    SuiteUsabilityResult checkSuiteUsable(const std::string &suiteName);

    /**
     * Export data and hints for a specific section in a suite.
     */
    void publishMetadataForSuiteSection(
        const Suite &suite,
        const std::string &section,
        std::shared_ptr<ReportGenerator> rgen);

    void cleanupStatistics();
};

} // namespace ASGenerator
