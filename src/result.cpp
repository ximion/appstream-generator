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

#include "result.h"

#include <format>
#include <algorithm>
#include <libfyaml.h>
#include <appstream.h>
#include <appstream-compose.h>

#include "hintregistry.h"
#include "logging.h"

namespace ASGenerator
{

GeneratorResult::GeneratorResult(std::shared_ptr<Package> pkg)
    : m_pkg(std::move(pkg)),
      m_res(asc_result_new())
{
    asc_result_set_bundle_kind(m_res, AS_BUNDLE_KIND_PACKAGE);
    asc_result_set_bundle_id(m_res, m_pkg->name().c_str());
}

GeneratorResult::GeneratorResult(AscResult *result, std::shared_ptr<Package> pkg)
    : m_pkg(std::move(pkg))
{
    m_res = g_object_ref(result);
    asc_result_set_bundle_kind(m_res, AS_BUNDLE_KIND_PACKAGE);
    asc_result_set_bundle_id(m_res, m_pkg->name().c_str());
}

GeneratorResult::~GeneratorResult()
{
    if (m_res)
        g_object_unref(m_res);
}

GeneratorResult::GeneratorResult(GeneratorResult &&other) noexcept
    : m_pkg(std::move(other.m_pkg)),
      m_res(other.m_res)
{
    other.m_res = nullptr;
}

GeneratorResult &GeneratorResult::operator=(GeneratorResult &&other) noexcept
{
    if (this != &other) {
        if (m_res)
            g_object_unref(m_res);

        m_pkg = std::move(other.m_pkg);
        m_res = other.m_res;

        other.m_res = nullptr;
    }
    return *this;
}

std::string GeneratorResult::pkid() const
{
    return m_pkg->id();
}

bool GeneratorResult::addHint(
    const std::string &id,
    const std::string &tag,
    const std::unordered_map<std::string, std::string> &vars)
{
    std::string cid = id.empty() ? "general" : id;

    if (vars.empty())
        return asc_result_add_hint_by_cid(m_res, cid.c_str(), tag.c_str(), nullptr, nullptr) != 0;

    // create null-terminated argument list for variadic function
    std::vector<char *> args;
    for (const auto &[key, value] : vars) {
        args.push_back(const_cast<char *>(key.c_str()));
        args.push_back(const_cast<char *>(value.c_str()));
    }
    args.push_back(nullptr); // null terminator

    return asc_result_add_hint_by_cid_v(m_res, cid.c_str(), tag.c_str(), args.data()) != 0;
}

bool GeneratorResult::addHint(
    AsComponent *cpt,
    const std::string &tag,
    const std::unordered_map<std::string, std::string> &vars)
{
    std::string cid = cpt ? as_component_get_id(cpt) : "general";
    return addHint(cid, tag, vars);
}

bool GeneratorResult::addHint(const std::string &id, const std::string &tag, const std::string &msg)
{
    std::unordered_map<std::string, std::string> vars;
    if (!msg.empty()) {
        vars["msg"] = msg;
    }
    return addHint(id, tag, vars);
}

bool GeneratorResult::addHint(AsComponent *cpt, const std::string &tag, const std::string &msg)
{
    std::string cid = cpt ? as_component_get_id(cpt) : "general";
    return addHint(cid, tag, msg);
}

void GeneratorResult::addComponentWithString(AsComponent *cpt, const std::string &data)
{
    g_autoptr(GError) error = nullptr;
    if (!asc_result_add_component_with_string(m_res, cpt, data.c_str(), &error))
        throw std::runtime_error(error->message);
}

std::string GeneratorResult::hintsToJson() const
{
    if (hintsCount() == 0) {
        return "";
    }

    // Create the root document
    fy_document *fyd = fy_document_create(nullptr);
    if (!fyd) {
        logError("Failed to create YAML document for hints");
        return "";
    }

    // Create root mapping
    fy_node *root = fy_node_create_mapping(fyd);
    fy_document_set_root(fyd, root);

    // Add package field
    g_autofree gchar *pkgid = g_strdup(pkid().c_str());
    fy_node *pkgKey = fy_node_create_scalar(fyd, "package", FY_NT);
    fy_node *pkgValue = fy_node_create_scalar(fyd, pkgid, FY_NT);
    fy_node_mapping_append(root, pkgKey, pkgValue);

    // Create hints mapping
    fy_node *hintsKey = fy_node_create_scalar(fyd, "hints", FY_NT);
    fy_node *hintsMapping = fy_node_create_mapping(fyd);
    fy_node_mapping_append(root, hintsKey, hintsMapping);

    // Get component IDs with hints
    auto componentIds = getComponentIdsWithHints();

    for (const auto &cid : componentIds) {
        // Get hints for this component
        GPtrArray *cptHints = asc_result_get_hints(m_res, cid.c_str());
        if (!cptHints || cptHints->len == 0)
            continue;

        // Create sequence for this component's hints
        fy_node *cidKey = fy_node_create_scalar(fyd, cid.c_str(), FY_NT);
        fy_node *hintSequence = fy_node_create_sequence(fyd);
        fy_node_mapping_append(hintsMapping, cidKey, hintSequence);

        for (guint i = 0; i < cptHints->len; i++) {
            AscHint *hint = static_cast<AscHint *>(g_ptr_array_index(cptHints, i));

            // Create mapping for this hint
            fy_node *hintMapping = fy_node_create_mapping(fyd);
            fy_node_sequence_append(hintSequence, hintMapping);

            // Add tag
            const char *tag = asc_hint_get_tag(hint);
            fy_node *tagKey = fy_node_create_scalar(fyd, "tag", FY_NT);
            fy_node *tagValue = fy_node_create_scalar(fyd, tag, FY_NT);
            fy_node_mapping_append(hintMapping, tagKey, tagValue);

            // Add vars
            GPtrArray *varsList = asc_hint_get_explanation_vars_list(hint);
            if (varsList && varsList->len > 0) {
                fy_node *varsKey = fy_node_create_scalar(fyd, "vars", FY_NT);
                fy_node *varsMapping = fy_node_create_mapping(fyd);
                fy_node_mapping_append(hintMapping, varsKey, varsMapping);

                for (guint j = 0; j < varsList->len; j += 2) {
                    if (j + 1 < varsList->len) {
                        const char *key = static_cast<const char *>(g_ptr_array_index(varsList, j));
                        const char *value = static_cast<const char *>(g_ptr_array_index(varsList, j + 1));

                        fy_node *varKey = fy_node_create_scalar(fyd, key, FY_NT);
                        fy_node *varValue = fy_node_create_scalar(fyd, value, FY_NT);
                        fy_node_mapping_append(varsMapping, varKey, varValue);
                    }
                }
            }
        }
    }

    // Emit as JSON
    char *json_output = fy_emit_document_to_string(fyd, FYECF_MODE_JSON);

    std::string result;
    if (json_output) {
        result = std::string(json_output);
        free(json_output);
    }

    fy_document_destroy(fyd);
    return result;
}

std::uint32_t GeneratorResult::hintsCount() const
{
    return asc_result_hints_count(m_res);
}

std::uint32_t GeneratorResult::componentsCount() const
{
    return asc_result_components_count(m_res);
}

std::vector<std::string> GeneratorResult::getComponentIdsWithHints() const
{
    g_autofree const gchar **cids = asc_result_get_component_ids_with_hints(m_res);
    std::vector<std::string> result;

    if (cids) {
        for (int i = 0; cids[i] != nullptr; ++i)
            result.emplace_back(cids[i]);
    }

    return result;
}

bool GeneratorResult::hasHint(const std::string &componentId, const std::string &tag) const
{
    // Find the component by ID first
    GPtrArray *hints = asc_result_get_hints(m_res, componentId.c_str());
    if (!hints)
        return false;

    for (guint i = 0; i < hints->len; i++) {
        AscHint *hint = ASC_HINT(g_ptr_array_index(hints, i));
        if (asc_hint_get_tag(hint) == tag)
            return true;
    }

    return false;
}

bool GeneratorResult::hasHint(AsComponent *cpt, const std::string &tag) const
{
    if (!cpt)
        return hasHint("general", tag);

    return asc_result_has_hint(m_res, cpt, tag.c_str()) != 0;
}

void GeneratorResult::addComponent(AsComponent *cpt) const
{
    asc_result_add_component(m_res, cpt, nullptr, nullptr);
}

void GeneratorResult::removeComponent(AsComponent *cpt) const
{
    asc_result_remove_component(m_res, cpt);
}

bool GeneratorResult::isIgnored(AsComponent *cpt) const
{
    return asc_result_is_ignored(m_res, cpt) != 0;
}

std::string GeneratorResult::gcidForComponent(AsComponent *cpt) const
{
    const char *gcid = asc_result_gcid_for_component(m_res, cpt);
    std::string result;
    if (gcid) {
        result = gcid;
    }
    return result;
}

std::vector<std::string> GeneratorResult::getComponentGcids() const
{
    g_autofree const char **gcids = asc_result_get_component_gcids(m_res);
    std::vector<std::string> result;

    if (gcids) {
        for (int i = 0; gcids[i] != nullptr; ++i)
            result.emplace_back(gcids[i]);
    }

    return result;
}

} // namespace ASGenerator
