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
#include <optional>
#include <memory>
#include <cstdint>
#include <glib.h>

namespace ASGenerator
{

class DataStore;

class GStreamer
{
private:
    std::vector<std::string> m_decoders;
    std::vector<std::string> m_encoders;
    std::vector<std::string> m_elements;
    std::vector<std::string> m_uriSinks;
    std::vector<std::string> m_uriSources;

public:
    GStreamer();

    GStreamer(
        const std::vector<std::string> &decoders,
        const std::vector<std::string> &encoders,
        const std::vector<std::string> &elements,
        const std::vector<std::string> &uriSinks,
        const std::vector<std::string> &uriSources);

    bool isNotEmpty() const noexcept;

    const std::vector<std::string> &decoders() const noexcept
    {
        return m_decoders;
    }
    const std::vector<std::string> &encoders() const noexcept
    {
        return m_encoders;
    }
    const std::vector<std::string> &elements() const noexcept
    {
        return m_elements;
    }
    const std::vector<std::string> &uriSinks() const noexcept
    {
        return m_uriSinks;
    }
    const std::vector<std::string> &uriSources() const noexcept
    {
        return m_uriSources;
    }
};

/**
 * Type of a package that can be processed.
 * Allows distinguishing "real" packages from
 * virtual or fake ones that are used internally.
 */
enum class PackageKind {
    Unknown,
    Physical,
    Fake
};

/**
 * Represents a distribution package in the generator.
 */
class Package
{
private:
    mutable std::string m_pkid;

public:
    virtual ~Package() = default;

    virtual std::string name() const = 0;
    virtual std::string ver() const = 0;
    virtual std::string arch() const = 0;
    virtual std::string maintainer() const = 0;

    /**
     * Type of this package (whether it actually exists or is a fake/virtual package)
     * You pretty much always want PHYSICAL.
     */
    virtual PackageKind kind() const noexcept
    {
        return PackageKind::Physical;
    }

    /**
     * A associative array containing package descriptions.
     * Key is the language (or locale), value the description.
     *
     * E.g.: {"en": "A description.", "de": "Eine Beschreibung"}
     */
    virtual const std::unordered_map<std::string, std::string> &description() const = 0;

    /**
     * A associative array containing package summaries.
     * Key is the language (or locale), value the summary.
     *
     * E.g.: {"en": "foo the bar"}
     */
    virtual const std::unordered_map<std::string, std::string> &summary() const
    {
        static const std::unordered_map<std::string, std::string> empty_map;
        return empty_map;
    }

    /**
     * Local filename of the package. This string is only used for
     * issue reporting and other information, the file is never
     * accessed directly (all data is retrieved via getFileData()).
     *
     * This function should return a local filepath, backends might
     * download missing packages on-demand from a web location.
     */
    virtual std::string getFilename() = 0;

    /**
     * A list payload files this package contains.
     */
    virtual const std::vector<std::string> &contents() = 0;

    /**
     * Obtain data for a specific file in the package.
     */
    virtual std::vector<std::uint8_t> getFileData(const std::string &fname) = 0;

    /**
     * Remove temporary data that might have been created while loading information from
     * this package. This function can be called to avoid excessive use of disk space.
     * As opposed to `finish()`, the package may be reopened afterwards.
     */
    virtual void cleanupTemp() {}

    /**
     * Close the package. This function is called when we will
     * no longer request any file data from this package.
     */
    virtual void finish() = 0;

    virtual std::optional<GStreamer> gst() const
    {
        return std::nullopt;
    }

    /**
     * Retrieve backend-specific translations.
     *
     * (currently only used by the Ubuntu backend)
     */
    virtual std::unordered_map<std::string, std::string> getDesktopFileTranslations(
        const GKeyFile *desktopFile,
        const std::string &text)
    {
        return {};
    }

    virtual bool hasDesktopFileTranslations() const
    {
        return false;
    }

    /**
     * Get the unique identifier for this package.
     * The ID is supposed to be unique per backend, it should never appear
     * multiple times in suites/sections.
     */
    const std::string &id() const;

    /**
     * Check if the package is valid.
     * A Package must at least have a name, version and architecture defined.
     */
    bool isValid() const;

    std::string toString() const;

    // Delete copy constructor and assignment operator
    Package(const Package &) = delete;
    Package &operator=(const Package &) = delete;

protected:
    Package() = default;
};

/**
 * An index of information about packages in a distribution.
 */
class PackageIndex
{
public:
    virtual ~PackageIndex() = default;

    /**
     * Called after a set of operations has completed, which allows the index to
     * release memory it might have allocated for cached data, or delete temporary
     * files.
     **/
    virtual void release() = 0;

    /**
     * Get a list of packages for the given suite/section/arch triplet.
     * The PackageIndex should cache the data if obtaining it is an expensive
     * operation, since the generator might query the data multiple times.
     **/
    virtual std::vector<std::shared_ptr<Package>> packagesFor(
        const std::string &suite,
        const std::string &section,
        const std::string &arch,
        bool withLongDescs = true) = 0;

    /**
     * Get an abstract package representation for a physical package
     * file. A suite name and section name is obviously given.
     * This function is used in case only processing of one particular
     * package is requested.
     * Backends should return null if the feature is not implemented.
     **/
    virtual std::shared_ptr<Package> packageForFile(
        const std::string &fname,
        const std::string &suite = "",
        const std::string &section = "") = 0;

    /**
     * Check if the index for the given suite/section/arch triplet has changed since
     * the last generator run. The index can use the (get/set)RepoInfo methods on DataStore
     * to store mtime or checksum data for the given suite.
     * For the lifetime of the PackageIndex, this method must return the same result,
     * which means an internal cache is useful.
     */
    virtual bool hasChanges(
        std::shared_ptr<DataStore> dstore,
        const std::string &suite,
        const std::string &section,
        const std::string &arch) = 0;

    // Delete copy constructor and assignment operator
    PackageIndex(const PackageIndex &) = delete;
    PackageIndex &operator=(const PackageIndex &) = delete;

protected:
    PackageIndex() = default;
};

} // namespace ASGenerator
