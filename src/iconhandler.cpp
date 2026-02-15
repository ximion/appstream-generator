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

#include "iconhandler.h"

#include <format>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <ranges>
#include <appstream-compose.h>
#include <gio/gio.h>

#include <tbb/parallel_for_each.h>

#include "config.h"
#include "logging.h"
#include "result.h"
#include "utils.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

// all image extensions that we recognize as possible for icons.
// the most favorable file extension needs to come first to prefer it
inline constexpr std::array<std::string_view, 9> PossibleIconExts =
    {".png", ".svgz", ".svg", ".jxl", ".jpg", ".jpeg", ".gif", ".ico", ".xpm"};

// the image extensions that we will actually allow software to have.
inline constexpr std::array<std::string_view, 5> AllowedIconExts = {".png", ".jxl", ".svgz", ".svg", ".xpm"};

// Theme implementation
Theme::Theme(const std::string &name, const std::vector<std::uint8_t> &indexData, const std::string &prefix)
    : m_name(name),
      m_prefix(prefix)
{
    g_autoptr(GKeyFile) index = g_key_file_new();
    g_autoptr(GError) error = nullptr;

    // default prefix if none set
    if (m_prefix.empty())
        m_prefix = "/usr";

    std::string indexText(indexData.begin(), indexData.end());
    if (!g_key_file_load_from_data(index, indexText.c_str(), indexText.length(), G_KEY_FILE_NONE, &error))
        throw std::runtime_error(std::format("Failed to parse theme index for {}: {}", name, error->message));

    gsize groupCount = 0;
    g_auto(GStrv) groups = g_key_file_get_groups(index, &groupCount);
    for (gsize i = 0; i < groupCount; ++i) {
        g_autoptr(GError) tmp_error = nullptr;
        const char *section = groups[i];

        // we ignore symbolic icons
        if (g_str_has_prefix(section, "symbolic/"))
            continue;

        int size = g_key_file_get_integer(index, section, "Size", &tmp_error);
        if (tmp_error)
            continue;

        g_autofree gchar *context = g_key_file_get_string(index, section, "Context", &tmp_error);
        if (tmp_error)
            continue;

        int threshold = g_key_file_get_integer(index, section, "Threshold", &tmp_error);
        if (tmp_error) {
            threshold = 2;
            g_clear_error(&tmp_error);
        }

        g_autofree gchar *type = g_key_file_get_string(index, section, "Type", &tmp_error);
        if (tmp_error) {
            type = g_strdup("Threshold");
            g_clear_error(&tmp_error);
        }

        int minSize = g_key_file_get_integer(index, section, "MinSize", &tmp_error);
        if (tmp_error) {
            minSize = size;
            g_clear_error(&tmp_error);
        }

        int maxSize = g_key_file_get_integer(index, section, "MaxSize", &tmp_error);
        if (tmp_error) {
            maxSize = size;
            g_clear_error(&tmp_error);
        }

        int scale = g_key_file_get_integer(index, section, "Scale", &tmp_error);
        if (tmp_error) {
            scale = 1;
            g_clear_error(&tmp_error);
        }

        if (size == 0)
            continue;

        std::unordered_map<std::string, std::variant<int, std::string>> themedir;
        themedir["path"] = std::string(section);
        themedir["type"] = std::string(type);
        themedir["size"] = size;
        themedir["minsize"] = minSize;
        themedir["maxsize"] = maxSize;
        themedir["threshold"] = threshold;
        themedir["scale"] = scale;

        m_directories.push_back(std::move(themedir));
    }

    // sort our directory list, so the smallest size is at the top
    std::ranges::sort(m_directories, [](const auto &a, const auto &b) {
        return std::get<int>(a.at("size")) < std::get<int>(b.at("size"));
    });
}

Theme::Theme(const std::string &name, std::shared_ptr<Package> pkg, const std::string &prefix)
{
    std::vector<std::uint8_t> indexData;
    if (prefix.empty())
        indexData = pkg->getFileData(std::format("/usr/share/icons/{}/index.theme", name));
    else
        indexData = pkg->getFileData(std::format("{}/share/icons/{}/index.theme", prefix, name));
    *this = Theme(name, indexData, prefix);
}

const std::string &Theme::name() const
{
    return m_name;
}

bool Theme::directoryMatchesSize(
    const std::unordered_map<std::string, std::variant<int, std::string>> &themedir,
    const ImageSize &size,
    bool assumeThresholdScalable) const
{
    const int scale = std::get<int>(themedir.at("scale"));
    if (scale != static_cast<int>(size.scale))
        return false;

    const std::string &type = std::get<std::string>(themedir.at("type"));
    if (type == "Fixed")
        return static_cast<int>(size.toInt()) == std::get<int>(themedir.at("size"));

    if (type == "Scalable") {
        const int minSize = std::get<int>(themedir.at("minsize"));
        const int maxSize = std::get<int>(themedir.at("maxsize"));
        const int sizeInt = static_cast<int>(size.toInt());
        if ((minSize <= sizeInt) && (sizeInt <= maxSize))
            return true;
        return false;
    }

    if (type == "Threshold") {
        const int themeSize = std::get<int>(themedir.at("size"));
        const int th = std::get<int>(themedir.at("threshold"));
        const int sizeInt = static_cast<int>(size.toInt());

        if (assumeThresholdScalable) {
            // we treat this "Threshold" as if we were allowed to downscale its icons if they
            // have a higher size.
            // This can lead to "wrong" scaling, but allows us to retrieve more icons.
            return themeSize >= sizeInt;
        } else {
            // follow the proper algorithm as defined by the XDG spec
            if (((themeSize - th) <= sizeInt) && (sizeInt <= (themeSize + th)))
                return true;
        }

        return false;
    }

    return false;
}

std::generator<std::string> Theme::matchingIconFilenames(
    const std::string &iconName,
    const ImageSize &size,
    bool relaxedScalingRules) const
{
    // extensions to check for
    static const std::array<std::string_view, 4> extensions = {"png", "svgz", "svg", "xpm"};

    for (const auto &themedir : m_directories) {
        if (directoryMatchesSize(themedir, size, relaxedScalingRules)) {
            for (const auto &ext : extensions) {
                co_yield std::format(
                    "{}/share/icons/{}/{}/{}.{}",
                    m_prefix,
                    m_name,
                    std::get<std::string>(themedir.at("path")),
                    iconName,
                    ext);
            }
        }
    }
}

// IconHandler implementation
IconHandler::IconHandler(
    ContentsStore &ccache,
    const fs::path &mediaPath,
    const std::unordered_map<std::string, std::shared_ptr<Package>> &pkgMap,
    const std::string &iconTheme,
    const std::string &extraPrefix)
    : m_mediaExportPath(mediaPath),
      m_iconPolicy(nullptr),
      m_defaultIconSize(64),
      m_defaultIconState(ASC_ICON_STATE_IGNORED),
      m_allowIconUpscaling(false),
      m_allowRemoteIcons(false)
{
    logDebug("Creating new IconHandler");
    auto &conf = Config::get();

    m_iconFiles.clear();

    m_iconPolicy = g_object_ref(conf.iconPolicy());

    // sanity checks
    AscIconPolicyIter policyIter;
    asc_icon_policy_iter_init(&policyIter, m_iconPolicy);

    guint iconSize, iconScale;
    AscIconState iconState;
    while (asc_icon_policy_iter_next(&policyIter, &iconSize, &iconScale, &iconState)) {
        if (iconSize == m_defaultIconSize.width && iconScale == m_defaultIconSize.scale) {
            m_defaultIconState = iconState;
            break;
        }
    }

    if (m_defaultIconState == ASC_ICON_STATE_IGNORED || m_defaultIconState == ASC_ICON_STATE_REMOTE_ONLY)
        throw std::runtime_error(
            "Default icon size '64x64' is set to ignore or remote-only. This is a bug in the generator or "
            "configuration file.");

    // cache a list of enabled icon sizes
    updateEnabledIconSizeList();

    m_allowIconUpscaling = conf.feature.allowIconUpscale;

    // we assume that when screenshot storage is permitted, remote icons are also okay
    // (only then we can actually use the global media_baseurl, if set)
    m_allowRemoteIcons = conf.feature.storeScreenshots && !conf.mediaBaseUrl.empty();

    // Preseeded theme names.
    // * prioritize hicolor, because that's where apps often install their upstream icon
    // * then look at the theme given in the config file
    // * allow Breeze icon theme, needed to support KDE apps (they have no icon at all, otherwise...)
    // * in rare events, GNOME needs the same treatment, so special-case Adwaita as well
    // * We need at least one icon theme to provide the default XDG icon spec stock icons.
    //   A fair take would be to select them between KDE and GNOME at random, but for consistency and
    //   because everyone hates unpredictable behavior, we sort alphabetically and prefer Adwaita over Breeze.
    m_themeNames = {"hicolor"};
    if (!iconTheme.empty())
        m_themeNames.push_back(iconTheme);
    m_themeNames.insert(
        m_themeNames.end(),
        {
            "Adwaita",       // GNOME
            "AdwaitaLegacy", // GNOME
            "breeze"         // KDE
        });

    auto getPackage = [&pkgMap](const std::string &pkid) -> std::shared_ptr<Package> {
        auto it = pkgMap.find(pkid);
        return (it != pkgMap.end()) ? it->second : nullptr;
    };

    // load data from the contents index.
    // we don't show mercy to memory here, we just want the icon lookup to be fast,
    // so we have to cache the data.
    std::unordered_map<std::string, std::unique_ptr<Theme>> tmpThemes;
    std::vector<std::string> pkgKeys;
    pkgKeys.reserve(pkgMap.size());
    for (const auto &[key, _] : pkgMap)
        pkgKeys.push_back(key);

    // Some backends may install icons in paths with a different prefix, and we
    // want to search them in addition to the canonical paths.
    m_extraPrefix = Utils::normalizePath(extraPrefix);
    if (m_extraPrefix == "/usr")
        m_extraPrefix.clear();
    std::string extraPixmapPath;
    std::string extraIconsPath;
    if (!m_extraPrefix.empty()) {
        extraIconsPath = std::format("{}/share/icons/", m_extraPrefix);
        extraPixmapPath = std::format("{}/share/pixmaps/", m_extraPrefix);
    }

    // Process files in parallel, but synchronize theme and icon file access
    std::mutex themesMutex, iconFilesMutex;
    auto filesPkids = ccache.getIconFilesMap(pkgKeys);
    tbb::parallel_for_each(filesPkids.begin(), filesPkids.end(), [&](const auto &info) {
        const std::string &fname = info.first;
        const std::string &pkgid = info.second;

        if (fname.starts_with("/usr/share/pixmaps/")
            || (!m_extraPrefix.empty() && fname.starts_with(extraPixmapPath))) {
            auto pkg = getPackage(pkgid);
            if (pkg) {
                std::lock_guard<std::mutex> lock(iconFilesMutex);
                m_iconFiles[fname] = std::move(pkg);
            }
            return;
        }

        // optimization: check if we actually have an interesting path before
        // entering the slower loop below.
        if (!fname.starts_with("/usr/share/icons/") && (!m_extraPrefix.empty() && !fname.starts_with(extraIconsPath)))
            return;

        auto pkg = getPackage(pkgid);
        if (!pkg)
            return;

        for (const auto &name : m_themeNames) {
            if (fname == std::format("/usr/share/icons/{}/index.theme", name)) {
                std::lock_guard<std::mutex> lock(themesMutex);
                tmpThemes[name] = std::make_unique<Theme>(name, pkg);
            } else if (fname.starts_with(std::format("/usr/share/icons/{}", name))) {
                std::lock_guard<std::mutex> lock(iconFilesMutex);
                m_iconFiles[fname] = pkg;
            } else if (!m_extraPrefix.empty()) {
                if (fname == std::format("{}{}/index.theme", extraIconsPath, name)) {
                    std::lock_guard<std::mutex> lock(themesMutex);
                    tmpThemes[name] = std::make_unique<Theme>(name, pkg, m_extraPrefix);
                } else if (fname.starts_with(extraIconsPath + name)) {
                    std::lock_guard<std::mutex> lock(iconFilesMutex);
                    m_iconFiles[fname] = pkg;
                }
            }
        }
    });

    // when running on partial repos (e.g. PPAs) we might not have a package containing the
    // hicolor theme definition. Since we always need it to be there to properly process icons,
    // we inject our own copy here.
    if (tmpThemes.find("hicolor") == tmpThemes.end()) {
        logInfo("No packaged hicolor icon theme found, using built-in one.");
        auto hicolorThemeIndex = Utils::getDataPath("hicolor-theme-index.theme");
        if (!fs::exists(hicolorThemeIndex)) {
            logError(
                "Hicolor icon theme index at '{}' was not found! We will not be able to handle icons in this theme.",
                hicolorThemeIndex.string());
        } else {
            std::vector<std::uint8_t> indexData;
            std::ifstream f(hicolorThemeIndex, std::ios::binary);
            if (f.is_open()) {
                f.seekg(0, std::ios::end);
                indexData.resize(f.tellg());
                f.seekg(0, std::ios::beg);
                f.read(reinterpret_cast<char *>(indexData.data()), indexData.size());
                tmpThemes["hicolor"] = std::make_unique<Theme>("hicolor", indexData, m_extraPrefix);
            }
        }
    }

    // this is necessary to keep the ordering (and therefore priority) of themes.
    // we don't know the order in which we find index.theme files in the code above,
    // therefore this sorting is necessary.
    for (const auto &tname : m_themeNames) {
        auto it = tmpThemes.find(tname);
        if (it != tmpThemes.end())
            m_themes.push_back(std::move(it->second));
    }

    logDebug("Created new IconHandler.");
}

IconHandler::~IconHandler()
{
    g_object_unref(m_iconPolicy);
}

void IconHandler::updateEnabledIconSizeList()
{
    m_enabledIconSizes.clear();

    AscIconPolicyIter policyIter;
    asc_icon_policy_iter_init(&policyIter, m_iconPolicy);

    guint iconSizeInt, iconScale;
    while (asc_icon_policy_iter_next(&policyIter, &iconSizeInt, &iconScale, nullptr))
        m_enabledIconSizes.emplace_back(iconSizeInt, iconSizeInt, iconScale);
}

std::string IconHandler::getIconNameAndClear(AsComponent *cpt) const
{
    std::string name;

    // a not-processed icon name is stored as "1x1px" icon, so we can
    // quickly identify it here.
    auto icon = Utils::componentGetRawIcon(cpt);
    if (icon.has_value()) {
        if (as_icon_get_kind(icon.value()) == AS_ICON_KIND_LOCAL) {
            const auto filename = as_icon_get_filename(icon.value());
            if (filename)
                name = filename;
        } else {
            const auto iconName = as_icon_get_name(icon.value());
            if (iconName)
                name = iconName;
        }
    }

    // clear the list of icons in this component
    auto iconsArray = as_component_get_icons(cpt);
    if (iconsArray->len > 0)
        g_ptr_array_remove_range(iconsArray, 0, iconsArray->len);

    return name;
}

bool IconHandler::iconAllowed(const std::string &iconName)
{
    return std::ranges::any_of(AllowedIconExts, [&iconName](const auto &ext) {
        return iconName.ends_with(ext);
    });
}

std::generator<std::string> IconHandler::possibleIconFilenames(
    const std::string &iconName,
    const ImageSize &size,
    bool relaxedScalingRules) const
{
    for (const auto &theme : m_themes) {
        for (const auto &fname : theme->matchingIconFilenames(iconName, size, relaxedScalingRules))
            co_yield fname;
    }

    if (size.scale == 1 && size.width == 64) {
        // Check icons root directory for icon files
        // this is "wrong", but we support it for compatibility reasons.
        // However, we only ever use it to satisfy the 64x64px requirement
        for (const auto &extension : PossibleIconExts)
            co_yield std::format("/usr/share/icons/{}{}", iconName, extension);

        // check pixmaps directory for icons
        // we only ever use the pixmap directory contents to satisfy the minimum 64x64px icon
        // requirement. Otherwise we get weird upscaling to higher sizes or HiDPI sizes happening,
        // as later code tries to downscale "bigger" sizes.
        for (const auto &extension : PossibleIconExts)
            co_yield std::format("/usr/share/pixmaps/{}{}", iconName, extension);

        // do the same things for the extra prefix directory, if we have one
        if (!m_extraPrefix.empty()) {
            for (const auto &extension : PossibleIconExts)
                co_yield std::format("{}/share/icons/{}{}", m_extraPrefix, iconName, extension);
            for (const auto &extension : PossibleIconExts)
                co_yield std::format("{}/share/pixmaps/{}{}", m_extraPrefix, iconName, extension);
        }
    }
}

std::unordered_map<ImageSize, IconHandler::IconFindResult> IconHandler::findIcons(
    const std::string &iconName,
    const std::vector<ImageSize> &sizes,
    std::shared_ptr<Package> pkg) const
{
    std::unordered_map<ImageSize, IconFindResult> sizeMap;

    for (const auto &size : sizes) {
        // search for possible icon filenames, using relaxed scaling rules by default
        for (const auto &fname : possibleIconFilenames(iconName, size, true)) {
            if (pkg) {
                // we are supposed to search in one particular package
                const auto &contents = pkg->contents();
                if (std::ranges::find(contents, fname) != contents.end()) {
                    sizeMap[size] = IconFindResult(pkg, fname);
                    break;
                }
            } else {
                // global search in all packages
                auto it = m_iconFiles.find(fname);
                if (it == m_iconFiles.end())
                    continue;

                sizeMap[size] = IconFindResult(it->second, fname);
                break;
            }
        }
    }

    return sizeMap;
}

std::string IconHandler::stripIconExt(const std::string &iconName)
{
    if (iconName.ends_with(".png"))
        return iconName.substr(0, iconName.length() - 4);
    if (iconName.ends_with(".svg"))
        return iconName.substr(0, iconName.length() - 4);
    if (iconName.ends_with(".xpm"))
        return iconName.substr(0, iconName.length() - 4);
    if (iconName.ends_with(".svgz"))
        return iconName.substr(0, iconName.length() - 5);
    return iconName;
}

bool IconHandler::storeIcon(
    AsComponent *cpt,
    GeneratorResult &gres,
    const fs::path &cptExportPath,
    std::shared_ptr<Package> sourcePkg,
    const std::string &iconPath,
    const ImageSize &size,
    AscIconState targetState) const
{
    auto iformat = asc_image_format_from_filename(iconPath.c_str());
    if (iformat == ASC_IMAGE_FORMAT_UNKNOWN) {
        gres.addHint(
            as_component_get_id(cpt),
            "icon-format-unsupported",
            {
                {"icon_fname", fs::path(iconPath).filename()}
        });
        return false;
    }

    auto path = cptExportPath / "icons" / size.toString();
    auto iconName = (gres.getPackage()->kind() == PackageKind::Fake)
                        ? fs::path(iconPath).filename().string()
                        : std::format("{}_{}", gres.getPackage()->name(), fs::path(iconPath).filename().string());

    if (iconName.ends_with(".svgz"))
        iconName = iconName.substr(0, iconName.length() - 5) + ".png";
    else if (iconName.ends_with(".svg"))
        iconName = iconName.substr(0, iconName.length() - 4) + ".png";
    else if (iconName.ends_with(".xpm"))
        iconName = iconName.substr(0, iconName.length() - 4) + ".png";

    auto iconStoreLocation = path / iconName;
    if (fs::exists(iconStoreLocation)) {
        // we already extracted that icon, skip the extraction step
        // and just add the new icon.
        if (targetState != ASC_ICON_STATE_REMOTE_ONLY) {
            g_autoptr(AsIcon) icon = as_icon_new();
            as_icon_set_kind(icon, AS_ICON_KIND_CACHED);
            as_icon_set_width(icon, size.width);
            as_icon_set_height(icon, size.height);
            as_icon_set_scale(icon, size.scale);
            as_icon_set_name(icon, iconName.c_str());
            as_component_add_icon(cpt, icon);
        }
        if (targetState != ASC_ICON_STATE_CACHED_ONLY && m_allowRemoteIcons) {
            auto gcid = gres.gcidForComponent(cpt);
            if (gcid.empty()) {
                gres.addHint(
                    cpt, "internal-error", "No global ID could be found for the component, could not add remote icon.");
                return true;
            }
            auto remoteIconUrl = fs::path(gcid) / "icons" / size.toString() / iconName;

            g_autoptr(AsIcon) icon = as_icon_new();
            as_icon_set_kind(icon, AS_ICON_KIND_REMOTE);
            as_icon_set_width(icon, size.width);
            as_icon_set_height(icon, size.height);
            as_icon_set_scale(icon, size.scale);
            as_icon_set_url(icon, remoteIconUrl.string().c_str());
            as_component_add_icon(cpt, icon);
        }

        return true;
    }

    // filepath is checked because icon can reside in another binary
    // eg amarok's icon is in amarok-data
    std::vector<std::uint8_t> iconData;
    try {
        iconData = sourcePkg->getFileData(iconPath);
    } catch (const std::exception &e) {
        gres.addHint(
            as_component_get_id(cpt),
            "pkg-extract-error",
            {
                {"fname",     fs::path(iconPath).filename()                },
                {"pkg_fname", fs::path(sourcePkg->getFilename()).filename()},
                {"error",     e.what()                                     }
        });
        return false;
    }

    if (iconData.empty()) {
        gres.addHint(
            as_component_get_id(cpt),
            "pkg-empty-file",
            {
                {"fname",     fs::path(iconPath).filename()                },
                {"pkg_fname", fs::path(sourcePkg->getFilename()).filename()}
        });
        return false;
    }

    auto scaled_width = (int)size.width * (int)size.scale;
    auto scaled_height = (int)size.height * (int)size.scale;

    if ((iformat == ASC_IMAGE_FORMAT_SVG) || (iformat == ASC_IMAGE_FORMAT_SVGZ)) {
        // create target directory
        fs::create_directories(path);

        g_autoptr(GError) error = nullptr;
        g_autoptr(GInputStream) stream = g_memory_input_stream_new_from_data(iconData.data(), iconData.size(), nullptr);
        gboolean ret = asc_render_svg_to_file(
            G_INPUT_STREAM(stream),
            (gint)scaled_width,
            (gint)scaled_height,
            ASC_IMAGE_FORMAT_PNG,
            iconStoreLocation.c_str(),
            &error);

        if (!ret) {
            gres.addHint(
                as_component_get_id(cpt),
                "image-write-error",
                {
                    {"fname",     fs::path(iconPath).filename()                },
                    {"pkg_fname", fs::path(sourcePkg->getFilename()).filename()},
                    {"error",     error->message                               }
            });
            return false;
        }
    } else {
        g_autoptr(GError) error = nullptr;
        g_autoptr(AscImage) img = asc_image_new_from_data(
            iconData.data(),
            iconData.size(),
            -1,
            -1,
            ASC_IMAGE_LOAD_FLAG_NONE,
            iconPath.ends_with(".svgz") ? ASC_IMAGE_FORMAT_SVGZ : ASC_IMAGE_FORMAT_UNKNOWN,
            &error);

        if (!img) {
            gres.addHint(
                as_component_get_id(cpt),
                "image-write-error",
                {
                    {"fname",     fs::path(iconPath).filename()                },
                    {"pkg_fname", fs::path(sourcePkg->getFilename()).filename()},
                    {"error",     error->message                               }
            });
            return false;
        }

        if (iformat == ASC_IMAGE_FORMAT_XPM) {
            // we use XPM images only if they are large enough
            if (m_allowIconUpscaling) {
                // we only try upscaling for the default 64x64px size and only if
                // the icon is not too small
                if (size != ImageSize(64))
                    return false;

                if ((asc_image_get_width(img) < 48) || (asc_image_get_height(img) < 48))
                    return false;
            } else {
                if ((asc_image_get_width(img) < scaled_width) || (asc_image_get_height(img) < scaled_height))
                    return false;
            }
        }

        // ensure that we don't try to make an application visible that has a really tiny icon
        // by upscaling it to a blurry mess
        if (size.scale == 1 && size.width == 64) {
            if ((asc_image_get_width(img) < 48) || (asc_image_get_height(img) < 48)) {
                gres.addHint(
                    cpt,
                    "icon-too-small",
                    {
                        {"icon_name", iconName},
                        {"icon_size", std::format("{}x{}", asc_image_get_width(img), asc_image_get_height(img))}
                });
                return false;
            }
        }

        // warn about icon upscaling, it looks ugly
        if (scaled_width > asc_image_get_width(img)) {
            gres.addHint(
                cpt,
                "icon-scaled-up",
                {
                    {"icon_name", iconName},
                    {"icon_size", std::format("{}x{}", asc_image_get_width(img), asc_image_get_height(img))},
                    {"scale_size", size.toString()}
            });
        }

        // create target directory
        fs::create_directories(path);

        asc_image_scale(img, scaled_width, scaled_height);
        asc_image_save_filename(img, iconStoreLocation.c_str(), 0, 0, ASC_IMAGE_SAVE_FLAG_OPTIMIZE, &error);
        if (error) {
            gres.addHint(
                cpt,
                "image-write-error",
                {
                    {"fname",     fs::path(iconPath).filename()                },
                    {"pkg_fname", fs::path(sourcePkg->getFilename()).filename()},
                    {"error",     error->message                               }
            });
            return false;
        }
    }

    if (targetState != ASC_ICON_STATE_REMOTE_ONLY) {
        g_autoptr(AsIcon) icon = as_icon_new();
        as_icon_set_kind(icon, AS_ICON_KIND_CACHED);
        as_icon_set_width(icon, size.width);
        as_icon_set_height(icon, size.height);
        as_icon_set_scale(icon, size.scale);
        as_icon_set_name(icon, iconName.c_str());
        as_component_add_icon(cpt, icon);
    }
    if (targetState != ASC_ICON_STATE_CACHED_ONLY && m_allowRemoteIcons) {
        auto gcid = gres.gcidForComponent(cpt);
        if (gcid.empty()) {
            gres.addHint(
                cpt, "internal-error", "No global ID could be found for the component, could not add remote icon.");
            return true;
        }
        auto remoteIconUrl = fs::path(gcid) / "icons" / size.toString() / iconName;

        g_autoptr(AsIcon) icon = as_icon_new();
        as_icon_set_kind(icon, AS_ICON_KIND_REMOTE);
        as_icon_set_width(icon, size.width);
        as_icon_set_height(icon, size.height);
        as_icon_set_scale(icon, size.scale);
        as_icon_set_url(icon, remoteIconUrl.string().c_str());
        as_component_add_icon(cpt, icon);
    }

    return true;
}

IconHandler::IconFindResult IconHandler::findIconScalableToSize(
    const std::unordered_map<ImageSize, IconFindResult> &possibleIcons,
    const ImageSize &size) const
{
    IconFindResult info;

    // on principle, never attempt to up- or downscale an icon to something below
    // AppStream's default icon size.
    // The clients can do that just as well, without us wasting disk space
    // and network bandwidth.
    if (size.scale == 1 && size.width < 64)
        return info;

    // the size we want wasn't found, can we downscale a larger one?
    for (const auto &[asize, data] : possibleIcons) {
        if (asize.scale != size.scale)
            continue;
        if (asize < size)
            continue;
        info = data;
        break;
    }

    if (!info.pkg && m_allowIconUpscaling && (size == m_defaultIconSize)) {
        // no icon was found to downscale, but we allow upscaling, so try one last time
        // to find a suitable icon for at least the default AppStream icon size.
        for (const auto &[asize, data] : possibleIcons) {
            // we never allow icons smaller than 48x48px
            if (asize.width < 48)
                continue;
            if (asize.scale != size.scale)
                continue;
            info = data;
            break;
        }
    }

    return info;
}

bool IconHandler::process(GeneratorResult &gres, AsComponent *cpt)
{
    std::lock_guard<std::mutex> lock(m_mutex);

    // we don't touch fonts unless those didn't have their icon
    // rendered from the font itself already
    if (as_component_get_kind(cpt) == AS_COMPONENT_KIND_FONT) {
        auto iconsArr = as_component_get_icons(cpt);
        for (guint i = 0; i < iconsArr->len; i++) {
            auto icon = AS_ICON(g_ptr_array_index(iconsArr, i));
            // nothing to do for us if cached and remote icons are already there
            if (as_icon_get_kind(icon) == AS_ICON_KIND_CACHED || as_icon_get_kind(icon) == AS_ICON_KIND_REMOTE)
                return true;
        }
    }

    auto iconName = getIconNameAndClear(cpt);
    // nothing to do if there is no icon
    if (iconName.empty())
        return true;

    auto gcid = gres.gcidForComponent(cpt);
    if (gcid.empty()) {
        const char *cid = as_component_get_id(cpt);
        if (!cid)
            cid = "general";
        gres.addHint(cid, "internal-error", "No global ID could be found for the component.");
        return false;
    }

    auto cptMediaPath = m_mediaExportPath / gcid;

    if (iconName.starts_with("/")) {
        logDebug("Looking for icon '{}' for '{}::{}' (path)", iconName, gres.pkid(), as_component_get_id(cpt));

        const auto &contents = gres.getPackage()->contents();
        if (std::ranges::find(contents, iconName) != contents.end()) {
            return storeIcon(
                cpt, gres, cptMediaPath, gres.getPackage(), iconName, m_defaultIconSize, m_defaultIconState);
        }

        // we couldn't find the absolute icon path
        gres.addHint(
            as_component_get_id(cpt),
            "icon-not-found",
            {
                {"icon_fname", iconName}
        });
        return false;
    } else {
        logDebug("Looking for icon '{}' for '{}::{}' (XDG)", iconName, gres.pkid(), as_component_get_id(cpt));

        iconName = fs::path(iconName).filename();

        // Small hack: Strip .png and other extensions from icon files to make the XDG and Pixmap finder
        // work properly, which add their own icon extensions and find the most suitable icon.
        // The icon name should not have an extension anyway, but some apps ignore the desktop-entry spec...
        iconName = stripIconExt(iconName);

        std::string lastIconName;

        /// Search for an icon in XDG icon directories.
        /// Returns true on success and sets lastIconName to the
        /// last icon name that has been handled.
        auto findAndStoreXdgIcon = [&](std::shared_ptr<Package> epkg = nullptr) -> bool {
            auto iconRes = findIcons(iconName, m_enabledIconSizes, std::move(epkg));
            if (iconRes.empty())
                return false;

            std::unordered_map<ImageSize, IconHandler::IconFindResult> iconsStored;

            AscIconPolicyIter policyIter;
            asc_icon_policy_iter_init(&policyIter, m_iconPolicy);

            guint iconSizeInt, iconScale;
            AscIconState iconState;
            while (asc_icon_policy_iter_next(&policyIter, &iconSizeInt, &iconScale, &iconState)) {
                const ImageSize size(iconSizeInt, iconSizeInt, iconScale);
                auto infoIt = iconRes.find(size);

                IconFindResult info;
                if (infoIt == iconRes.end())
                    info.pkg = nullptr;
                else
                    info = infoIt->second;

                // check if we can scale another size to the desired one
                if (!info.pkg)
                    info = findIconScalableToSize(iconRes, size);

                // give up if we still haven't found an icon (in which case `info.pkg` would be set)
                if (!info.pkg)
                    continue;

                lastIconName = info.fname;
                if (iconAllowed(lastIconName)) {
                    if (storeIcon(cpt, gres, cptMediaPath, info.pkg, lastIconName, size, iconState))
                        iconsStored[size] = std::move(info);
                } else {
                    // the found icon is not suitable, but maybe we can scale a differently sized icon to the right one?
                    info = findIconScalableToSize(iconRes, size);
                    if (!info.pkg)
                        continue;

                    if (iconAllowed(info.fname)) {
                        if (storeIcon(cpt, gres, cptMediaPath, info.pkg, lastIconName, size, iconState))
                            iconsStored[size] = info;
                        lastIconName = info.fname;
                    }
                }

                if (gres.isIgnored(cpt)) {
                    // running storeIcon() in this loop may lead to rejection
                    // of this component, in case icons can't be saved.
                    // we just give up in that case.
                    return false;
                }
            }

            // ensure we have stored a 64x64px icon, since this is mandated
            // by the AppStream spec by downscaling a larger icon that we
            // might have found.
            if (iconsStored.find(ImageSize(64)) != iconsStored.end()) {
                logDebug("Found icon {} - {} in XDG directories, 64x64px size is present", gres.pkid(), iconName);
                return true;
            } else {
                for (const auto &size : m_enabledIconSizes) {
                    auto it = iconsStored.find(size);
                    if (it == iconsStored.end())
                        continue;
                    if (size < ImageSize(64))
                        continue;
                    logInfo(
                        "Downscaling icon {} - {} from {} to {}",
                        gres.pkid(),
                        iconName,
                        size.toString(),
                        m_defaultIconSize.toString());
                    const auto &info = it->second;
                    lastIconName = info.fname;
                    if (storeIcon(
                            cpt, gres, cptMediaPath, info.pkg, lastIconName, m_defaultIconSize, m_defaultIconState)) {
                        return true;
                    }
                }
            }

            // if we are here, we either didn't find an icon, or no icon is present
            // in the default 64x64px size
            return false;
        };

        // search for the right icon inside the current package
        auto success = findAndStoreXdgIcon(gres.getPackage());
        if (!success && !gres.isIgnored(cpt)) {
            // search in all packages
            success = findAndStoreXdgIcon();
        }

        if (success) {
            logDebug("Icon {} - {} found in XDG dirs", gres.pkid(), iconName);

            // we found a valid stock icon, so set that additionally to the cached one
            g_autoptr(AsIcon) icon = as_icon_new();
            as_icon_set_kind(icon, AS_ICON_KIND_STOCK);
            as_icon_set_name(icon, iconName.c_str());
            as_component_add_icon(cpt, icon);

            return true;
        } else {
            logDebug("Icon {} - {} not found in required size(s) in XDG dirs", gres.pkid(), iconName);

            if (!lastIconName.empty() && !iconAllowed(lastIconName)) {
                gres.addHint(
                    as_component_get_id(cpt),
                    "icon-format-unsupported",
                    {
                        {"icon_fname", fs::path(lastIconName).filename()}
                });
                return false;
            }

            gres.addHint(
                as_component_get_id(cpt),
                "icon-not-found",
                {
                    {"icon_fname", iconName}
            });
            return false;
        }
    }
}

} // namespace ASGenerator
