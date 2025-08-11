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

#include "dataunits.h"

#include <string>
#include <memory>
#include <unordered_map>
#include <vector>
#include <mutex>
#include <shared_mutex>

#include "backends/interfaces.h"
#include "contentsstore.h"
#include "logging.h"
#include "config.h"

using namespace ASGenerator;

/* AsgPackageUnit implementation */

/**
 * AsgPackageUnit - A unit representing a single package
 */
struct _AsgPackageUnit {
    AscUnit parent_instance;

    /* Private data stored as C++ objects */
    gpointer priv_data;
};

namespace
{

/**
 * Private data structure for AsgPackageUnit
 */
class PackageUnitPrivate
{
public:
    std::shared_ptr<Package> package;
    mutable std::shared_mutex mutex;
    bool contents_loaded = false;

    explicit PackageUnitPrivate(std::shared_ptr<Package> pkg)
        : package(pkg)
    {
    }
};

} // anonymous namespace

G_DEFINE_TYPE(AsgPackageUnit, asg_package_unit, ASC_TYPE_UNIT)

/**
 * asg_package_unit_new:
 * @pkg: Package to wrap (ownership is transferred)
 *
 * Create a new package unit for a given package.
 */
AsgPackageUnit *asg_package_unit_new(std::shared_ptr<Package> pkg)
{
    AsgPackageUnit *unit = static_cast<AsgPackageUnit *>(g_object_new(ASG_TYPE_PACKAGE_UNIT, nullptr));

    try {
        unit->priv_data = new PackageUnitPrivate(pkg);

        // set identity
        asc_unit_set_bundle_id(ASC_UNIT(unit), pkg->name().c_str());
        asc_unit_set_bundle_kind(ASC_UNIT(unit), AS_BUNDLE_KIND_PACKAGE);

    } catch (const std::exception &e) {
        logError("Failed to create package unit: {}", e.what());
        g_object_unref(unit);
        return nullptr;
    }

    return unit;
}

static gboolean asg_package_unit_open_impl(AscUnit *unit, GError **error)
{
    AsgPackageUnit *pkg_unit = ASG_PACKAGE_UNIT(unit);
    auto *priv = static_cast<PackageUnitPrivate *>(pkg_unit->priv_data);

    if (!priv || !priv->package) {
        g_set_error(error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "No package associated with this unit.");
        return FALSE;
    }

    std::unique_lock<std::shared_mutex> lock(priv->mutex);

    try {
        // Load package contents
        const auto &contents = priv->package->contents();

        // Set contents in the parent AscUnit
        g_autoptr(GPtrArray) contents_array = g_ptr_array_new_with_free_func(g_free);
        for (const auto &filename : contents)
            g_ptr_array_add(contents_array, g_strdup(filename.c_str()));
        asc_unit_set_contents(unit, contents_array);

        priv->contents_loaded = true;
        return TRUE;

    } catch (const std::exception &e) {
        logError("Failed to open package unit: {}", e.what());
        g_set_error(error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "Failed to open package unit: %s", e.what());
        return FALSE;
    }
}

static void asg_package_unit_close_impl(AscUnit *unit)
{
    AsgPackageUnit *pkg_unit = ASG_PACKAGE_UNIT(unit);
    auto *priv = static_cast<PackageUnitPrivate *>(pkg_unit->priv_data);

    if (priv->package)
        priv->package->finish();
}

static gboolean asg_package_unit_dir_exists_impl(AscUnit *unit, const gchar *dirname)
{
    AsgPackageUnit *pkg_unit = ASG_PACKAGE_UNIT(unit);
    auto *priv = static_cast<PackageUnitPrivate *>(pkg_unit->priv_data);

    if (!priv || !priv->package) {
        g_warning("No package associated with this unit.");
        return FALSE;
    }

    std::shared_lock<std::shared_mutex> lock(priv->mutex);

    if (!priv->contents_loaded) {
        g_warning("Package contents not loaded yet.");
        return FALSE;
    }

    const std::string dirpath(dirname);
    const std::string dirpath_slash = dirpath + "/";

    for (const auto &file : priv->package->contents()) {
        if (file.starts_with(dirpath_slash))
            return TRUE;
    }

    return FALSE;
}

static GBytes *asg_package_unit_read_data_impl(AscUnit *unit, const gchar *filename, GError **error)
{
    AsgPackageUnit *pkg_unit = ASG_PACKAGE_UNIT(unit);
    auto *priv = static_cast<PackageUnitPrivate *>(pkg_unit->priv_data);

    if (!priv || !priv->package) {
        g_set_error(error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "No package associated with this unit.");
        return nullptr;
    }

    std::shared_lock<std::shared_mutex> lock(priv->mutex);

    try {
        const std::string fname(filename);
        auto data = priv->package->getFileData(fname);

        if (data.empty()) {
            g_set_error(
                error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "File '%s' does not exist or is empty.", filename);
            return nullptr;
        }

        // Create a copy of the data for GBytes
        void *data_copy = g_memdup2(data.data(), data.size());
        return g_bytes_new_take(data_copy, data.size());

    } catch (const std::exception &e) {
        logError("Failed to read data from package unit: {}", e.what());
        g_set_error(error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "Failed to read data: %s", e.what());
        return nullptr;
    }
}

static void asg_package_unit_finalize(GObject *object)
{
    AsgPackageUnit *pkg_unit = ASG_PACKAGE_UNIT(object);

    if (pkg_unit->priv_data) {
        auto *priv = static_cast<PackageUnitPrivate *>(pkg_unit->priv_data);
        delete priv;
        pkg_unit->priv_data = nullptr;
    }

    G_OBJECT_CLASS(asg_package_unit_parent_class)->finalize(object);
}

static void asg_package_unit_class_init(AsgPackageUnitClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS(klass);
    AscUnitClass *unit_class = ASC_UNIT_CLASS(klass);

    object_class->finalize = asg_package_unit_finalize;

    unit_class->open = asg_package_unit_open_impl;
    unit_class->close = asg_package_unit_close_impl;
    unit_class->dir_exists = asg_package_unit_dir_exists_impl;
    unit_class->read_data = asg_package_unit_read_data_impl;
}

static void asg_package_unit_init(AsgPackageUnit *pkg_unit)
{
    pkg_unit->priv_data = nullptr;
}

/* AsgLocaleUnit implementation */

/**
 * AsgLocaleUnit - A unit for handling locale-specific files across multiple packages
 */
struct _AsgLocaleUnit {
    AscUnit parent_instance;

    /* Private data stored as C++ objects */
    gpointer priv_data;
};

namespace
{
/**
 * Private data structure for AsgLocaleUnit
 */
class LocaleUnitPrivate
{
public:
    std::shared_ptr<ContentsStore> contents_store;
    std::vector<std::shared_ptr<Package>> package_list;
    std::unordered_map<std::string, Package *> locale_file_pkg_map;
    mutable std::shared_mutex mutex;

    explicit LocaleUnitPrivate(std::shared_ptr<ContentsStore> cstore, const std::vector<std::shared_ptr<Package>> &pkgs)
        : contents_store(cstore)
    {
        package_list = pkgs;

        // Check if locale processing is enabled
        const auto &conf = Config::get();
        if (!conf.feature.processLocale) {
            // Don't load the expensive locale<->package mapping if we don't need it
            return;
        }

        // Convert the list into a map for faster lookups (like the D code)
        std::unordered_map<std::string, Package *> pkgMap;
        for (const auto &pkg : package_list) {
            const std::string pkid = pkg->id();
            pkgMap[pkid] = pkg.get();
        }

        // Get package IDs for the contents store lookup
        std::vector<std::string> pkids;
        pkids.reserve(pkgMap.size());
        for (const auto &[pkid, pkg] : pkgMap)
            pkids.push_back(pkid);

        // We make the assumption here that all locale for a given domain are in one package.
        // Otherwise this global search will get even more insane.
        // The key of the map returned by getLocaleMap will therefore contain only the locale
        // file basename instead of a full path
        auto dbLocaleMap = contents_store->getLocaleMap(pkids);

        for (const auto &[id, pkgid] : dbLocaleMap) {
            // Check if we already have a package - lookups in this HashMap are faster
            // due to its smaller size and (most of the time) outweigh the following additional
            // lookup for the right package entity.
            if (locale_file_pkg_map.find(id) != locale_file_pkg_map.end())
                continue;

            Package *pkg = nullptr;
            if (!pkgid.empty()) {
                auto pkgIt = pkgMap.find(pkgid);
                if (pkgIt != pkgMap.end()) {
                    pkg = pkgIt->second;
                }
            }

            if (pkg != nullptr)
                locale_file_pkg_map[id] = pkg;
        }
    }
};
} // anonymous namespace

G_DEFINE_TYPE(AsgLocaleUnit, asg_locale_unit, ASC_TYPE_UNIT)

/**
 * asg_locale_unit_new:
 * @contents_store: ContentsStore instance (ownership is transferred)
 * @package_list: Package list (ownership is transferred)
 *
 * Create a new locale unit with contents store and package list.
 */
AsgLocaleUnit *asg_locale_unit_new(std::shared_ptr<ContentsStore> cstore, std::vector<std::shared_ptr<Package>> pkgList)
{
    AsgLocaleUnit *unit = static_cast<AsgLocaleUnit *>(g_object_new(ASG_TYPE_LOCALE_UNIT, nullptr));

    try {
        unit->priv_data = new LocaleUnitPrivate(cstore, pkgList);

        // Set bundle information for locale unit
        asc_unit_set_bundle_id(ASC_UNIT(unit), "locale-data");
        asc_unit_set_bundle_kind(ASC_UNIT(unit), AS_BUNDLE_KIND_UNKNOWN);

    } catch (const std::exception &e) {
        logError("Failed to create locale unit: {}", e.what());
        g_object_unref(unit);
        return nullptr;
    }

    return unit;
}

static gboolean asg_locale_unit_open_impl(AscUnit *unit, GError **error)
{
    AsgLocaleUnit *locale_unit = ASG_LOCALE_UNIT(unit);
    auto *priv = static_cast<LocaleUnitPrivate *>(locale_unit->priv_data);

    if (!priv) {
        g_set_error(error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "No locale mapping associated with this unit.");
        return FALSE;
    }

    std::shared_lock<std::shared_mutex> lock(priv->mutex);

    try {
        // Set up contents list from the file mapping keys
        g_autoptr(GPtrArray) contents_array = g_ptr_array_new_with_free_func(g_free);

        for (const auto &[filename, pkg] : priv->locale_file_pkg_map)
            g_ptr_array_add(contents_array, g_strdup(filename.c_str()));

        asc_unit_set_contents(unit, contents_array);
        return TRUE;

    } catch (const std::exception &e) {
        logError("Failed to open locale unit: {}", e.what());
        g_set_error(error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "Failed to open locale unit: %s", e.what());
        return FALSE;
    }
}

static void asg_locale_unit_close_impl(AscUnit *unit)
{
    // noop - locale units don't need explicit closing
}

static gboolean asg_locale_unit_dir_exists_impl(AscUnit *unit, const gchar *dirname)
{
    // not implemented yet, as it's not needed for locale finding (yet?)
    return FALSE;
}

static GBytes *asg_locale_unit_read_data_impl(AscUnit *unit, const gchar *filename, GError **error)
{
    AsgLocaleUnit *locale_unit = ASG_LOCALE_UNIT(unit);
    auto *priv = static_cast<LocaleUnitPrivate *>(locale_unit->priv_data);

    if (!priv) {
        g_set_error(error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "No locale mapping associated with this unit.");
        return nullptr;
    }

    std::shared_lock<std::shared_mutex> lock(priv->mutex);

    try {
        const std::string fname(filename);

        auto it = priv->locale_file_pkg_map.find(fname);
        if (it == priv->locale_file_pkg_map.end()) {
            g_set_error(
                error,
                ASC_COMPOSE_ERROR,
                ASC_COMPOSE_ERROR_FAILED,
                "File '%s' does not exist in a known package!",
                filename);
            return nullptr;
        }

        Package *pkg = it->second;
        if (!pkg) {
            g_set_error(error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "Package for file '%s' is null!", filename);
            return nullptr;
        }

        auto data = pkg->getFileData(fname);

        if (data.empty()) {
            g_set_error(
                error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "File '%s' does not exist or is empty.", filename);
            return nullptr;
        }

        // Create a copy of the data for GBytes
        void *data_copy = g_memdup2(data.data(), data.size());
        return g_bytes_new_take(data_copy, data.size());

    } catch (const std::exception &e) {
        logError("Failed to read data from locale unit: {}", e.what());
        g_set_error(error, ASC_COMPOSE_ERROR, ASC_COMPOSE_ERROR_FAILED, "Failed to read data: %s", e.what());
        return nullptr;
    }
}

static void asg_locale_unit_finalize(GObject *object)
{
    AsgLocaleUnit *locale_unit = ASG_LOCALE_UNIT(object);

    if (locale_unit->priv_data) {
        auto *priv = static_cast<LocaleUnitPrivate *>(locale_unit->priv_data);
        delete priv;
        locale_unit->priv_data = nullptr;
    }

    G_OBJECT_CLASS(asg_locale_unit_parent_class)->finalize(object);
}

static void asg_locale_unit_class_init(AsgLocaleUnitClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS(klass);
    AscUnitClass *unit_class = ASC_UNIT_CLASS(klass);

    object_class->finalize = asg_locale_unit_finalize;

    unit_class->open = asg_locale_unit_open_impl;
    unit_class->close = asg_locale_unit_close_impl;
    unit_class->dir_exists = asg_locale_unit_dir_exists_impl;
    unit_class->read_data = asg_locale_unit_read_data_impl;
}

static void asg_locale_unit_init(AsgLocaleUnit *locale_unit)
{
    locale_unit->priv_data = nullptr;
}
