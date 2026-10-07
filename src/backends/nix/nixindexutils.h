/*
 * Copyright (C) 2026 Victor Fuentes <vlinkz@snowflakeos.org>
 *
 * Based on the archlinux and alpinelinux backends, which are:
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
 * Copyright (C) 2020-2025 Rasmus Thomsen <oss@cogitri.dev>
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
#include <set>
#include <unordered_map>
#include <cstdint>
#include <nlohmann/json.hpp>

namespace ASGenerator
{

/**
 * Find the nix executable in the system PATH.
 * @return The path to the nix executable, or an empty string if not found.
 */
std::string findNixExecutable();

/**
 * Find the nix-env executable in the system PATH.
 * @return The path to the nix-env executable, or an empty string if not found.
 */
std::string findNixEnvExecutable();

/**
 * Generate the packages.json file by querying nix-env if it doesn't already exist.
 *
 * @param nixExe Path to the nix executable.
 * @param suite The suite (flake reference).
 * @param section The section (flake output).
 * @param destFilePath The destination path for the packages.json file.
 * @return The path to the generated (or existing) packages.json file.
 */
std::string generateNixPackagesIfNecessary(
    const std::string &nixExe,
    const std::string &suite,
    const std::string &section,
    const std::string &destFilePath);

/**
 * Information about an interesting nix package.
 */
struct NixPkgInfo {
    std::string storePath;
    std::set<std::string> desktopFiles; // Resolved paths to .desktop files
};

/**
 * Get a map of interesting nix packages (those that might have AppStream data).
 * This function checks for packages with share/applications directories.
 *
 * @param nixExe Path to the nix executable.
 * @param indexPath Path to store the index cache.
 * @param storeUrl URL of the nix store.
 * @param packagesJson The parsed packages.json data.
 * @return A map of attribute names to package info.
 */
std::unordered_map<std::string, NixPkgInfo> getInterestingNixPkgs(
    const std::string &nixExe,
    const std::string &indexPath,
    const std::string &storeUrl,
    const nlohmann::json &packagesJson);

/**
 * Read the contents of a file from the nix store using `nix store cat`.
 *
 * @param nixExe Path to the nix executable.
 * @param storeUrl URL of the nix store.
 * @param path Path to the file in the nix store.
 * @param workDir Working directory for the command (for nix cache).
 * @return The file contents as a byte array.
 */
std::vector<std::uint8_t> nixStoreCat(
    const std::string &nixExe,
    const std::string &storeUrl,
    const std::string &path,
    const std::string &workDir = "");

/**
 * List the contents of a path in the nix store using `nix store ls`.
 *
 * @param nixExe Path to the nix executable.
 * @param storeUrl URL of the nix store.
 * @param path Path to list in the nix store.
 * @param workDir Working directory for the command (for nix cache).
 * @return The directory listing as a JSON object.
 */
nlohmann::json nixStoreLs(
    const std::string &nixExe,
    const std::string &storeUrl,
    const std::string &path,
    const std::string &workDir = "");

/**
 * Compute a priority score for a package name.
 * Lower score = higher priority (preferred).
 *
 * @param name The package attribute name.
 * @return The priority score.
 */
int packagePriority(const std::string &name);

} // namespace ASGenerator
