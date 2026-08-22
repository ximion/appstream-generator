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
#include <appstream.h>
#include <appstream-compose.h>
#include <nlohmann/json.hpp>

#include "hintregistry.h"
#include "logging.h"

namespace ASGenerator
{

using ordered_json = nlohmann::ordered_json;

/**
 * Create an empty hints document for @pkid.
 */
static ordered_json makeHintsDocument(const std::string &pkid)
{
    return ordered_json{
        {"package", pkid                  },
        {"hints",   ordered_json::object()}
    };
}

/**
 * Create the JSON object representing a single hint.
 */
static ordered_json makeHintNode(const std::string &tag, const std::vector<std::pair<std::string, std::string>> &vars)
{
    ordered_json hint{
        {"tag", tag}
    };
    if (!vars.empty()) {
        auto &varsNode = hint["vars"];
        for (const auto &[key, value] : vars)
            varsNode[key] = value;
    }

    return hint;
}

GeneratorResult::GeneratorResult(std::shared_ptr<Package> pkg, fs::path mediaStagingDir)
    : m_pkg(std::move(pkg)),
      m_res(asc_result_new()),
      m_mediaStagingDir(std::move(mediaStagingDir))
{
    asc_result_set_bundle_kind(m_res, AS_BUNDLE_KIND_PACKAGE);
    asc_result_set_bundle_id(m_res, m_pkg->name().c_str());
}

GeneratorResult::GeneratorResult(AscResult *result, std::shared_ptr<Package> pkg, fs::path mediaStagingDir)
    : m_pkg(std::move(pkg)),
      m_mediaStagingDir(std::move(mediaStagingDir))
{
    m_res = g_object_ref(result);
    asc_result_set_bundle_kind(m_res, AS_BUNDLE_KIND_PACKAGE);
    asc_result_set_bundle_id(m_res, m_pkg->name().c_str());
}

GeneratorResult::~GeneratorResult()
{
    clearMediaStaging();

    if (m_res)
        g_object_unref(m_res);
}

GeneratorResult::GeneratorResult(GeneratorResult &&other) noexcept
    : m_pkg(std::move(other.m_pkg)),
      m_res(other.m_res),
      m_mediaStagingDir(std::move(other.m_mediaStagingDir))
{
    other.m_res = nullptr;
    other.m_mediaStagingDir.clear();
}

GeneratorResult &GeneratorResult::operator=(GeneratorResult &&other) noexcept
{
    if (this != &other) {
        clearMediaStaging();
        if (m_res)
            g_object_unref(m_res);

        m_pkg = std::move(other.m_pkg);
        m_res = other.m_res;
        m_mediaStagingDir = std::move(other.m_mediaStagingDir);

        other.m_res = nullptr;
        other.m_mediaStagingDir.clear();
    }
    return *this;
}

fs::path GeneratorResult::mediaStagingDir(AsComponent *cpt) const
{
    if (m_mediaStagingDir.empty())
        return {};

    const auto gcid = gcidForComponent(cpt);
    if (gcid.empty())
        return {};

    return m_mediaStagingDir / gcid;
}

void GeneratorResult::clearMediaStaging()
{
    if (m_mediaStagingDir.empty())
        return;

    std::error_code ec;
    fs::remove_all(m_mediaStagingDir, ec);
    if (ec)
        LOG_WARNING(
            logRoot, "Unable to remove media staging directory '{}': {}", m_mediaStagingDir.string(), ec.message());

    m_mediaStagingDir.clear();
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
    if (hintsCount() == 0)
        return {};

    auto doc = makeHintsDocument(pkid());
    for (const auto &cid : getComponentIdsWithHints()) {
        GPtrArray *cptHints = asc_result_get_hints(m_res, cid.c_str());
        if (!cptHints || cptHints->len == 0)
            continue;

        auto &hintNodes = doc["hints"][cid];
        for (guint i = 0; i < cptHints->len; i++) {
            auto *hint = static_cast<AscHint *>(g_ptr_array_index(cptHints, i));

            std::vector<std::pair<std::string, std::string>> vars;
            GPtrArray *varsList = asc_hint_get_explanation_vars_list(hint);
            if (varsList) {
                for (guint j = 0; j + 1 < varsList->len; j += 2)
                    vars.emplace_back(
                        static_cast<const char *>(g_ptr_array_index(varsList, j)),
                        static_cast<const char *>(g_ptr_array_index(varsList, j + 1)));
            }

            hintNodes.push_back(makeHintNode(asc_hint_get_tag(hint), vars));
        }
    }

    return doc.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
}

std::optional<std::string> hintsJsonAddHint(
    const std::string &hintsJson,
    const std::string &pkid,
    const std::string &cid,
    const std::string &tag,
    const std::unordered_map<std::string, std::string> &vars)
{
    auto doc = hintsJson.empty() ? makeHintsDocument(pkid) : ordered_json::parse(hintsJson);

    auto &hintNodes = doc["hints"][cid];
    for (const auto &hint : hintNodes) {
        if (hint.value("tag", "") == tag)
            return std::nullopt;
    }

    hintNodes.push_back(makeHintNode(tag, {vars.begin(), vars.end()}));
    return doc.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
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
    g_autofree const gchar **cids = asc_result_fetch_component_ids_with_hints(m_res);
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

bool GeneratorResult::isUnitIgnored() const
{
    return asc_result_unit_ignored(m_res);
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
    g_autofree const char **gcids = asc_result_fetch_component_gcids(m_res);
    std::vector<std::string> result;

    if (gcids) {
        for (int i = 0; gcids[i] != nullptr; ++i)
            result.emplace_back(gcids[i]);
    }

    return result;
}

GPtrArray *GeneratorResult::fetchComponents() const
{
    return asc_result_fetch_components(m_res);
}

} // namespace ASGenerator
