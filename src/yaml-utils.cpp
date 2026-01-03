/*
 * Copyright (C) 2018-2025 Matthias Klumpp <matthias@tenstral.net>
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
#include "yaml-utils.h"

#include <stdexcept>
#include <memory>

namespace ASGenerator
{

namespace Yaml
{

/**
 * Parse a YAML/JSON document from a string.
 * @param yamlData The YAML/JSON data as a string.
 * @param forceJson If true, only allow JSON input.
 * @return The parsed fy_document object.
 * @throws std::runtime_error if parsing fails.
 */
YDocumentPtr parseDocument(const std::string &yamlData, bool forceJson)
{
    fy_parse_cfg cfg = {};

    if (forceJson)
        cfg.flags = FYPCF_JSON_FORCE;
    else
        cfg.flags = FYPCF_DEFAULT_VERSION_1_2;

    auto parser = fy_parser_create(&cfg);
    if (!parser)
        throw std::runtime_error("Failed to create YAML parser");

    if (fy_parser_set_string(parser, yamlData.c_str(), yamlData.length()) != 0) {
        fy_parser_destroy(parser);
        throw std::runtime_error("Failed to set JSON/YAML parser input");
    }

    auto doc = fy_parse_load_document(parser);
    fy_parser_destroy(parser);

    if (!doc)
        throw std::runtime_error("Failed to parse JSON/YAML document");

    return YDocumentPtr(doc, fy_document_destroy);
}

fy_node *documentRoot(YDocumentPtr &doc)
{
    return doc ? fy_document_root(doc.get()) : nullptr;
}

std::string nodeStrValue(fy_node *node, std::string defaultValue)
{
    if (!node || fy_node_get_type(node) != FYNT_SCALAR)
        return defaultValue;

    size_t len = 0;
    const char *value = fy_node_get_scalar(node, &len);
    return value ? std::string(value, len) : std::move(defaultValue);
}

int64_t nodeIntValue(fy_node *node, int64_t defaultValue)
{
    if (!node || fy_node_get_type(node) != FYNT_SCALAR)
        return defaultValue;

    size_t len = 0;
    const char *value = fy_node_get_scalar(node, &len);
    if (!value)
        return defaultValue;
    
    std::string strValue(value, len);
    try {
        return std::stoll(strValue);
    } catch (...) {
        return defaultValue;
    }
}

bool nodeBoolValue(fy_node *node, bool defaultValue)
{
    if (!node || fy_node_get_type(node) != FYNT_SCALAR)
        return defaultValue;

    size_t len = 0;
    const char *value = fy_node_get_scalar(node, &len);
    if (!value)
        return defaultValue;

    std::string strValue(value, len);
    return strValue == "true" || strValue == "1" || strValue == "yes";
}

std::vector<std::string> nodeArrayValues(fy_node *node)
{
    std::vector<std::string> result;

    if (!node || fy_node_get_type(node) != FYNT_SEQUENCE)
        return result;

    fy_node *item;
    void *iter = nullptr;
    while ((item = fy_node_sequence_iterate(node, &iter)) != nullptr) {
        auto value = nodeStrValue(item);
        if (!value.empty())
            result.push_back(std::move(value));
    }

    return result;
}

fy_node *nodeByKey(fy_node *mapping, const std::string &key)
{
    if (!mapping || fy_node_get_type(mapping) != FYNT_MAPPING)
        return nullptr;

    fy_node_pair *pair;
    void *iter = nullptr;
    while ((pair = fy_node_mapping_iterate(mapping, &iter)) != nullptr) {
        auto keyNode = fy_node_pair_key(pair);
        auto keyValue = nodeStrValue(keyNode);
        if (keyValue == key)
            return fy_node_pair_value(pair);
    }

    return nullptr;
}

YDocumentPtr createDocument()
{
    auto doc = fy_document_create(nullptr);
    return YDocumentPtr(doc, fy_document_destroy);
}

std::string libfyamlVersion() noexcept
{
    const auto versionRaw = fy_library_version();
    if (versionRaw == nullptr)
        return {};

    std::string version(versionRaw);
    if (version == "UNKNOWN")
        return {};

    return version;
}

} // namespace Yaml

} // namespace ASGenerator
