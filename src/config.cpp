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
#include "config.h"

#include <fstream>
#include <sstream>
#include <format>
#include <algorithm>
#include <unistd.h>
#include <cstdlib>
#include <filesystem>
#include <mutex>
#include <system_error>

#include <appstream-compose.h>
#include <glib.h>

#include "logging.h"
#include "utils.h"
#include "yaml-utils.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

// Static member definitions
std::unique_ptr<Config> Config::instance_;
std::once_flag Config::initialized_;

/**
 * Read an image format name from the configuration.
 * Renditions can only ever be written as PNG or JPEG-XL, so any other format name is
 * rejected and @fallback is used instead.
 */
static AscImageFormat parseImageFormat(
    const std::string &formatStr,
    AscImageFormat fallback,
    quill::Logger *log,
    const std::string &context)
{
    const auto format = asc_image_format_from_string(Utils::toLower(formatStr).c_str());
    if (format != ASC_IMAGE_FORMAT_PNG && format != ASC_IMAGE_FORMAT_JXL) {
        LOG_ERROR(
            log,
            "Invalid value '{}' for the {}: Media can only be generated as 'png' or 'jxl'. Using '{}'.",
            formatStr,
            context,
            asc_image_format_to_string(fallback));
        return fallback;
    }

    return format;
}

Config::Config()
    : backend(Backend::Unknown),
      metadataType(DataType::XML),
      maxScrFileSize(14),
      m_log(getLogger("config"))
{
    // our default export format version
    formatVersion = AS_FORMAT_VERSION_V1_0;

    // find all the external binaries we (may) need
    // we search for them unconditionally, because the unittests may rely on their absolute
    // paths being set even if a particular feature flag that requires them isn't.
    const auto optipngBin_c = asc_globals_get_optipng_binary();
    optipngBinary = optipngBin_c ? std::string(optipngBin_c) : "";

    g_autofree gchar *ffprobeBin_c = g_find_program_in_path("ffprobe");
    ffprobeBinary = ffprobeBin_c ? std::string(ffprobeBin_c) : "";

    // new default icon policy instance
    m_iconPolicy = asc_icon_policy_new();
}

Config::~Config()
{
    if (m_iconPolicy)
        g_object_unref(m_iconPolicy);
}

Config &Config::get()
{
    std::call_once(initialized_, []() {
        instance_ = std::unique_ptr<Config>(new Config());
    });
    return *instance_;
}

std::string Config::formatVersionStr() const
{
    return as_format_version_to_string(formatVersion);
}

fs::path Config::databaseDir() const
{
    return m_workspaceDir / "db";
}

fs::path Config::cacheRootDir() const
{
    return m_workspaceDir / "cache";
}

fs::path Config::templateDir() const
{
    // find a suitable template directory
    // first check the workspace
    auto tdir = m_workspaceDir / "templates";
    tdir = getVendorTemplateDir(tdir, true);

    if (tdir.empty())
        tdir = getVendorTemplateDir(Utils::getDataPath("templates"));

    return tdir;
}

AscIconPolicy *Config::iconPolicy() const
{
    return m_iconPolicy;
}

/**
 * Helper function to determine a vendor template directory.
 */
fs::path Config::getVendorTemplateDir(const std::string &dir, bool allowRoot) const
{
    if (!projectName.empty()) {
        auto tdir = (fs::path(dir) / Utils::toLower(projectName)).string();
        if (Utils::existsAndIsDir(tdir))
            return tdir;
    }

    auto tdir = (fs::path(dir) / "default").string();
    if (Utils::existsAndIsDir(tdir))
        return tdir;

    if (allowRoot && Utils::existsAndIsDir(dir))
        return dir;

    return {};
}

static std::string readFileToString(const std::string &filename)
{
    std::ifstream file(filename);
    if (!file.is_open())
        throw std::runtime_error(std::format("Could not open file: {}", filename));

    std::stringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

void Config::loadFromFile(
    const std::string &fname,
    const std::string &enforcedWorkspaceDir,
    const std::string &enforcedExportDir)
{
    // read configuration file content (JSON or YAML)
    auto configData = readFileToString(fname);

    auto doc = Yaml::parseDocument(configData);
    auto root = fy_document_root(doc.get());

    if (!root || fy_node_get_type(root) != FYNT_MAPPING) {
        throw std::runtime_error("Invalid configuration file: Expected a mapping object");
    }

    auto workspaceDirNode = Yaml::nodeByKey(root, "WorkspaceDir");
    if (workspaceDirNode) {
        m_workspaceDir = fs::path(Yaml::nodeStrValue(workspaceDirNode));
    } else {
        m_workspaceDir = fs::path(fname).parent_path();
        if (m_workspaceDir.empty())
            m_workspaceDir = fs::current_path();
    }

    // allow overriding the workspace location
    if (!enforcedWorkspaceDir.empty())
        m_workspaceDir = enforcedWorkspaceDir;

    if (!fs::path(m_workspaceDir).is_absolute())
        m_workspaceDir = fs::absolute(m_workspaceDir);

    auto projectNameNode = Yaml::nodeByKey(root, "ProjectName");
    projectName = projectNameNode ? Yaml::nodeStrValue(projectNameNode) : "Unknown";

    auto archiveRootNode = Yaml::nodeByKey(root, "ArchiveRoot");
    if (!archiveRootNode) {
        throw std::runtime_error("ArchiveRoot is required in configuration");
    }
    archiveRoot = Yaml::nodeStrValue(archiveRootNode);

    auto mediaBaseUrlNode = Yaml::nodeByKey(root, "MediaBaseUrl");
    mediaBaseUrl = mediaBaseUrlNode ? Yaml::nodeStrValue(mediaBaseUrlNode) : "";

    auto htmlBaseUrlNode = Yaml::nodeByKey(root, "HtmlBaseUrl");
    htmlBaseUrl = htmlBaseUrlNode ? Yaml::nodeStrValue(htmlBaseUrlNode) : "";

    // set root export directory
    if (enforcedExportDir.empty()) {
        m_exportDir = fs::path(m_workspaceDir) / "export";
    } else {
        m_exportDir = enforcedExportDir;
        LOG_INFO(m_log, "Using data export directory root from the command-line: {}", m_exportDir.string());
    }

    if (!m_exportDir.is_absolute())
        m_exportDir = fs::absolute(m_exportDir);

    // set the default export directory locations, allow people to override them in the config
    // (we convert the relative to absolute paths later)
    mediaExportDir = "media";
    dataExportDir = "data";
    hintsExportDir = "hints";
    htmlExportDir = "html";

    auto exportDirsNode = Yaml::nodeByKey(root, "ExportDirs");
    if (exportDirsNode && fy_node_get_type(exportDirsNode) == FYNT_MAPPING) {
        fy_node_pair *pair;
        void *iter = nullptr;
        while ((pair = fy_node_mapping_iterate(exportDirsNode, &iter)) != nullptr) {
            auto keyNode = fy_node_pair_key(pair);
            auto valueNode = fy_node_pair_value(pair);
            auto key = Yaml::nodeStrValue(keyNode);
            auto value = Yaml::nodeStrValue(valueNode);

            if (key == "Media") {
                mediaExportDir = value;
            } else if (key == "Data") {
                dataExportDir = value;
            } else if (key == "Hints") {
                hintsExportDir = value;
            } else if (key == "Html") {
                htmlExportDir = value;
            } else {
                LOG_WARNING(m_log, "Unknown export directory specifier in config: {}", key);
            }
        }
    }

    // convert export directory paths to absolute paths if necessary
    auto makeAbsoluteExportPath = [&](const fs::path &path) {
        return path.is_absolute() ? path : fs::absolute(fs::path(m_exportDir) / path);
    };

    mediaExportDir = makeAbsoluteExportPath(mediaExportDir);
    dataExportDir = makeAbsoluteExportPath(dataExportDir);
    hintsExportDir = makeAbsoluteExportPath(hintsExportDir);
    htmlExportDir = makeAbsoluteExportPath(htmlExportDir);

    // a place where external metainfo data can be injected
    auto extraMetainfoDir = m_workspaceDir / "extra-metainfo";
    auto extraMetainfoDirNode = Yaml::nodeByKey(root, "ExtraMetainfoDir");
    if (extraMetainfoDirNode)
        extraMetainfoDir = Yaml::nodeStrValue(extraMetainfoDirNode);

    auto caInfoNode = Yaml::nodeByKey(root, "CAInfo");
    if (caInfoNode)
        caInfo = Yaml::nodeStrValue(caInfoNode);

    // allow specifying the AppStream format version we build data for.
    auto formatVersionNode = Yaml::nodeByKey(root, "FormatVersion");
    if (formatVersionNode) {
        auto versionStr = Yaml::nodeStrValue(formatVersionNode);
        if (versionStr == "1.0") {
            formatVersion = AS_FORMAT_VERSION_V1_0;
        } else {
            LOG_WARNING(
                m_log,
                "Configuration tried to set unknown AppStream format version '{}'. Falling back to default version.",
                versionStr);
        }
    }

    // we default to the Debian backend for now
    metadataType = DataType::XML;
    std::string backendId = "debian";
    auto backendNode = Yaml::nodeByKey(root, "Backend");
    if (backendNode)
        backendId = Utils::toLower(Yaml::nodeStrValue(backendNode));

    if (backendId == "dummy") {
        backendName = "Dummy";
        backend = Backend::Dummy;
        metadataType = DataType::YAML;
    } else if (backendId == "debian") {
        backendName = "Debian";
        backend = Backend::Debian;
        metadataType = DataType::YAML;
    } else if (backendId == "ubuntu") {
        backendName = "Ubuntu";
        backend = Backend::Ubuntu;
        metadataType = DataType::YAML;
    } else if (backendId == "arch" || backendId == "archlinux") {
        backendName = "Arch Linux";
        backend = Backend::Archlinux;
        metadataType = DataType::XML;
    } else if (backendId == "mageia" || backendId == "rpmmd") {
        backendName = "RpmMd";
        backend = Backend::RpmMd;
        metadataType = DataType::XML;
    } else if (backendId == "alpinelinux") {
        backendName = "Alpine Linux";
        backend = Backend::Alpinelinux;
        metadataType = DataType::XML;
    } else if (backendId == "freebsd") {
        backendName = "FreeBSD";
        backend = Backend::FreeBSD;
        metadataType = DataType::XML;
    }

    // override the backend's default metadata type if requested by user
    auto metadataTypeNode = Yaml::nodeByKey(root, "MetadataType");
    if (metadataTypeNode) {
        auto mdataTypeStr = Utils::toLower(Yaml::nodeStrValue(metadataTypeNode));
        if (mdataTypeStr == "yaml") {
            metadataType = DataType::YAML;
        } else if (mdataTypeStr == "xml") {
            metadataType = DataType::XML;
        } else {
            LOG_ERROR(m_log, "Invalid value '{}' for MetadataType setting.", mdataTypeStr);
        }
    }

    // set the format that generated media is stored in. Suites may override this individually,
    // so distributors can e.g. keep serving PNG for older releases while newer ones use JPEG-XL
    imageFormat = ASC_IMAGE_FORMAT_JXL;
    auto imageFormatNode = Yaml::nodeByKey(root, "ImageFormat");
    if (imageFormatNode)
        imageFormat = parseImageFormat(Yaml::nodeStrValue(imageFormatNode), imageFormat, m_log, "ImageFormat setting");

    // suite selections
    suites.clear();
    bool hasImmutableSuites = false;
    auto suitesNode = Yaml::nodeByKey(root, "Suites");
    if (suitesNode && fy_node_get_type(suitesNode) == FYNT_MAPPING) {
        fy_node_pair *pair;
        void *iter = nullptr;
        while ((pair = fy_node_mapping_iterate(suitesNode, &iter)) != nullptr) {
            auto keyNode = fy_node_pair_key(pair);
            auto valueNode = fy_node_pair_value(pair);
            auto suiteName = Yaml::nodeStrValue(keyNode);

            Suite suite;
            suite.name = suiteName;
            suite.imageFormat = imageFormat;

            // Having a suite named "pool" will result in the media pool being copied on
            // itself if immutableSuites is used. Since 'pool' is a bad suite name anyway,
            // we error out early on this.
            // The same goes for ".staging", which is where media is rendered before it is
            // moved into the pool.
            if (suiteName == "pool" || suiteName == ".staging")
                throw std::runtime_error(std::format("The name '{}' is forbidden for a suite.", suiteName));

            auto dataPriorityNode = Yaml::nodeByKey(valueNode, "dataPriority");
            if (dataPriorityNode)
                suite.dataPriority = static_cast<int>(Yaml::nodeIntValue(dataPriorityNode));

            auto baseSuiteNode = Yaml::nodeByKey(valueNode, "baseSuite");
            if (baseSuiteNode)
                suite.baseSuite = Yaml::nodeStrValue(baseSuiteNode);

            auto iconThemeNode = Yaml::nodeByKey(valueNode, "useIconTheme");
            if (iconThemeNode)
                suite.iconTheme = Yaml::nodeStrValue(iconThemeNode);

            auto sectionsNode = Yaml::nodeByKey(valueNode, "sections");
            if (sectionsNode)
                suite.sections = Yaml::nodeArrayValues(sectionsNode);

            auto architecturesNode = Yaml::nodeByKey(valueNode, "architectures");
            if (architecturesNode)
                suite.architectures = Yaml::nodeArrayValues(architecturesNode);

            auto suiteImageFormatNode = Yaml::nodeByKey(valueNode, "imageFormat");
            if (suiteImageFormatNode)
                suite.imageFormat = parseImageFormat(
                    Yaml::nodeStrValue(suiteImageFormatNode),
                    suite.imageFormat,
                    m_log,
                    std::format("imageFormat setting of suite '{}'", suiteName));

            auto immutableNode = Yaml::nodeByKey(valueNode, "immutable");
            if (immutableNode) {
                suite.isImmutable = Yaml::nodeBoolValue(immutableNode);
                if (suite.isImmutable) {
                    hasImmutableSuites = true;
                }
            }

            auto suiteExtraMIDir = extraMetainfoDir / suite.name;
            if (fs::exists(suiteExtraMIDir) && fs::is_directory(suiteExtraMIDir))
                suite.extraMetainfoDir = std::move(suiteExtraMIDir);

            suites.push_back(std::move(suite));
        }
    }

    auto oldsuitesNode = Yaml::nodeByKey(root, "Oldsuites");
    if (oldsuitesNode)
        oldsuites = Yaml::nodeArrayValues(oldsuitesNode);

    // icon policy
    auto iconsNode = Yaml::nodeByKey(root, "Icons");
    if (iconsNode && fy_node_get_type(iconsNode) == FYNT_MAPPING) {
        fy_node_pair *pair;
        void *iter = nullptr;
        while ((pair = fy_node_mapping_iterate(iconsNode, &iter)) != nullptr) {
            auto keyNode = fy_node_pair_key(pair);
            auto valueNode = fy_node_pair_value(pair);
            auto iconString = Yaml::nodeStrValue(keyNode);

            // Parse icon size in ImageSize constructor
            ImageSize iconSize;
            bool isBadIconSize = false;
            try {
                iconSize = ImageSize(iconString);
                if (iconSize.width == 0)
                    isBadIconSize = true;
            } catch (const std::exception &e) {
                isBadIconSize = true;
            }
            if (isBadIconSize) {
                LOG_ERROR(
                    m_log,
                    "Malformed icon size '{}' found in configuration, icon policy has been ignored.",
                    iconString);
                continue;
            }

            // Check if the parsed icon size is in the list of allowed icon sizes
            bool isAllowed = false;
            for (const auto &allowedSize : AllowedIconSizes) {
                if (allowedSize == iconSize) {
                    isAllowed = true;
                    break;
                }
            }
            if (!isAllowed) {
                LOG_ERROR(
                    m_log,
                    "Invalid icon size '{}' selected in configuration, icon policy has been ignored.",
                    iconString);
                continue;
            }

            bool storeRemote = false;
            bool storeCached = false;

            auto remoteNode = Yaml::nodeByKey(valueNode, "remote");
            if (remoteNode)
                storeRemote = Yaml::nodeBoolValue(remoteNode);

            auto cachedNode = Yaml::nodeByKey(valueNode, "cached");
            if (cachedNode)
                storeCached = Yaml::nodeBoolValue(cachedNode);

            AscIconState istate = ASC_ICON_STATE_IGNORED;
            if (storeRemote && storeCached) {
                istate = ASC_ICON_STATE_CACHED_REMOTE;
            } else if (storeRemote) {
                istate = ASC_ICON_STATE_REMOTE_ONLY;
            } else if (storeCached) {
                istate = ASC_ICON_STATE_CACHED_ONLY;
            }

            // sanity check
            if (iconSize == ImageSize(64)) {
                if (!storeCached) {
                    LOG_ERROR(
                        m_log,
                        "The icon size 64x64 must always be present and be allowed to be cached. Ignored user "
                        "configuration.");
                    continue;
                }
            }

            // set new policy, overriding existing one
            asc_icon_policy_set_policy(m_iconPolicy, iconSize.width, iconSize.scale, istate);
        }
    }

    maxScrFileSize = 14; // 14MiB is the default maximum size
    auto maxScrFileSizeNode = Yaml::nodeByKey(root, "MaxScreenshotFileSize");
    if (maxScrFileSizeNode)
        maxScrFileSize = Yaml::nodeIntValue(maxScrFileSizeNode);

    allowedCustomKeys.clear();
    auto allowedCustomKeysNode = Yaml::nodeByKey(root, "AllowedCustomKeys");
    if (allowedCustomKeysNode) {
        auto keysList = Yaml::nodeArrayValues(allowedCustomKeysNode);
        for (const auto &key : keysList)
            allowedCustomKeys[key] = true;
    }

    // Enable features which are default-enabled
    feature.processDesktop = true;
    feature.validate = true;
    feature.storeScreenshots = true;
    feature.optipng = true;
    feature.metadataTimestamps = true;
    feature.immutableSuites = true;
    feature.processFonts = true;
    feature.allowIconUpscale = true;
    feature.processGStreamer = true;
    feature.processLocale = true;
    feature.screenshotVideos = true;

    // apply vendor feature settings
    auto featuresNode = Yaml::nodeByKey(root, "Features");
    if (featuresNode && fy_node_get_type(featuresNode) == FYNT_MAPPING) {
        fy_node_pair *pair;
        void *iter = nullptr;
        while ((pair = fy_node_mapping_iterate(featuresNode, &iter)) != nullptr) {
            auto keyNode = fy_node_pair_key(pair);
            auto valueNode = fy_node_pair_value(pair);
            auto featureId = Yaml::nodeStrValue(keyNode);
            auto featureValue = Yaml::nodeBoolValue(valueNode);

            if (featureId == "validateMetainfo") {
                feature.validate = featureValue;
            } else if (featureId == "processDesktop") {
                feature.processDesktop = featureValue;
            } else if (featureId == "noDownloads") {
                feature.noDownloads = featureValue;
            } else if (featureId == "createScreenshotsStore") {
                feature.storeScreenshots = featureValue;
            } else if (featureId == "optimizePNGSize") {
                feature.optipng = featureValue;
            } else if (featureId == "metadataTimestamps") {
                feature.metadataTimestamps = featureValue;
            } else if (featureId == "immutableSuites") {
                feature.immutableSuites = featureValue;
            } else if (featureId == "processFonts") {
                feature.processFonts = featureValue;
            } else if (featureId == "allowIconUpscaling") {
                feature.allowIconUpscale = featureValue;
            } else if (featureId == "processGStreamer") {
                feature.processGStreamer = featureValue;
            } else if (featureId == "processLocale") {
                feature.processLocale = featureValue;
            } else if (featureId == "screenshotVideos") {
                feature.screenshotVideos = featureValue;
            } else if (featureId == "propagateMetaInfoArtifacts") {
                feature.propagateMetaInfoArtifacts = featureValue;
            }
        }
    }

    // check if we need to disable features because some prerequisites are not met
    if (feature.optipng) {
        if (optipngBinary.empty()) {
            feature.optipng = false;
            LOG_ERROR(m_log, "Disabled feature `optimizePNGSize`: The `optipng` binary was not found.");
        } else {
            LOG_DEBUG(m_log, "Using `optipng`: {}", optipngBinary);
        }
    }
    asc_globals_set_use_optipng(feature.optipng);

    if (feature.screenshotVideos) {
        if (ffprobeBinary.empty()) {
            feature.screenshotVideos = false;
            LOG_ERROR(m_log, "Disabled feature `screenshotVideos`: The `ffprobe` binary was not found.");
        } else {
            LOG_DEBUG(m_log, "Using `ffprobe`: {}", ffprobeBinary);
        }
    }

    if (feature.noDownloads) {
        // since disallowing network access might have quite a lot of sideeffects, we print
        // a message to the logs to make debugging easier.
        // in general, running with noDownloads is discouraged.
        LOG_WARNING(m_log, "Configuration does not permit downloading files. Several features will not be available.");
    }

    if (!feature.immutableSuites) {
        // Immutable suites won't work if the feature is disabled - log this error
        if (hasImmutableSuites) {
            LOG_ERROR(
                m_log,
                "Suites are defined as immutable, but the `immutableSuites` feature is disabled. Immutability will not "
                "work!");
        }
    }

    if (!feature.validate)
        LOG_WARNING(m_log, "MetaInfo validation has been disabled in configuration.");

    // hand our temporary directory to appstream-compose. this has to happen before the
    // media worker check below, which seals the global compose settings - every setter
    // called after that point is refused with a warning.
    ensureTmpDir();

    // sanity check to see whether we can process media at all: all image, font and video
    // handling is done by a helper process, and if we can not even launch it, no amount of
    // data processing will yield any usable result.
    // doing this here means we fail with a clear message instead of drowning in per-package hints.
    {
        g_autoptr(AscMedia) media = asc_media_new();
        g_autoptr(GError) error = nullptr;
        if (asc_media_ensure_worker(media, nullptr, &error))
            asc_media_stop(media);
        else
            LOG_CRITICAL(
                m_log,
                "The AppStream media worker process could not be started: {} "
                "Image, font and video processing will not work.",
                error->message);
    }
}

bool Config::isValid() const
{
    return !projectName.empty();
}

/**
 * Settle the unique temporary directory to use during one generator run and make
 * appstream-compose use it as well.
 *
 * This has to happen before anything seals the global compose settings: once compose
 * work has begun, `asc_globals_set_tmp_dir()` is refused with a warning and compose
 * silently keeps using a directory of its own below /tmp.
 *
 * We create the directory right away on purpose. `asc_compose_run()` claims ownership
 * of the temporary directory if it does not exist yet, and deletes it recursively once
 * it is done - and we run one compose per package on several threads, all of them
 * sharing this directory. Letting compose own it would have the first run to finish
 * delete the scratch data of every other one still working.
 */
void Config::ensureTmpDir() const
{
    static std::mutex tmpDirMutex;
    std::lock_guard<std::mutex> lock(tmpDirMutex);

    if (!m_tmpDir.empty())
        return;

    std::string root;
    if (cacheRootDir().empty())
        root = "/tmp/";
    else
        root = cacheRootDir();

    m_tmpDir = fs::path(root) / "tmp" / std::format("asgen-{}", Utils::randomString(8));

    std::error_code ec;
    fs::create_directories(m_tmpDir, ec);
    if (ec)
        LOG_WARNING(m_log, "Unable to create temporary directory `{}`: {}", m_tmpDir.string(), ec.message());

    // make appstream-compose internal functions aware of the new temp dir
    asc_globals_set_tmp_dir(m_tmpDir.c_str());
}

/**
 * Get unique temporary directory to use during one generator run.
 */
fs::path Config::getTmpDir() const
{
    ensureTmpDir();
    return m_tmpDir;
}

void Config::setWorkspaceDir(const fs::path &dir)
{
    m_workspaceDir = dir;
}

} // namespace ASGenerator
