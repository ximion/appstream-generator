/*
 * Copyright (C) 2021-2025 Matthias Klumpp <matthias@tenstral.net>
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

#include "cptmodifiers.h"

#include <fstream>
#include <filesystem>
#include <format>
#include <libfyaml.h>
#include <appstream.h>

#include "logging.h"
#include "result.h"
#include "utils.h"

namespace ASGenerator
{

InjectedModifications::InjectedModifications()
    : m_hasRemovedCpts(false),
      m_hasInjectedCustom(false)
{
}

InjectedModifications::~InjectedModifications()
{
    for (auto &[key, cpt] : m_removedComponents)
        g_object_unref(cpt);
}

void InjectedModifications::loadForSuite(std::shared_ptr<Suite> suite)
{
    std::unique_lock<std::shared_mutex> lock(m_mutex);

    // Clear existing data and unreference components
    for (auto &[key, component] : m_removedComponents)
        g_object_unref(component);

    m_removedComponents.clear();
    m_injectedCustomData.clear();

    const auto fname = fs::path(suite->extraMetainfoDir) / "modifications.json";
    if (!fs::exists(fname))
        return;

    logInfo("Using repo-level modifications for {} (via modifications.json)", suite->name);

    // Read the JSON file
    std::ifstream file(fname);
    if (!file.is_open())
        throw std::runtime_error(std::format("Failed to open modifications file: {}", fname.string()));

    std::string jsonData((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    file.close();

    // Parse JSON
    fy_document *fyd = fy_document_build_from_string(nullptr, jsonData.c_str(), jsonData.length());
    if (!fyd)
        throw std::runtime_error(std::format("Failed to parse modifications JSON file: {}", fname.string()));

    fy_node *root = fy_document_root(fyd);
    if (!root || fy_node_get_type(root) != FYNT_MAPPING) {
        fy_document_destroy(fyd);
        throw std::runtime_error(std::format("Invalid modifications file format: {}", fname.string()));
    }

    // Process InjectCustom section
    fy_node *injectCustomNode = fy_node_mapping_lookup_by_string(root, "InjectCustom", FY_NT);
    if (injectCustomNode && fy_node_get_type(injectCustomNode) == FYNT_MAPPING) {
        logDebug("Using injected custom entries from {}", fname.string());

        fy_node_pair *pair;
        void *iter = nullptr;
        while ((pair = fy_node_mapping_iterate(injectCustomNode, &iter)) != nullptr) {
            fy_node *keyNode = fy_node_pair_key(pair);
            fy_node *valueNode = fy_node_pair_value(pair);

            if (!keyNode || !valueNode)
                continue;

            size_t keyLen = 0;
            const char *keyStr = fy_node_get_scalar(keyNode, &keyLen);
            if (!keyStr)
                continue;

            std::string entryKey(keyStr, keyLen);

            if (fy_node_get_type(valueNode) == FYNT_MAPPING) {
                std::unordered_map<std::string, std::string> customData;

                fy_node_pair *customPair;
                void *customIter = nullptr;
                while ((customPair = fy_node_mapping_iterate(valueNode, &customIter)) != nullptr) {
                    fy_node *customKeyNode = fy_node_pair_key(customPair);
                    fy_node *customValueNode = fy_node_pair_value(customPair);

                    if (!customKeyNode || !customValueNode)
                        continue;

                    size_t customKeyLen = 0;
                    const char *customKeyStr = fy_node_get_scalar(customKeyNode, &customKeyLen);
                    size_t customValueLen = 0;
                    const char *customValueStr = fy_node_get_scalar(customValueNode, &customValueLen);

                    if (customKeyStr && customValueStr) {
                        customData[std::string(customKeyStr, customKeyLen)] = std::string(
                            customValueStr, customValueLen);
                    }
                }

                m_injectedCustomData[entryKey] = std::move(customData);
            }
        }
    }

    // Process Remove section
    fy_node *removeNode = fy_node_mapping_lookup_by_string(root, "Remove", FY_NT);
    if (removeNode && fy_node_get_type(removeNode) == FYNT_SEQUENCE) {
        logDebug("Using package removal info from {}", fname.string());

        fy_node *cidNode;
        void *iter = nullptr;
        while ((cidNode = fy_node_sequence_iterate(removeNode, &iter)) != nullptr) {
            size_t cidLen = 0;
            const char *cidStr = fy_node_get_scalar(cidNode, &cidLen);
            if (!cidStr)
                continue;

            std::string cid(cidStr, cidLen);

            g_autoptr(AsComponent) cpt = as_component_new();
            as_component_set_kind(cpt, AS_COMPONENT_KIND_GENERIC);
            as_component_set_merge_kind(cpt, AS_MERGE_KIND_REMOVE_COMPONENT);
            as_component_set_id(cpt, cid.c_str());

            m_removedComponents[cid] = g_steal_pointer(&cpt);
        }
    }

    m_hasRemovedCpts = !m_removedComponents.empty();
    m_hasInjectedCustom = !m_injectedCustomData.empty();

    fy_document_destroy(fyd);
}

bool InjectedModifications::hasRemovedComponents() const
{
    return m_hasRemovedCpts;
}

/**
 * Test if component was marked for deletion.
 */
bool InjectedModifications::isComponentRemoved(const std::string &cid) const
{
    if (!m_hasRemovedCpts)
        return false;

    std::shared_lock<std::shared_mutex> lock(m_mutex);
    return m_removedComponents.contains(cid);
}

std::optional<std::unordered_map<std::string, std::string>> InjectedModifications::injectedCustomData(
    const std::string &cid) const
{
    if (!m_hasInjectedCustom)
        return std::nullopt;

    std::shared_lock<std::shared_mutex> lock(m_mutex);
    auto it = m_injectedCustomData.find(cid);
    if (it == m_injectedCustomData.end())
        return std::nullopt;

    return it->second;
}

void InjectedModifications::addRemovalRequestsToResult(GeneratorResult *gres) const
{
    std::shared_lock<std::shared_mutex> lock(m_mutex);
    for (const auto &[cid, cpt] : m_removedComponents) {
        gres->addComponentWithString(cpt, std::format("{}/-{}", gres->pkid(), cid));
    }
}

} // namespace ASGenerator
