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
#include <unordered_map>
#include <vector>
#include <appstream.h>

namespace ASGenerator
{

/**
 * Each issue hint type has a severity assigned to it:
 *
 * ERROR:   A fatal error which resulted in the component being excluded from the final metadata.
 * WARNING: An issue which did not prevent generating meaningful data, but which is still serious
 *          and should be fixed (warning of this kind usually result in less data).
 * INFO:    Information, no immediate action needed (but will likely be an issue later).
 * PEDANTIC: Information which may improve the data, but could also be ignored.
 */

/**
 * Definition of an issue hint.
 */
struct HintDefinition {
    std::string tag;          /// Unique issue tag
    AsIssueSeverity severity; /// Issue severity
    std::string explanation;  /// Explanation template
};

/**
 * Load all issue hints from file and register them globally.
 */
void loadHintsRegistry();

/**
 * Save information about all hint templates we know about to a JSON file.
 */
void saveHintsRegistryToJsonFile(const std::string &fname);

/**
 * Retrieve hint definition for a given tag.
 */
HintDefinition retrieveHintDef(const char *tag);

/**
 * Convert a hint to JSON format.
 */
std::string hintToJsonString(const std::string &tag, const std::unordered_map<std::string, std::string> &vars);

} // namespace ASGenerator
