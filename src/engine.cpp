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

#include "defines.h"
#include "engine.h"

#include <algorithm>
#include <chrono>
#include <execution>
#include <filesystem>
#include <format>
#include <iostream>
#include <sstream>
#include <thread>
#include <unordered_set>

#include <appstream.h>
#include <glib.h>

#include <tbb/parallel_for.h>
#include <tbb/parallel_for_each.h>
#include <tbb/blocked_range.h>
#include <tbb/task_arena.h>
#include <inja/inja.hpp>

#include "datainjectpkg.h"
#include "extractor.h"
#include "hintregistry.h"
#include "logging.h"
#include "result.h"
#include "utils.h"
#include "zarchive.h"
#include "backends/interfaces.h"

// Backends
#include "backends/dummy/pkgindex.h"
#include "backends/debian/debpkgindex.h"
#include "backends/ubuntu/ubupkgindex.h"
#include "backends/alpinelinux/apkpkgindex.h"
#include "backends/archlinux/alpkgindex.h"
#include "backends/rpmmd/rpmpkgindex.h"
#include "backends/freebsd/fbsdpkgindex.h"

namespace ASGenerator
{

Engine::Engine()
    : m_conf(&Config::get()),
      m_forced(false)
{
    // Configure a TBB task arena to limit parallelism a little (use half the available CPU cores, or at least 6
    // threads) This avoids having too many parallel downloads on high-core-count machines, and also leaves some room
    // for additional parallelism of the used libraries, e.g. for image processing.
    const auto numCPU = std::thread::hardware_concurrency();
    const auto maxThreads = std::max(numCPU > 6 ? 6L : numCPU, std::lround(numCPU * 0.60));
    m_taskArena = std::make_unique<tbb::task_arena>(maxThreads);

    // Select backend
    switch (m_conf->backend) {
    case Backend::Dummy:
        m_pkgIndex = std::make_unique<DummyPackageIndex>(m_conf->archiveRoot);
        break;
    case Backend::Debian:
        m_pkgIndex = std::make_unique<DebianPackageIndex>(m_conf->archiveRoot);
        break;
    case Backend::Ubuntu:
        m_pkgIndex = std::make_unique<UbuntuPackageIndex>(m_conf->archiveRoot);
        break;
    case Backend::Archlinux:
        m_pkgIndex = std::make_unique<ArchPackageIndex>(m_conf->archiveRoot);
        break;
    case Backend::RpmMd:
        m_pkgIndex = std::make_unique<RPMPackageIndex>(m_conf->archiveRoot);
        break;
    case Backend::Alpinelinux:
        m_pkgIndex = std::make_unique<AlpinePackageIndex>(m_conf->archiveRoot);
        break;
    case Backend::FreeBSD:
        m_pkgIndex = std::make_unique<FreeBSDPackageIndex>(m_conf->archiveRoot);
        break;
    default:
        throw std::runtime_error("No backend specified, can not continue!");
    }

    // Load global registry of issue hint templates
    loadHintsRegistry();

    // Create cache in cache directory on workspace
    m_dstore = std::make_shared<DataStore>();
    m_dstore->open(*m_conf);

    // Open package contents cache
    m_cstore = std::make_shared<ContentsStore>();
    m_cstore->open(*m_conf);
}

bool Engine::forced() const
{
    return m_forced;
}

void Engine::setForced(bool v)
{
    m_forced = v;
}

void Engine::logVersionInfo()
{
    std::string backendInfo = "";
    if (!m_conf->backendName.empty())
        backendInfo = std::format(" [{}]", m_conf->backendName);

    // Get AppStream version
    const char *asVersion = as_version_string();
    logInfo("AppStream Generator {}, AS: {}{}", ASGEN_VERSION, asVersion, backendInfo);
}

void Engine::processPackages(
    const std::vector<std::shared_ptr<Package>> &pkgs,
    std::shared_ptr<IconHandler> iconh,
    std::shared_ptr<InjectedModifications> injMods)
{
    g_autoptr(AsgLocaleUnit) localeUnit = asg_locale_unit_new(m_cstore, pkgs);

    const auto numProcessors = std::thread::hardware_concurrency();
    std::size_t chunkSize = pkgs.size() / numProcessors / 10;
    if (chunkSize > 100)
        chunkSize = 100;
    if (chunkSize <= 10)
        chunkSize = 10;

    logDebug(
        "Analyzing {} packages in batches of {} with {} parallel tasks",
        pkgs.size(),
        chunkSize,
        m_taskArena->max_concurrency());

    m_taskArena->execute([&] {
        tbb::parallel_for(
            tbb::blocked_range<std::size_t>(0, pkgs.size(), chunkSize),
            [&](const tbb::blocked_range<std::size_t> &range) {
                auto mde = std::make_unique<DataExtractor>(m_dstore, iconh, localeUnit, injMods);

                for (std::size_t i = range.begin(); i != range.end(); ++i) {
                    auto pkg = pkgs[i];
                    const auto &pkid = pkg->id();

                    if (m_dstore->packageExists(pkid))
                        continue;

                    auto res = mde->processPackage(pkg);
                    {
                        std::lock_guard<std::mutex> lock(m_mutex);
                        // Write resulting data into the database
                        m_dstore->addGeneratorResult(m_conf->metadataType, res);
                    }

                    logInfo(
                        "Processed {}, components: {}, hints: {}", res.pkid(), res.componentsCount(), res.hintsCount());

                    // We don't need content data from this package anymore
                    pkg->finish();
                }
            });
    });
}

// Helper to check if a package may contain interesting metadata
static bool packageIsInteresting(std::shared_ptr<Package> pkg)
{
    // Prefixes are defined as string_view for faster comparison
    constexpr std::string_view usr_share_apps = "/usr/share/applications/";
    constexpr std::string_view usr_share_meta = "/usr/share/metainfo/";
    constexpr std::string_view usr_local_apps = "/usr/local/share/applications/";
    constexpr std::string_view usr_local_meta = "/usr/local/share/metainfo/";
    constexpr std::string_view usr_share = "/usr/share/";
    constexpr std::string_view usr_local = "/usr/local/share/";

    const auto &contents = pkg->contents();
    for (const auto &c : contents) {
        // Quick length check first - all interesting paths are at least 18 characters
        if (c.size() < 18)
            continue;

        std::string_view path_view{c};
        if (path_view.starts_with(usr_share)) {
            // Already know it starts with /usr/share/, check specific subdirs
            if (path_view.starts_with(usr_share_apps) || path_view.starts_with(usr_share_meta))
                return true;
        } else if (path_view.starts_with(usr_local)) {
            // Already know it starts with /usr/local/share/, check specific subdirs
            if (path_view.starts_with(usr_local_apps) || path_view.starts_with(usr_local_meta))
                return true;
        }
    }

    // Check for GStreamer codec info
    auto gst = pkg->gst();
    if (gst.has_value() && gst->isNotEmpty())
        return true;

    return false;
}

bool Engine::seedContentsData(
    const Suite &suite,
    const std::string &section,
    const std::string &arch,
    const std::vector<std::shared_ptr<Package>> &pkgs)
{
    const auto numProcessors = std::thread::hardware_concurrency();
    std::size_t workUnitSize = numProcessors * 2;
    if (workUnitSize >= pkgs.size())
        workUnitSize = 4;
    if (workUnitSize > 30)
        workUnitSize = 30;

    logDebug(
        "Scanning {} packages, work unit size: {}, parallel tasks: {}",
        pkgs.size(),
        workUnitSize,
        m_taskArena->max_concurrency());

    // Check if the index has changed data, skip the update if there's nothing new
    if (pkgs.empty() && !m_pkgIndex->hasChanges(m_dstore, suite.name, section, arch) && !m_forced) {
        logDebug("Skipping contents cache update for {}/{} [{}], index has not changed.", suite.name, section, arch);
        return false;
    }

    logInfo("Scanning new packages for {}/{} [{}]", suite.name, section, arch);

    std::vector<std::shared_ptr<Package>> packagesToProcess = pkgs;
    if (packagesToProcess.empty())
        packagesToProcess = m_pkgIndex->packagesFor(suite.name, section, arch);

    // Get contents information for packages and add them to the database
    std::atomic_bool interestingFound = false;

    // First get the contents (only) of all packages in the base suite
    if (!suite.baseSuite.empty()) {
        logInfo("Scanning new packages for base suite {}/{} [{}]", suite.baseSuite, section, arch);
        auto baseSuitePkgs = m_pkgIndex->packagesFor(suite.baseSuite, section, arch);

        m_taskArena->execute([&] {
            tbb::parallel_for(
                tbb::blocked_range<std::size_t>(0, baseSuitePkgs.size(), workUnitSize),
                [&](const tbb::blocked_range<std::size_t> &range) {
                    for (size_t i = range.begin(); i != range.end(); ++i) {
                        auto pkg = baseSuitePkgs[i];
                        const auto &pkid = pkg->id();

                        if (!m_cstore->packageExists(pkid)) {
                            m_cstore->addContents(pkid, pkg->contents());
                            logInfo("Scanned {} for base suite.", pkid);
                        }

                        // Chances are that we might never want to extract data from these packages, so remove their
                        // temporary data for now - we can reopen the packages later if we actually need them.
                        pkg->cleanupTemp();
                    }
                });
        });
    }

    // And then scan the suite itself - here packages can be 'interesting'
    // in that they might end up in the output.
    m_taskArena->execute([&] {
        tbb::parallel_for(
            tbb::blocked_range<std::size_t>(0, packagesToProcess.size(), workUnitSize),
            [&](const tbb::blocked_range<std::size_t> &range) {
                for (std::size_t i = range.begin(); i != range.end(); ++i) {
                    auto pkg = packagesToProcess[i];
                    const auto &pkid = pkg->id();

                    std::vector<std::string> contents;
                    if (m_cstore->packageExists(pkid)) {
                        if (m_dstore->packageExists(pkid)) {
                            // TODO: Unfortunately, packages can move between suites without changing their ID.
                            // This means as soon as we have an interesting package, even if we already processed it,
                            // we need to regenerate the output metadata.
                            // For that to happen, we set interestingFound to true here. Later, a more elegant solution
                            // would be desirable here, ideally one which doesn't force us to track which package is
                            // in which suite as well.
                            if (!m_dstore->isIgnored(pkid))
                                interestingFound.store(true);
                            return;
                        }
                        // We will complement the main database with ignore data, in case it
                        // went missing.
                        contents = m_cstore->getContents(pkid);
                    } else {
                        // Add contents to the index
                        contents = pkg->contents();
                        m_cstore->addContents(pkid, contents);
                    }

                    // Check if we can already mark this package as ignored, and print some log messages
                    if (!packageIsInteresting(pkg)) {
                        m_dstore->setPackageIgnore(pkid);
                        logInfo("Scanned {}, no interesting files found.", pkid);
                        // We won't use this anymore
                        pkg->finish();
                    } else {
                        logInfo("Scanned {}, could be interesting.", pkid);
                        interestingFound.store(true);
                    }
                }
            });
    });

    // Ensure the contents store is in a consistent state on disk,
    // since it might be accessed from other threads after this function
    // is run.
    m_cstore->sync();

    return interestingFound;
}

std::string Engine::getMetadataHead(const Suite &suite, const std::string &section)
{
    std::string head;
    auto origin = std::format("{}-{}-{}", m_conf->projectName, suite.name, section);

    // Convert to lowercase
    std::transform(origin.begin(), origin.end(), origin.begin(), ::tolower);

    // Get current time in ISO8601 UTC
    auto now = std::chrono::floor<std::chrono::seconds>(std::chrono::system_clock::now());
    std::string timeNowIso8601 = std::format("{:%FT%TZ}", now);

    std::string mediaPoolUrl = fs::path(m_conf->mediaBaseUrl) / "pool";
    if (m_conf->feature.immutableSuites)
        mediaPoolUrl = std::format("{}/{}", m_conf->mediaBaseUrl, suite.name);

    const bool mediaBaseUrlAllowed = !m_conf->mediaBaseUrl.empty() && m_conf->feature.storeScreenshots;
    if (m_conf->metadataType == DataType::XML) {
        head = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
        head += std::format("<components version=\"{}\" origin=\"{}\"", m_conf->formatVersionStr(), origin);
        if (suite.dataPriority != 0)
            head += std::format(" priority=\"{}\"", suite.dataPriority);
        if (mediaBaseUrlAllowed)
            head += std::format(" media_baseurl=\"{}\"", mediaPoolUrl);
        if (m_conf->feature.metadataTimestamps)
            head += std::format(" time=\"{}\"", timeNowIso8601);
        head += ">";
    } else {
        head = "%YAML 1.2\n---\n";
        head += std::format(
            "File: DEP-11\n"
            "Version: '{}'\n"
            "Origin: {}",
            m_conf->formatVersionStr(),
            origin);
        if (mediaBaseUrlAllowed)
            head += std::format("\nMediaBaseUrl: {}", mediaPoolUrl);
        if (suite.dataPriority != 0)
            head += std::format("\nPriority: {}", suite.dataPriority);
        if (m_conf->feature.metadataTimestamps)
            head += std::format("\nTime: '{}'", timeNowIso8601);
    }

    return head;
}

void Engine::exportMetadata(
    const Suite &suite,
    const std::string &section,
    const std::string &arch,
    const std::vector<std::shared_ptr<Package>> &pkgs)
{
    std::ostringstream mdataFile;
    std::ostringstream hintsFile;

    // Reserve some space for our data
    mdataFile.str().reserve(pkgs.size() / 2);
    hintsFile.str().reserve(512);

    // Prepare hints file
    hintsFile << "[\n";

    logInfo("Exporting data for {} ({}/{})", suite.name, section, arch);

    // Add metadata document header
    mdataFile << getMetadataHead(suite, section) << "\n";

    // Prepare destination
    const auto dataExportDir = m_conf->dataExportDir / suite.name / section;
    const auto hintsExportDir = m_conf->hintsExportDir / suite.name / section;

    fs::create_directories(dataExportDir);
    fs::create_directories(hintsExportDir);

    const bool useImmutableSuites = m_conf->feature.immutableSuites;
    // Select the media export target directory
    fs::path mediaExportDir;
    if (useImmutableSuites)
        mediaExportDir = m_dstore->mediaExportPoolDir().parent_path() / suite.name;
    else
        mediaExportDir = m_dstore->mediaExportPoolDir();

    // Collect metadata, icons and hints for the given packages
    std::unordered_map<std::string, std::string> cidGcidMap;
    bool firstHintEntry = true;
    std::mutex exportMutex;

    logDebug("Building final metadata and hints files.");

    tbb::parallel_for_each(pkgs.begin(), pkgs.end(), [&](std::shared_ptr<Package> pkg) {
        const auto &pkid = pkg->id();
        auto gcids = m_dstore->getGCIDsForPackage(pkid);
        if (!gcids.empty()) {
            auto mres = m_dstore->getMetadataForPackage(m_conf->metadataType, pkid);
            if (!mres.empty()) {
                std::lock_guard<std::mutex> lock(exportMutex);
                // FIXME: We sanitize the returned metadata here, because if asgen was run on systems
                // with broken locale, we ended up with bad UTF-8 in the database. This issue needs more
                // investigation and a proper resoltition, so this is only a temporary fix.
                for (const auto &md : mres)
                    mdataFile << Utils::sanitizeUtf8(md) << "\n";
            }

            for (const auto &gcid : gcids) {
                {
                    std::lock_guard<std::mutex> lock(exportMutex);
                    const auto cid = Utils::getCidFromGlobalID(gcid);
                    if (cid.has_value())
                        cidGcidMap[cid.value()] = gcid;
                    else
                        logError("Could not extract component-ID from GCID: {}", gcid);
                }

                // Hardlink data from the pool to the suite-specific directories
                if (useImmutableSuites) {
                    const auto gcidMediaPoolPath = m_dstore->mediaExportPoolDir() / gcid;
                    const auto gcidMediaSuitePath = mediaExportDir / gcid;
                    if (!fs::exists(gcidMediaSuitePath) && fs::exists(gcidMediaPoolPath))
                        Utils::copyDir(gcidMediaPoolPath.string(), gcidMediaSuitePath.string(), true);
                }
            }
        }

        const auto hres = m_dstore->getHints(pkid);
        if (!hres.empty()) {
            std::lock_guard<std::mutex> lock(exportMutex);
            if (firstHintEntry) {
                firstHintEntry = false;
                hintsFile << Utils::rtrimString(hres);
            } else {
                hintsFile << ",\n" << Utils::rtrimString(hres);
            }
        }
    });

    fs::path dataBaseFname;
    if (m_conf->metadataType == DataType::XML)
        dataBaseFname = dataExportDir / std::format("Components-{}.xml", arch);
    else
        dataBaseFname = dataExportDir / std::format("Components-{}.yml", arch);

    const auto cidIndexFname = dataExportDir / std::format("CID-Index-{}.json", arch);
    const auto hintsBaseFname = hintsExportDir / std::format("Hints-{}.json", arch);

    // Write metadata
    logInfo("Writing metadata for {}/{} [{}]", suite.name, section, arch);

    // Add the closing XML tag for XML metadata
    if (m_conf->metadataType == DataType::XML)
        mdataFile << "</components>\n";

    // Compress metadata and save it to disk
    auto mdataFileStr = mdataFile.str();
    std::vector<std::uint8_t> mdataFileBytes(mdataFileStr.begin(), mdataFileStr.end());
    compressAndSave(mdataFileBytes, dataBaseFname.string() + ".gz", ArchiveType::GZIP);
    compressAndSave(mdataFileBytes, dataBaseFname.string() + ".xz", ArchiveType::XZ);

    // Component ID index
    inja::json cidIndexJson = inja::json::object();
    for (const auto &[cid, gcid] : cidGcidMap)
        cidIndexJson[cid] = gcid;

    auto cidIndexStr = cidIndexJson.dump(2); // Pretty print with 2-space indentation
    std::vector<std::uint8_t> cidIndexData(cidIndexStr.begin(), cidIndexStr.end());
    compressAndSave(cidIndexData, cidIndexFname.string() + ".gz", ArchiveType::GZIP);

    // Write hints
    logInfo("Writing hints for {}/{} [{}]", suite.name, section, arch);

    // Finalize the JSON hints document
    hintsFile << "\n]\n";

    // Compress hints
    auto hintsFileStr = hintsFile.str();
    std::vector<std::uint8_t> hintsFileBytes(hintsFileStr.begin(), hintsFileStr.end());
    compressAndSave(hintsFileBytes, hintsBaseFname.string() + ".gz", ArchiveType::GZIP);
    compressAndSave(hintsFileBytes, hintsBaseFname.string() + ".xz", ArchiveType::XZ);

    // Save a copy of the hints registry to be used by other tools
    // (this allows other apps to just resolve the hint tags to severities and explanations
    // without loading either AppStream or AppStream-Generator code)
    saveHintsRegistryToJsonFile((m_conf->hintsExportDir / suite.name / "hint-definitions.json").string());
}

void Engine::exportIconTarballs(
    const Suite &suite,
    const std::string &section,
    const std::vector<std::shared_ptr<Package>> &pkgs)
{
    // Determine data sources and destinations
    const auto dataExportDir = m_conf->dataExportDir / suite.name / section;
    fs::create_directories(dataExportDir);
    const bool useImmutableSuites = m_conf->feature.immutableSuites;
    const auto mediaExportDir = useImmutableSuites ? m_dstore->mediaExportPoolDir().parent_path() / suite.name
                                                   : m_dstore->mediaExportPoolDir();

    // Prepare icon-tarball array
    std::unordered_map<std::string, std::vector<std::string>> iconTarFiles;

    // Initialize icon policy iterator
    AscIconPolicyIter policyIter;
    asc_icon_policy_iter_init(&policyIter, m_conf->iconPolicy());

    guint iconSizeInt;
    guint iconScale;
    AscIconState iconState;
    while (asc_icon_policy_iter_next(&policyIter, &iconSizeInt, &iconScale, &iconState)) {
        if (iconState == ASC_ICON_STATE_IGNORED || iconState == ASC_ICON_STATE_REMOTE_ONLY)
            continue; // We only want to create tarballs for cached icons

        const ImageSize iconSize(iconSizeInt, iconSizeInt, iconScale);
        iconTarFiles[iconSize.toString()] = std::vector<std::string>();
        iconTarFiles[iconSize.toString()].reserve(256);
    }

    logInfo("Creating icon tarballs for: {}/{}", suite.name, section);
    std::unordered_set<std::string> processedDirs;
    std::mutex dirMutex;
    std::mutex iconMutex;

    tbb::parallel_for_each(pkgs.begin(), pkgs.end(), [&](std::shared_ptr<Package> pkg) {
        const auto &pkid = pkg->id();
        auto gcids = m_dstore->getGCIDsForPackage(pkid);
        if (gcids.empty())
            return;

        for (const auto &gcid : gcids) {
            // Compile list of icon-tarball files
            AscIconPolicyIter ipIter;
            asc_icon_policy_iter_init(&ipIter, m_conf->iconPolicy());
            while (asc_icon_policy_iter_next(&ipIter, &iconSizeInt, &iconScale, &iconState)) {
                if (iconState == ASC_ICON_STATE_IGNORED || iconState == ASC_ICON_STATE_REMOTE_ONLY)
                    continue; // Only add icon to cache tarball if we want a cache for the particular size

                const ImageSize iconSize(iconSizeInt, iconSizeInt, iconScale);
                const auto iconDir = mediaExportDir / gcid / "icons" / iconSize.toString();

                // Skip adding icon entries if we've already investigated this directory
                {
                    std::lock_guard<std::mutex> lock(dirMutex);
                    if (processedDirs.contains(iconDir.string()))
                        continue;
                    else
                        processedDirs.insert(iconDir.string());
                }

                if (!fs::exists(iconDir))
                    continue;

                for (const auto &entry : fs::directory_iterator(iconDir)) {
                    if (entry.is_regular_file()) {
                        std::lock_guard<std::mutex> lock(iconMutex);
                        iconTarFiles[iconSize.toString()].push_back(entry.path().string());
                    }
                }
            }
        }
    });

    // Create the icon tarballs
    asc_icon_policy_iter_init(&policyIter, m_conf->iconPolicy());
    while (asc_icon_policy_iter_next(&policyIter, &iconSizeInt, &iconScale, &iconState)) {
        if (iconState == ASC_ICON_STATE_IGNORED || iconState == ASC_ICON_STATE_REMOTE_ONLY)
            continue;

        const ImageSize iconSize(iconSizeInt, iconSizeInt, iconScale);
        auto iconTar = std::make_unique<ArchiveCompressor>(ArchiveType::GZIP);
        iconTar->open((dataExportDir / std::format("icons-{}.tar.gz", iconSize.toString())).string());

        auto &iconFiles = iconTarFiles[iconSize.toString()];
        std::sort(iconFiles.begin(), iconFiles.end());

        for (const auto &fname : iconFiles)
            iconTar->addFile(fname);

        iconTar->close();
    }
    logInfo("Icon tarballs built for: {}/{}", suite.name, section);
}

std::unordered_map<std::string, std::shared_ptr<Package>> Engine::getIconCandidatePackages(
    const Suite &suite,
    const std::string &section,
    const std::string &arch)
{
    // Always load the "main" and "universe" components, which contain most of the icon data
    // on Debian and Ubuntu. Load the "core" and "extra" components for Arch Linux.
    // FIXME: This is a hack, find a sane way to get rid of this, or at least get rid of the
    // distro-specific hardcoding.
    std::vector<std::shared_ptr<Package>> pkgs;

    for (const auto &newSection : std::vector<std::string>{"main", "universe", "core", "extra"}) {
        if (section != newSection && std::ranges::find(suite.sections, newSection) != suite.sections.end()) {
            auto sectionPkgs = m_pkgIndex->packagesFor(suite.name, newSection, arch);
            pkgs.insert(pkgs.end(), sectionPkgs.begin(), sectionPkgs.end());

            if (!suite.baseSuite.empty()) {
                auto basePkgs = m_pkgIndex->packagesFor(suite.baseSuite, newSection, arch);
                pkgs.insert(pkgs.end(), basePkgs.begin(), basePkgs.end());
            }
        }
    }

    if (!suite.baseSuite.empty()) {
        auto basePkgs = m_pkgIndex->packagesFor(suite.baseSuite, section, arch);
        pkgs.insert(pkgs.end(), basePkgs.begin(), basePkgs.end());
    }

    auto sectionPkgs = m_pkgIndex->packagesFor(suite.name, section, arch);
    pkgs.insert(pkgs.end(), sectionPkgs.begin(), sectionPkgs.end());

    std::unordered_map<std::string, std::shared_ptr<Package>> pkgMap;
    for (auto &pkg : pkgs) {
        const auto &pkid = pkg->id();
        pkgMap[pkid] = pkg;
    }

    return pkgMap;
}

std::shared_ptr<Package> Engine::processExtraMetainfoData(
    const Suite &suite,
    std::shared_ptr<IconHandler> iconh,
    const std::string &section,
    const std::string &arch,
    std::shared_ptr<InjectedModifications> injMods)
{
    if (suite.extraMetainfoDir.empty() && !injMods->hasRemovedComponents())
        return nullptr;

    const auto extraMIDir = suite.extraMetainfoDir / section;
    const auto archExtraMIDir = extraMIDir / arch;

    if (suite.extraMetainfoDir.empty())
        logInfo("Injecting component removal requests for {}/{}/{}", suite.name, section, arch);
    else
        logInfo("Loading additional metainfo from local directory for {}/{}/{}", suite.name, section, arch);

    // We create a dummy package to hold information for the injected components
    auto diPkg = std::make_shared<DataInjectPackage>(EXTRA_METAINFO_FAKE_PKGNAME, arch);
    diPkg->setDataLocation(extraMIDir.string());
    diPkg->setArchDataLocation(archExtraMIDir.string());
    diPkg->setMaintainer("AppStream Generator Maintainer");

    // Ensure we have no leftover hints in the database.
    // Since this package never changes its version number, cruft data will not be automatically
    // removed for it.
    m_dstore->removePackage(diPkg->id());

    // Analyze our dummy package just like all other packages
    auto mde = std::make_unique<DataExtractor>(m_dstore, iconh, nullptr, nullptr);
    auto gres = mde->processPackage(diPkg);

    // Add removal requests, as we can remove packages from frozen suites via overlays
    injMods->addRemovalRequestsToResult(&gres);

    // Write resulting data into the database
    m_dstore->addGeneratorResult(m_conf->metadataType, gres, true);

    return diPkg;
}

bool Engine::processSuiteSection(const Suite &suite, const std::string &section, std::shared_ptr<ReportGenerator> rgen)
{
    auto reportgen = std::move(rgen);
    if (!reportgen)
        reportgen = std::make_shared<ReportGenerator>(m_dstore.get());

    // Load repo-level modifications
    auto injMods = std::make_shared<InjectedModifications>();
    try {
        injMods->loadForSuite(std::make_shared<Suite>(suite));
    } catch (const std::exception &e) {
        throw std::runtime_error(
            std::format("Unable to read modifications.json for suite {}: {}", suite.name, e.what()));
    }

    // Process packages by architecture
    std::vector<std::shared_ptr<Package>> sectionPkgs;
    bool suiteDataChanged = false;

    for (const auto &arch : suite.architectures) {
        // Update package contents information and flag boring packages as ignored
        const bool foundInteresting = seedContentsData(suite, section, arch) || m_forced;

        // Check if the suite/section/arch has actually changed
        if (!foundInteresting) {
            logInfo("Skipping {}/{} [{}], no interesting new packages since last update.", suite.name, section, arch);
            continue;
        }

        // Process new packages
        auto pkgs = m_pkgIndex->packagesFor(suite.name, section, arch);
        auto iconh = std::make_shared<IconHandler>(
            *m_cstore, m_dstore->mediaExportPoolDir(), getIconCandidatePackages(suite, section, arch), suite.iconTheme);
        processPackages(pkgs, iconh, injMods);

        // Read injected data and add it to the database as a fake package
        auto fakePkg = processExtraMetainfoData(suite, std::move(iconh), section, arch, injMods);
        if (fakePkg)
            pkgs.push_back(std::move(fakePkg));

        // Export package data
        exportMetadata(suite, section, arch, pkgs);
        suiteDataChanged = true;

        // We store the package info over all architectures to generate reports later
        sectionPkgs.reserve(sectionPkgs.capacity() + pkgs.size());
        sectionPkgs.insert(sectionPkgs.end(), pkgs.begin(), pkgs.end());

        // Log progress
        logInfo("Completed metadata processing of {}/{} [{}]", suite.name, section, arch);
    }

    // Finalize
    if (suiteDataChanged) {
        // Export icons for the found packages in this section
        exportIconTarballs(suite, section, sectionPkgs);

        // Write reports & statistics and render HTML, if that option is selected
        reportgen->processFor(suite.name, section, sectionPkgs);
    }

    // Release the index to free some memory
    m_pkgIndex->release();

    return suiteDataChanged;
}

SuiteUsabilityResult Engine::checkSuiteUsable(const std::string &suiteName)
{
    SuiteUsabilityResult res;
    res.suiteUsable = false;

    bool suiteFound = false;
    for (const auto &s : m_conf->suites) {
        if (s.name == suiteName) {
            res.suite = s;
            suiteFound = true;
            break;
        }
    }

    if (!suiteFound) {
        logError("Suite '{}' was not found.", suiteName);
        return res;
    }

    if (res.suite.isImmutable) {
        // We also can't process anything if there are no architectures defined
        logError("Suite '{}' is marked as immutable. No changes are allowed.", res.suite.name);
        return res;
    }

    if (res.suite.sections.empty()) {
        // If we have no sections, we can't do anything but exit...
        logError("Suite '{}' has no sections. Can not continue.", res.suite.name);
        return res;
    }

    if (res.suite.architectures.empty()) {
        // We also can't process anything if there are no architectures defined
        logError("Suite '{}' has no architectures defined. Can not continue.", res.suite.name);
        return res;
    }

    // If we are here, we can process this suite
    res.suiteUsable = true;
    return res;
}

bool Engine::processFile(
    const std::string &suiteName,
    const std::string &sectionName,
    const std::vector<std::string> &files)
{
    // Fetch suite and exit in case we can't write to it.
    auto suiteTuple = checkSuiteUsable(suiteName);
    if (!suiteTuple.suiteUsable)
        return false;
    auto suite = suiteTuple.suite;

    bool sectionValid = false;
    for (const auto &section : suite.sections) {
        if (section == sectionName) {
            sectionValid = true;
            break;
        }
    }
    if (!sectionValid) {
        logError("Section '{}' does not exist in suite '{}'. Can not continue.", sectionName, suite.name);
        return false;
    }

    std::unordered_map<std::string, std::vector<std::shared_ptr<Package>>> pkgByArch;
    for (const auto &fname : files) {
        auto pkg = m_pkgIndex->packageForFile(fname, suiteName, sectionName);
        if (!pkg) {
            logError(
                "Could not get package representation for file '{}' from backend '{}': The backend might not support "
                "this feature.",
                fname,
                m_conf->backendName);
            return false;
        }
        pkgByArch[pkg->arch()].push_back(pkg);
    }

    for (const auto &[arch, pkgs] : pkgByArch) {
        // Update package contents information and flag boring packages as ignored
        const bool foundInteresting = seedContentsData(suite, sectionName, arch, pkgs);

        // Skip if the new package files have no interesting data
        if (!foundInteresting) {
            logInfo("Skipping {}/{} [{}], no interesting new packages.", suite.name, sectionName, arch);
            continue;
        }

        // Process new packages
        auto iconh = std::make_shared<IconHandler>(
            *m_cstore,
            m_dstore->mediaExportPoolDir(),
            getIconCandidatePackages(suite, sectionName, arch),
            suite.iconTheme);
        processPackages(pkgs, std::move(iconh), nullptr);
    }

    return true;
}

void Engine::run(const std::string &suiteName)
{
    // Fetch suite and exit in case we can't write to it.
    // The `checkSuiteUsable` method will print an error
    // message in case the suite isn't usable.
    auto suiteCheck = checkSuiteUsable(suiteName);
    if (!suiteCheck.suiteUsable)
        return;
    auto suite = suiteCheck.suite;

    logVersionInfo();

    auto reportgen = std::make_shared<ReportGenerator>(m_dstore.get());

    bool dataChanged = false;
    for (const auto &section : suite.sections) {
        const bool ret = processSuiteSection(suite, section, reportgen);
        if (ret)
            dataChanged = true;
    }

    // Render index pages & statistics
    reportgen->updateIndexPages();
    if (dataChanged)
        reportgen->exportStatistics();
}

void Engine::run(const std::string &suiteName, const std::string &sectionName)
{
    // Fetch suite and exit in case we can't write to it.
    // The `checkSuiteUsable` method will print an error
    // message in case the suite isn't usable.
    auto suiteCheck = checkSuiteUsable(suiteName);
    if (!suiteCheck.suiteUsable)
        return;
    auto suite = suiteCheck.suite;

    logVersionInfo();

    bool sectionValid = false;
    for (const auto &section : suite.sections) {
        if (section == sectionName) {
            sectionValid = true;
            break;
        }
    }
    if (!sectionValid) {
        logError("Section '{}' does not exist in suite '{}'. Can not continue.", sectionName, suite.name);
        return;
    }

    auto reportgen = std::make_shared<ReportGenerator>(m_dstore.get());
    auto dataChanged = processSuiteSection(suite, sectionName, reportgen);

    // Render index pages & statistics
    reportgen->updateIndexPages();
    if (dataChanged)
        reportgen->exportStatistics();
}

void Engine::publishMetadataForSuiteSection(
    const Suite &suite,
    const std::string &section,
    std::shared_ptr<ReportGenerator> rgen)
{
    auto reportgen = std::move(rgen);
    if (!reportgen)
        reportgen = std::make_shared<ReportGenerator>(m_dstore.get());

    std::vector<std::shared_ptr<Package>> sectionPkgs;
    for (const auto &arch : suite.architectures) {
        // Process new packages
        auto pkgs = m_pkgIndex->packagesFor(suite.name, section, arch);

        // Export package data
        exportMetadata(suite, section, arch, pkgs);

        // We store the package info over all architectures to generate reports later
        sectionPkgs.insert(sectionPkgs.end(), pkgs.begin(), pkgs.end());

        // Log progress
        logInfo("Completed publishing of data for {}/{} [{}]", suite.name, section, arch);
    }

    // Export icons for the found packages in this section
    exportIconTarballs(suite, section, sectionPkgs);

    // Write reports & statistics and render HTML, if that option is selected
    reportgen->processFor(suite.name, section, sectionPkgs);

    // Free some memory explicitly
    m_pkgIndex->release();
}

void Engine::publish(const std::string &suiteName)
{
    // Fetch suite and exit in case we can't write to it.
    auto scResult = checkSuiteUsable(suiteName);
    if (!scResult.suiteUsable)
        return;
    auto suite = scResult.suite;

    logVersionInfo();

    auto reportgen = std::make_shared<ReportGenerator>(m_dstore.get());
    for (const auto &section : suite.sections)
        publishMetadataForSuiteSection(suite, section, reportgen);

    // Render index pages & statistics
    reportgen->updateIndexPages();
    reportgen->exportStatistics();
}

void Engine::publish(const std::string &suiteName, const std::string &sectionName)
{
    // Fetch suite and exit in case we can't write to it.
    auto scResult = checkSuiteUsable(suiteName);
    if (!scResult.suiteUsable)
        return;
    auto suite = scResult.suite;

    logVersionInfo();

    bool sectionValid = false;
    for (const auto &section : suite.sections) {
        if (section == sectionName) {
            sectionValid = true;
            break;
        }
    }
    if (!sectionValid) {
        logError("Section '{}' does not exist in suite '{}'. Can not continue.", sectionName, suite.name);
        return;
    }

    auto reportgen = std::make_shared<ReportGenerator>(m_dstore.get());
    publishMetadataForSuiteSection(suite, sectionName, reportgen);

    // Render index pages & statistics
    reportgen->updateIndexPages();
    reportgen->exportStatistics();
}

void Engine::cleanupStatistics()
{
    auto allStats = m_dstore->getStatistics();
    std::sort(allStats.begin(), allStats.end(), [](const auto &a, const auto &b) {
        return a.time < b.time;
    });

    std::unordered_map<std::string, std::vector<std::uint8_t>> lastStatData;
    std::unordered_map<std::string, std::size_t> lastTime;

    for (const auto &entry : allStats) {
        // We don't clean up combined statistics entries, and therefore need to reset
        // the last-data hashmaps as soon as we encounter one to not lose data.
        auto suiteIt = entry.data.find("suite");
        auto sectionIt = entry.data.find("section");

        if (suiteIt == entry.data.end() || sectionIt == entry.data.end()) {
            lastStatData.clear();
            lastTime.clear();
            continue;
        }

        const auto ssid = std::format(
            "{}-{}", std::get<std::string>(suiteIt->second), std::get<std::string>(sectionIt->second));

        if (lastStatData.find(ssid) == lastStatData.end()) {
            lastStatData[ssid] = entry.serialize();
            lastTime[ssid] = entry.time;
            continue;
        }

        auto sdata = entry.serialize();
        if (lastStatData[ssid] == sdata) {
            logInfo("Removing superfluous statistics entry: {}", lastTime[ssid]);
            m_dstore->removeStatistics(lastTime[ssid]);
        }

        lastTime[ssid] = entry.time;
        lastStatData[ssid] = std::move(sdata);
    }
}

void Engine::runCleanup()
{
    logVersionInfo();

    logInfo("Cleaning up left over temporary data.");
    const auto tmpDir = m_conf->cacheRootDir() / "tmp";
    if (fs::exists(tmpDir))
        fs::remove_all(tmpDir);

    logInfo("Collecting information.");

    // Get sets of all packages registered in the database
    std::unordered_set<std::string> pkidsContents;
    std::unordered_set<std::string> pkidsData;

    // Parallel collection of package IDs
    tbb::parallel_invoke(
        [&]() {
            pkidsContents = m_cstore->getPackageIdSet();
        },
        [&]() {
            pkidsData = m_dstore->getPackageIdSet();
        });
    logInfo("We have data on a total of {} packages (content lists on {})", pkidsData.size(), pkidsContents.size());

    // Build a set of all valid packages
    for (const auto &suite : m_conf->suites) {
        if (suite.isImmutable)
            continue; // Data from immutable suites is ignored

        for (const auto &section : suite.sections) {
            for (const auto &arch : suite.architectures) {
                // Fetch current packages without long descriptions, we really only are interested in the pkgid
                auto pkgs = m_pkgIndex->packagesFor(suite.name, section, arch, false);
                if (!suite.baseSuite.empty()) {
                    auto basePkgs = m_pkgIndex->packagesFor(suite.baseSuite, section, arch, false);
                    pkgs.insert(pkgs.end(), basePkgs.begin(), basePkgs.end());
                }

                {
                    std::lock_guard<std::mutex> lock(m_mutex);
                    for (const auto &pkg : pkgs) {
                        // Remove packages from the sets that are still active
                        pkidsContents.erase(pkg->id());
                        pkidsData.erase(pkg->id());
                    }

                    // Free some memory
                    m_pkgIndex->release();
                }
            }
        }
    }

    // Release index resources
    m_pkgIndex->release();

    logInfo("Cleaning up superseded data ({} hints/data, {} content lists).", pkidsData.size(), pkidsContents.size());

    // Remove packages from the caches which are no longer in the archive
    tbb::parallel_invoke(
        [&]() {
            m_cstore->removePackages(pkidsContents);
        },
        [&]() {
            m_dstore->removePackages(pkidsData);
        });

    // Remove orphaned data and media
    logInfo("Cleaning up obsolete media.");
    m_dstore->cleanupCruft();

    // Cleanup duplicate statistical entries
    logInfo("Cleaning up excess statistical data.");
    cleanupStatistics();
}

void Engine::removeHintsComponents(const std::string &suiteName)
{
    auto st = checkSuiteUsable(suiteName);
    if (!st.suiteUsable)
        return;
    auto suite = st.suite;

    logVersionInfo();

    for (const auto &section : suite.sections) {
        const auto &architectures = suite.architectures;

        tbb::parallel_for_each(architectures.begin(), architectures.end(), [&](const std::string &arch) {
            auto pkgs = m_pkgIndex->packagesFor(suite.name, section, arch, false);

            for (const auto &pkg : pkgs) {
                const auto &pkid = pkg->id();

                if (!m_dstore->packageExists(pkid))
                    continue;
                if (m_dstore->isIgnored(pkid))
                    continue;

                m_dstore->removePackage(pkid);
            }
        });

        m_pkgIndex->release();
    }

    m_dstore->cleanupCruft();
    m_pkgIndex->release();
}

void Engine::forgetPackage(const std::string &identifier)
{
    const auto slashCount = std::count(identifier.begin(), identifier.end(), '/');

    if (slashCount == 2) {
        // We have a package-id, so we can do a targeted remove
        const auto pkid = identifier;
        logDebug("Considering {} to be a package-id.", pkid);

        if (m_cstore->packageExists(pkid))
            m_cstore->removePackage(pkid);
        if (m_dstore->packageExists(pkid))
            m_dstore->removePackage(pkid);
        logInfo("Removed package with ID: {}", pkid);
    } else {
        auto pkids = m_dstore->getPkidsMatching(identifier);
        for (const auto &pkid : pkids) {
            m_dstore->removePackage(pkid);
            if (m_cstore->packageExists(pkid))
                m_cstore->removePackage(pkid);
            logInfo("Removed package with ID: {}", pkid);
        }
    }

    // Remove orphaned data and media
    m_dstore->cleanupCruft();
}

bool Engine::printPackageInfo(const std::string &identifier)
{
    const auto slashCount = std::count(identifier.begin(), identifier.end(), '/');

    if (slashCount != 2) {
        std::cout << "Please enter a package-id in the format <name>/<version>/<arch>\n";
        return false;
    }
    const auto pkid = identifier;

    std::cout << "== " << pkid << " ==\n";
    std::cout << "Contents:\n";
    auto pkgContents = m_cstore->getContents(pkid);
    if (pkgContents.empty()) {
        std::cout << "~ No contents found.\n";
    } else {
        for (const auto &s : pkgContents)
            std::cout << " " << s << "\n";
    }
    std::cout << "\n";

    std::cout << "Icons:\n";
    auto pkgIcons = m_cstore->getIcons(pkid);
    if (pkgIcons.empty()) {
        std::cout << "~ No icons found.\n";
    } else {
        for (const auto &s : pkgIcons)
            std::cout << " " << s << "\n";
    }
    std::cout << "\n";

    if (m_dstore->isIgnored(pkid)) {
        std::cout << "Ignored: yes\n";
        std::cout << "\n";
    } else {
        std::cout << "Global Component IDs:\n";
        for (const auto &s : m_dstore->getGCIDsForPackage(pkid))
            std::cout << "- " << s << "\n";
        std::cout << "\n";

        std::cout << "Generated Data:\n";
        for (const auto &s : m_dstore->getMetadataForPackage(m_conf->metadataType, pkid))
            std::cout << s << "\n";
        std::cout << "\n";
    }

    if (m_dstore->hasHints(pkid)) {
        std::cout << "Hints:\n";
        std::cout << m_dstore->getHints(pkid) << "\n";
    } else {
        std::cout << "Hints: None\n";
    }

    std::cout << "\n";

    return true;
}

} // namespace ASGenerator
