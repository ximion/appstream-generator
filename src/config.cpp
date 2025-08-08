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

#include <appstream-compose.h>
#include <libfyaml.h>
#include <glib.h>

#include "logging.h"
#include "utils.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

// Static member definitions
std::unique_ptr<Config> Config::instance_;
std::once_flag Config::initialized_;

Config::Config()
{
    // our default export format version
    formatVersion = AS_FORMAT_VERSION_V1_0;

    // find all the external binaries we (may) need
    // we search for them unconditionally, because the unittests may rely on their absolute
    // paths being set even if a particular feature flag that requires them isn't.
    const auto optipngBin_c = asc_globals_get_optipng_binary();
    optipngBinary = optipngBin_c? std::string(optipngBin_c) : "";

    g_autofree gchar *ffprobeBin_c = g_find_program_in_path("ffprobe");
    ffprobeBinary = ffprobeBin_c? std::string(ffprobeBin_c) : "";

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

    if (tdir.empty()) {
        const auto exeDir = fs::path(getExecutableDir());
        tdir = fs::canonical(exeDir / ".." / ".." / ".." / "data" / "templates");
        tdir = getVendorTemplateDir(tdir);

        if (tdir.empty()) {
            tdir = getVendorTemplateDir((fs::path(DATADIR) / "templates"));

            if (tdir.empty()) {
                tdir = fs::canonical(exeDir / ".." / "data" / "templates");
                tdir = getVendorTemplateDir(tdir);
            }
        }
    }

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
        auto tdir = (fs::path(dir) / toLower(projectName)).string();
        if (existsAndIsDir(tdir))
            return tdir;
    }

    auto tdir = (fs::path(dir) / "default").string();
    if (existsAndIsDir(tdir))
        return tdir;

    if (allowRoot && existsAndIsDir(dir))
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

static fy_document *parseJsonDocument(const std::string &jsonData)
{
    fy_parse_cfg cfg = {};
    cfg.flags = FYPCF_JSON_FORCE; // Force JSON mode

    auto fyp = fy_parser_create(&cfg);
    if (!fyp) {
        throw std::runtime_error("Failed to create YAML parser");
    }

    // Set the JSON string as input
    if (fy_parser_set_string(fyp, jsonData.c_str(), jsonData.length()) != 0) {
        fy_parser_destroy(fyp);
        throw std::runtime_error("Failed to set parser input");
    }

    // Parse the document
    auto fyd = fy_parse_load_document(fyp);
    fy_parser_destroy(fyp);

    if (!fyd)
        throw std::runtime_error("Failed to parse JSON/YAML document");

    return fyd;
}

static std::string getNodeStringValue(fy_node *node)
{
    if (!node || fy_node_get_type(node) != FYNT_SCALAR)
        return "";

    size_t len = 0;
    const char *value = fy_node_get_scalar(node, &len);
    return value ? std::string(value, len) : "";
}

static int64_t getNodeIntValue(fy_node *node, int64_t defaultValue = 0)
{
    if (!node || fy_node_get_type(node) != FYNT_SCALAR)
        return defaultValue;

    size_t len = 0;
    const char *value = fy_node_get_scalar(node, &len);
    if (!value)
        return defaultValue;

    try {
        return std::stoll(value);
    } catch (...) {
        return defaultValue;
    }
}

static bool getNodeBoolValue(fy_node *node, bool defaultValue = false)
{
    if (!node || fy_node_get_type(node) != FYNT_SCALAR)
        return defaultValue;

    const char *value = fy_node_get_scalar(node, nullptr);
    if (!value)
        return defaultValue;

    std::string strValue(value);
    return strValue == "true" || strValue == "1" || strValue == "yes";
}

static std::vector<std::string> getNodeArrayValues(fy_node *node)
{
    std::vector<std::string> result;

    if (!node || fy_node_get_type(node) != FYNT_SEQUENCE)
        return result;

    fy_node *item;
    void *iter = nullptr;
    while ((item = fy_node_sequence_iterate(node, &iter)) != nullptr) {
        auto value = getNodeStringValue(item);
        if (!value.empty()) {
            result.push_back(value);
        }
    }

    return result;
}

static fy_node *getNodeByKey(fy_node *mapping, const std::string &key)
{
    if (!mapping || fy_node_get_type(mapping) != FYNT_MAPPING)
        return nullptr;

    fy_node_pair *pair;
    void *iter = nullptr;
    while ((pair = fy_node_mapping_iterate(mapping, &iter)) != nullptr) {
        auto keyNode = fy_node_pair_key(pair);
        auto keyValue = getNodeStringValue(keyNode);
        if (keyValue == key) {
            return fy_node_pair_value(pair);
        }
    }

    return nullptr;
}

void Config::loadFromFile(
    const std::string &fname,
    const std::string &enforcedWorkspaceDir,
    const std::string &enforcedExportDir)
{
    // read the configuration JSON file
    auto jsonData = readFileToString(fname);

    std::unique_ptr<fy_document, decltype(&fy_document_destroy)> document(
        parseJsonDocument(jsonData), fy_document_destroy);

    auto root = fy_document_root(document.get());

    if (!root || fy_node_get_type(root) != FYNT_MAPPING) {
        throw std::runtime_error("Invalid JSON configuration file");
    }

    auto workspaceDirNode = getNodeByKey(root, "WorkspaceDir");
    if (workspaceDirNode) {
        m_workspaceDir = fs::path(getNodeStringValue(workspaceDirNode));
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

    auto projectNameNode = getNodeByKey(root, "ProjectName");
    projectName = projectNameNode ? getNodeStringValue(projectNameNode) : "Unknown";

    auto archiveRootNode = getNodeByKey(root, "ArchiveRoot");
    if (!archiveRootNode) {
        throw std::runtime_error("ArchiveRoot is required in configuration");
    }
    archiveRoot = getNodeStringValue(archiveRootNode);

    auto mediaBaseUrlNode = getNodeByKey(root, "MediaBaseUrl");
    mediaBaseUrl = mediaBaseUrlNode ? getNodeStringValue(mediaBaseUrlNode) : "";

    auto htmlBaseUrlNode = getNodeByKey(root, "HtmlBaseUrl");
    htmlBaseUrl = htmlBaseUrlNode ? getNodeStringValue(htmlBaseUrlNode) : "";

    // set root export directory
    if (enforcedExportDir.empty()) {
        m_exportDir = fs::path(m_workspaceDir) / "export";
    } else {
        m_exportDir = enforcedExportDir;
        logInfo("Using data export directory root from the command-line: {}", m_exportDir.string());
    }

    if (!m_exportDir.is_absolute())
        m_exportDir = fs::absolute(m_exportDir);

    // set the default export directory locations, allow people to override them in the config
    // (we convert the relative to absolute paths later)
    mediaExportDir = "media";
    dataExportDir = "data";
    hintsExportDir = "hints";
    htmlExportDir = "html";

    auto exportDirsNode = getNodeByKey(root, "ExportDirs");
    if (exportDirsNode && fy_node_get_type(exportDirsNode) == FYNT_MAPPING) {
        fy_node_pair *pair;
        void *iter = nullptr;
        while ((pair = fy_node_mapping_iterate(exportDirsNode, &iter)) != nullptr) {
            auto keyNode = fy_node_pair_key(pair);
            auto valueNode = fy_node_pair_value(pair);
            auto key = getNodeStringValue(keyNode);
            auto value = getNodeStringValue(valueNode);

            if (key == "Media") {
                mediaExportDir = value;
            } else if (key == "Data") {
                dataExportDir = value;
            } else if (key == "Hints") {
                hintsExportDir = value;
            } else if (key == "Html") {
                htmlExportDir = value;
            } else {
                logWarning("Unknown export directory specifier in config: {}", key);
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
    auto extraMetainfoDir = (fs::path(m_workspaceDir) / "extra-metainfo").string();
    auto extraMetainfoDirNode = getNodeByKey(root, "ExtraMetainfoDir");
    if (extraMetainfoDirNode) {
        extraMetainfoDir = getNodeStringValue(extraMetainfoDirNode);
    }

    auto caInfoNode = getNodeByKey(root, "CAInfo");
    if (caInfoNode)
        caInfo = getNodeStringValue(caInfoNode);

    // allow specifying the AppStream format version we build data for.
    auto formatVersionNode = getNodeByKey(root, "FormatVersion");
    if (formatVersionNode) {
        auto versionStr = getNodeStringValue(formatVersionNode);
        if (versionStr == "1.0") {
            formatVersion = AS_FORMAT_VERSION_V1_0;
        } else {
            logWarning(
                "Configuration tried to set unknown AppStream format version '{}'. Falling back to default version.",
                versionStr);
        }
    }

    // we default to the Debian backend for now
    metadataType = DataType::XML;
    std::string backendId = "debian";
    auto backendNode = getNodeByKey(root, "Backend");
    if (backendNode)
        backendId = toLower(getNodeStringValue(backendNode));

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
    auto metadataTypeNode = getNodeByKey(root, "MetadataType");
    if (metadataTypeNode) {
        auto mdataTypeStr = toLower(getNodeStringValue(metadataTypeNode));
        if (mdataTypeStr == "yaml") {
            metadataType = DataType::YAML;
        } else if (mdataTypeStr == "xml") {
            metadataType = DataType::XML;
        } else {
            logError("Invalid value '{}' for MetadataType setting.", mdataTypeStr);
        }
    }

    // suite selections
    bool hasImmutableSuites = false;
    auto suitesNode = getNodeByKey(root, "Suites");
    if (suitesNode && fy_node_get_type(suitesNode) == FYNT_MAPPING) {
        fy_node_pair *pair;
        void *iter = nullptr;
        while ((pair = fy_node_mapping_iterate(suitesNode, &iter)) != nullptr) {
            auto keyNode = fy_node_pair_key(pair);
            auto valueNode = fy_node_pair_value(pair);
            auto suiteName = getNodeStringValue(keyNode);

            Suite suite;
            suite.name = suiteName;

            // Having a suite named "pool" will result in the media pool being copied on
            // itself if immutableSuites is used. Since 'pool' is a bad suite name anyway,
            // we error out early on this.
            if (suiteName == "pool")
                throw std::runtime_error("The name 'pool' is forbidden for a suite.");

            auto dataPriorityNode = getNodeByKey(valueNode, "dataPriority");
            if (dataPriorityNode)
                suite.dataPriority = static_cast<int>(getNodeIntValue(dataPriorityNode));

            auto baseSuiteNode = getNodeByKey(valueNode, "baseSuite");
            if (baseSuiteNode)
                suite.baseSuite = getNodeStringValue(baseSuiteNode);

            auto iconThemeNode = getNodeByKey(valueNode, "useIconTheme");
            if (iconThemeNode)
                suite.iconTheme = getNodeStringValue(iconThemeNode);

            auto sectionsNode = getNodeByKey(valueNode, "sections");
            if (sectionsNode)
                suite.sections = getNodeArrayValues(sectionsNode);

            auto architecturesNode = getNodeByKey(valueNode, "architectures");
            if (architecturesNode)
                suite.architectures = getNodeArrayValues(architecturesNode);

            auto immutableNode = getNodeByKey(valueNode, "immutable");
            if (immutableNode) {
                suite.isImmutable = getNodeBoolValue(immutableNode);
                if (suite.isImmutable) {
                    hasImmutableSuites = true;
                }
            }

            auto suiteExtraMIDir = fs::path(extraMetainfoDir) / suite.name;
            if (fs::exists(suiteExtraMIDir) && fs::is_directory(suiteExtraMIDir))
                suite.extraMetainfoDir = suiteExtraMIDir.string();

            suites.push_back(suite);
        }
    }

    auto oldsuitesNode = getNodeByKey(root, "Oldsuites");
    if (oldsuitesNode)
        oldsuites = getNodeArrayValues(oldsuitesNode);

    // icon policy
    auto iconsNode = getNodeByKey(root, "Icons");
    if (iconsNode && fy_node_get_type(iconsNode) == FYNT_MAPPING) {
        fy_node_pair *pair;
        void *iter = nullptr;
        while ((pair = fy_node_mapping_iterate(iconsNode, &iter)) != nullptr) {
            auto keyNode = fy_node_pair_key(pair);
            auto valueNode = fy_node_pair_value(pair);
            auto iconString = getNodeStringValue(keyNode);

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
                logError("Malformed icon size '{}' found in configuration, icon policy has been ignored.", iconString);
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
                logError("Invalid icon size '{}' selected in configuration, icon policy has been ignored.", iconString);
                continue;
            }

            bool storeRemote = false;
            bool storeCached = false;

            auto remoteNode = getNodeByKey(valueNode, "remote");
            if (remoteNode)
                storeRemote = getNodeBoolValue(remoteNode);

            auto cachedNode = getNodeByKey(valueNode, "cached");
            if (cachedNode)
                storeCached = getNodeBoolValue(cachedNode);

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
                    logError(
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
    auto maxScrFileSizeNode = getNodeByKey(root, "MaxScreenshotFileSize");
    if (maxScrFileSizeNode) {
        maxScrFileSize = getNodeIntValue(maxScrFileSizeNode);
    }

    auto allowedCustomKeysNode = getNodeByKey(root, "AllowedCustomKeys");
    if (allowedCustomKeysNode) {
        auto keysList = getNodeArrayValues(allowedCustomKeysNode);
        for (const auto &key : keysList) {
            allowedCustomKeys[key] = true;
        }
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
    auto featuresNode = getNodeByKey(root, "Features");
    if (featuresNode && fy_node_get_type(featuresNode) == FYNT_MAPPING) {
        fy_node_pair *pair;
        void *iter = nullptr;
        while ((pair = fy_node_mapping_iterate(featuresNode, &iter)) != nullptr) {
            auto keyNode = fy_node_pair_key(pair);
            auto valueNode = fy_node_pair_value(pair);
            auto featureId = getNodeStringValue(keyNode);
            auto featureValue = getNodeBoolValue(valueNode);

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
            logError("Disabled feature `optimizePNGSize`: The `optipng` binary was not found.");
        } else {
            logDebug("Using `optipng`: {}", optipngBinary);
        }
    }
    asc_globals_set_use_optipng(feature.optipng);

    if (feature.screenshotVideos) {
        if (ffprobeBinary.empty()) {
            feature.screenshotVideos = false;
            logError("Disabled feature `screenshotVideos`: The `ffprobe` binary was not found.");
        } else {
            logDebug("Using `ffprobe`: {}", ffprobeBinary);
        }
    }

    if (feature.noDownloads) {
        // since disallowing network access might have quite a lot of sideeffects, we print
        // a message to the logs to make debugging easier.
        // in general, running with noDownloads is discouraged.
        logWarning("Configuration does not permit downloading files. Several features will not be available.");
    }

    if (!feature.immutableSuites) {
        // Immutable suites won't work if the feature is disabled - log this error
        if (hasImmutableSuites) {
            logError(
                "Suites are defined as immutable, but the `immutableSuites` feature is disabled. Immutability will not "
                "work!");
        }
    }

    if (!feature.validate)
        logWarning("MetaInfo validation has been disabled in configuration.");

    // sanity check to warn if our GdkPixbuf does not support the minimum amount
    // of image formats we need
    g_autoptr(GHashTable) pbFormatNames = asc_image_supported_format_names();
    if (!g_hash_table_contains(pbFormatNames, "png") || !g_hash_table_contains(pbFormatNames, "svg")
        || !g_hash_table_contains(pbFormatNames, "jpeg")) {
        logError(
            "The currently used GdkPixbuf does not seem to support all image formats we require to run normally "
            "(png/svg/jpeg). This may be a problem with your installation of appstream-generator or gdk-pixbuf.");
    }
}

bool Config::isValid() const
{
    return !projectName.empty();
}

/**
 * Get unique temporary directory to use during one generator run.
 */
fs::path Config::getTmpDir()
{
    static std::mutex tmpDirMutex;
    std::lock_guard<std::mutex> lock(tmpDirMutex);

    if (m_tmpDir.empty()) {
        std::string root;
        if (cacheRootDir().empty()) {
            root = "/tmp/";
        } else {
            root = cacheRootDir();
        }

        m_tmpDir = fs::path(root) / "tmp" / std::format("asgen-{}", randomString(8));

        // make appstream-compose internal functions aware of the new temp dir
        asc_globals_set_tmp_dir(m_tmpDir.c_str());
    }

    return m_tmpDir;
}

} // namespace ASGenerator
