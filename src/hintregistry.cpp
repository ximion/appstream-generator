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

#include "hintregistry.h"

#include <fstream>
#include <sstream>
#include <format>
#include <mutex>
#include <unordered_set>
#include <libfyaml.h>
#include <appstream.h>
#include <appstream-compose.h>

#include "logging.h"
#include "utils.h"

namespace ASGenerator
{

static std::mutex g_hintsRegistryMutex;

void loadHintsRegistry()
{
    std::lock_guard<std::mutex> lock(g_hintsRegistryMutex);
    static bool registryLoaded = false;
    if (registryLoaded) {
        logDebug("Hints registry already loaded, ignoring second load request.");
        return;
    }

    // find the hint definition file
    auto hintsDefFile = getDataPath("asgen-hints.json");
    if (!std::filesystem::exists(hintsDefFile)) {
        logError(
            "Hints definition file '{}' was not found! This means we can not determine severity of issue tags and not "
            "render report pages.",
            hintsDefFile.string());
        return;
    }

    // read the hints definition JSON file
    std::ifstream file(hintsDefFile);
    if (!file.is_open()) {
        logError("Failed to open hints definition file '{}'", hintsDefFile.string());
        return;
    }

    std::string jsonData((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    file.close();

    // Parse JSON
    fy_document *fyd = fy_document_build_from_string(nullptr, jsonData.c_str(), jsonData.length());
    if (!fyd) {
        logError("Failed to parse hints definition JSON file");
        return;
    }

    fy_node *root = fy_document_root(fyd);
    if (!root || fy_node_get_type(root) != FYNT_MAPPING) {
        logError("Invalid hints definition file format");
        fy_document_destroy(fyd);
        return;
    }

    bool checkAlreadyLoaded = true;

    // Iterate through all hint definitions
    fy_node_pair *pair;
    void *iter = nullptr;
    while ((pair = fy_node_mapping_iterate(root, &iter)) != nullptr) {
        fy_node *keyNode = fy_node_pair_key(pair);
        fy_node *valueNode = fy_node_pair_value(pair);

        if (!keyNode || !valueNode)
            continue;

        // Get tag name
        size_t tagLen = 0;
        const char *tagStr = fy_node_get_scalar(keyNode, &tagLen);
        if (!tagStr)
            continue;

        std::string tag(tagStr, tagLen);

        if (fy_node_get_type(valueNode) != FYNT_MAPPING)
            continue;

        // Get severity
        fy_node *severityNode = fy_node_mapping_lookup_by_string(valueNode, "severity", FY_NT);
        if (!severityNode)
            continue;

        size_t severityLen = 0;
        const char *severityStr = fy_node_get_scalar(severityNode, &severityLen);
        if (!severityStr)
            continue;

        std::string severityString(severityStr, severityLen);
        auto severity = as_issue_severity_from_string(severityString.c_str());

        // Get explanation text
        fy_node *textNode = fy_node_mapping_lookup_by_string(valueNode, "text", FY_NT);
        if (!textNode)
            continue;

        std::string explanation;
        if (fy_node_get_type(textNode) == FYNT_SEQUENCE) {
            // Text is an array of lines
            fy_node *lineNode;
            void *textIter = nullptr;
            while ((lineNode = fy_node_sequence_iterate(textNode, &textIter)) != nullptr) {
                size_t lineLen = 0;
                const char *lineStr = fy_node_get_scalar(lineNode, &lineLen);
                if (lineStr) {
                    explanation += std::string(lineStr, lineLen) + "\n";
                }
            }
        } else {
            // Text is a single string
            size_t textLen = 0;
            const char *textStr = fy_node_get_scalar(textNode, &textLen);
            if (textStr) {
                explanation = std::string(textStr, textLen);
            }
        }

        bool overrideExisting = false;
        if (tag == "icon-not-found" || tag == "internal-unknown-tag" || tag == "internal-error"
            || tag == "no-metainfo") {
            overrideExisting = true;
        }

        if (checkAlreadyLoaded) {
            // Check if hints are already loaded by looking for a common tag
            if (!overrideExisting && asc_globals_hint_tag_severity(tag.c_str()) != AS_ISSUE_SEVERITY_UNKNOWN) {
                logDebug("Global hints registry already loaded.");
                fy_document_destroy(fyd);
                return;
            }
            checkAlreadyLoaded = false;
        }

        if (!asc_globals_add_hint_tag(tag.c_str(), severity, explanation.c_str(), overrideExisting))
            logError("Unable to override existing hint tag: {}", tag);
    }

    registryLoaded = true;
    fy_document_destroy(fyd);
}

void saveHintsRegistryToJsonFile(const std::string &fname)
{
    std::lock_guard<std::mutex> lock(g_hintsRegistryMutex);

    // Create YAML document for JSON output
    fy_document *fyd = fy_document_create(nullptr);
    if (!fyd)
        throw std::runtime_error("Failed to create document for hints registry export");

    fy_node *root = fy_node_create_mapping(fyd);
    fy_document_set_root(fyd, root);

    g_auto(GStrv) hintTags = asc_globals_get_hint_tags();
    for (guint i = 0; hintTags[i] != nullptr; i++) {
        const gchar *tag = hintTags[i];
        const auto hdef = retrieveHintDef(tag);

        // Create mapping for this hint
        fy_node *hintMapping = fy_node_create_mapping(fyd);

        // Add text field
        fy_node *textKey = fy_node_create_scalar(fyd, "text", FY_NT);
        fy_node *textValue = fy_node_create_scalar_copy(fyd, hdef.explanation.c_str(), FY_NT);
        fy_node_mapping_append(hintMapping, textKey, textValue);

        // Add severity field
        fy_node *severityKey = fy_node_create_scalar(fyd, "severity", FY_NT);
        fy_node *severityValue = fy_node_create_scalar(fyd, as_issue_severity_to_string(hdef.severity), FY_NT);
        fy_node_mapping_append(hintMapping, severityKey, severityValue);

        // Add to root mapping
        fy_node *tagKey = fy_node_create_scalar(fyd, tag, FY_NT);
        fy_node_mapping_append(root, tagKey, hintMapping);
    }

    // Emit as JSON
    g_autofree char *json_output = fy_emit_document_to_string(
        fyd, static_cast<fy_emitter_cfg_flags>(FYECF_MODE_JSON | FYECF_INDENT_DEFAULT));

    if (json_output) {
        std::ofstream file(fname);
        if (file.is_open()) {
            file.write(json_output, strlen(json_output));
            file.close();
        } else {
            logError("Failed to open file '{}' for writing", fname);
        }
    } else {
        throw std::runtime_error("Failed to emit hints registry as JSON");
    }

    fy_document_destroy(fyd);
}

HintDefinition retrieveHintDef(const gchar *tag)
{
    HintDefinition hdef;
    hdef.tag = tag;
    hdef.severity = asc_globals_hint_tag_severity(tag);
    if (hdef.severity == AS_ISSUE_SEVERITY_UNKNOWN)
        return {};
    hdef.explanation = std::string(asc_globals_hint_tag_explanation(tag));
    return hdef;
}

std::string hintToJsonString(const std::string &tag, const std::unordered_map<std::string, std::string> &vars)
{
    // Create YAML document for JSON output
    fy_document *fyd = fy_document_create(nullptr);
    if (!fyd) {
        return "{}";
    }

    fy_node *root = fy_node_create_mapping(fyd);
    fy_document_set_root(fyd, root);

    // Add tag field
    fy_node *tagKey = fy_node_create_scalar(fyd, "tag", FY_NT);
    fy_node *tagValue = fy_node_create_scalar(fyd, tag.c_str(), FY_NT);
    fy_node_mapping_append(root, tagKey, tagValue);

    // Add vars field
    fy_node *varsKey = fy_node_create_scalar(fyd, "vars", FY_NT);
    fy_node *varsMapping = fy_node_create_mapping(fyd);
    fy_node_mapping_append(root, varsKey, varsMapping);

    for (const auto &[key, value] : vars) {
        fy_node *varKey = fy_node_create_scalar(fyd, key.c_str(), FY_NT);
        fy_node *varValue = fy_node_create_scalar(fyd, value.c_str(), FY_NT);
        fy_node_mapping_append(varsMapping, varKey, varValue);
    }

    // Emit as JSON
    char *json_output = fy_emit_document_to_string(fyd, FYECF_MODE_JSON);

    std::string result = "{}";
    if (json_output) {
        result = std::string(json_output);
        free(json_output);
    }

    fy_document_destroy(fyd);
    return result;
}

} // namespace ASGenerator
