/*
 * Copyright (C) 2016-2026 Matthias Klumpp <matthias@tenstral.net>
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

#include "reportgenerator.h"

#include <filesystem>
#include <fstream>
#include <regex>
#include <algorithm>
#include <format>
#include <chrono>
#include <ranges>
#include <array>
#include <optional>

#include <glib.h>
#include <appstream.h>
#include <appstream-compose.h>

#include "defines.h"
#include "logging.h"
#include "utils.h"
#include "hintregistry.h"
#include "zarchive.h"

namespace ASGenerator
{

using json = nlohmann::json;

ReportGenerator::ReportGenerator(DataStore *db, StatsStore *sdb)
    : m_log(getLogger("report")),
      m_dstore(db),
      m_sstore(sdb),
      m_conf(&Config::get()),
      m_templateDir(m_conf->templateDir()),
      m_injaEnv(
          m_conf->templateDir().empty() ? inja::Environment() : inja::Environment(m_conf->templateDir().string() + "/"))
{
    // Enable searching for included templates in files if we have a template directory
    m_injaEnv.set_search_included_templates_in_files(!m_conf->templateDir().empty());

    m_htmlExportDir = m_conf->htmlExportDir;
    m_mediaPoolDir = m_dstore->mediaExportPoolDir();
    m_mediaPoolUrl = std::format("{}/pool", m_conf->mediaBaseUrl);

    m_defaultTemplateDir = Utils::getDataPath("templates/default");

    m_versionInfo = std::format("{}, AS: {}", ASGEN_VERSION, as_version_string());
}

void ReportGenerator::setupInjaContext(inja::json &context)
{
    auto now = std::chrono::system_clock::now();
    auto time_t = std::chrono::system_clock::to_time_t(now);
    auto *tm = std::localtime(&time_t);

    auto timeStr = std::format(
        "{:04d}-{:02d}-{:02d} {:02d}:{:02d} [{}]",
        tm->tm_year + 1900,
        tm->tm_mon + 1,
        tm->tm_mday,
        tm->tm_hour,
        tm->tm_min,
        tm->tm_zone ? tm->tm_zone : "UTC");

    context["time"] = timeStr;
    context["generator_version"] = m_versionInfo;
    context["project_name"] = m_conf->projectName;
    context["root_url"] = m_conf->htmlBaseUrl;
}

void ReportGenerator::renderPage(const std::string &pageID, const std::string &exportName, const inja::json &context)
{
    inja::json fullContext = context;
    setupInjaContext(fullContext);

    auto fname = m_htmlExportDir / (exportName + ".html");
    fs::create_directories(fname.parent_path());

    auto templatePath = m_templateDir / (pageID + ".html");
    auto defaultTemplatePath = m_defaultTemplateDir / (pageID + ".html");

    inja::Environment *activeEnv = &m_injaEnv;
    std::unique_ptr<inja::Environment> defaultEnv;

    if (!fs::exists(templatePath) && fs::exists(defaultTemplatePath)) {
        defaultEnv = std::make_unique<inja::Environment>(m_defaultTemplateDir.string() + "/");
        // Configure the default environment to search for included templates in files
        defaultEnv->set_search_included_templates_in_files(true);
        activeEnv = defaultEnv.get();
    }

    LOG_DEBUG(m_log, "Rendering HTML page: {}", exportName);
    try {
        auto data = activeEnv->render_file(pageID + ".html", fullContext);

        std::ofstream f(fname);
        f << data;
        f.close();
    } catch (const std::exception &e) {
        LOG_ERROR(m_log, "Failed to render template {}: {}", pageID, e.what());
    }
}

/**
 * Build the description of a health bar: one segment per component state, with the share of
 * the whole each one takes up.
 */
static inja::json buildHealthContext(int64_t clean, int64_t warning, int64_t rejected)
{
    const std::array<std::tuple<const char *, const char *, int64_t>, 3> segmentDefs = {
        {{"clean", "Clean", clean}, {"warning", "Warnings", warning}, {"rejected", "Rejected", rejected}}
    };

    const int64_t total = clean + warning + rejected;

    auto segments = inja::json::array();
    for (const auto &[key, label, count] : segmentDefs) {
        if (count <= 0)
            continue;
        segments.push_back(
            inja::json{
                {"key",        key                                                                                },
                {"label",      label                                                                              },
                {"count",      count                                                                              },
                {"percentage", total > 0 ? (static_cast<double>(count) * 100.0 / static_cast<double>(total)) : 0.0}
        });
    }

    return inja::json{
        {"total",    total   },
        {"segments", segments}
    };
}

/**
 * Draw a small trend line for a handful of values. This is decoration next to a number that
 * already says what the current state is, so it carries no axes and no labels - it only has
 * to show which way things have been moving.
 */
static std::string renderSparkline(const std::vector<int64_t> &values)
{
    constexpr double width = 104.0;
    constexpr double height = 26.0;
    constexpr double padding = 3.0;

    if (values.size() < 2)
        return {};

    const auto [minIt, maxIt] = std::ranges::minmax_element(values);
    const auto minValue = static_cast<double>(*minIt);
    const auto span = static_cast<double>(*maxIt) - minValue;
    const double usableHeight = height - (2 * padding);

    std::string points;
    double lastX = 0.0;
    double lastY = 0.0;
    for (std::size_t i = 0; i < values.size(); ++i) {
        lastX = (static_cast<double>(i) / static_cast<double>(values.size() - 1)) * width;
        // a series that never changed sits in the middle, rather than at the very top
        const double normalized = span > 0.0 ? (static_cast<double>(values[i]) - minValue) / span : 0.5;
        lastY = padding + ((1.0 - normalized) * usableHeight);

        if (!points.empty())
            points += ' ';
        points += std::format("{:.1f},{:.1f}", lastX, lastY);
    }

    return std::format(
        R"(<svg class="sparkline" viewBox="0 0 {0:.0f} {1:.0f}" width="{0:.0f}" height="{1:.0f}" )"
        R"(role="presentation" aria-hidden="true" focusable="false">)"
        R"(<polyline points="{2}"/><circle cx="{3:.1f}" cy="{4:.1f}" r="2.5"/></svg>)",
        width,
        height,
        points,
        lastX,
        lastY);
}

void ReportGenerator::renderPagesFor(const std::string &suiteName, const std::string &section, const DataSummary &dsum)
{
    if (m_templateDir.empty()) {
        LOG_ERROR(m_log, "Can not render HTML: No page templates found.");
        return;
    }

    LOG_INFO(m_log, "Rendering HTML for {}/{}", suiteName, section);
    std::regex maintRE(R"([àáèéëêòöøîìùñ~/\\(\\" '])");

    // write issue hint pages
    for (const auto &[pkgname, pkgHEntries] : dsum.hintEntries) {
        auto exportName = std::format("{}/{}/issues/{}", suiteName, section, pkgname);

        inja::json context;
        context["suite"] = suiteName;
        context["package_name"] = pkgname;
        context["section"] = section;

        inja::json entries = inja::json::array();
        for (const auto &[cid, hentry] : pkgHEntries) {
            inja::json entry;
            entry["component_id"] = cid;

            inja::json architectures = inja::json::array();
            for (const auto &arch : hentry.archs) {
                architectures.push_back(
                    inja::json{
                        {"arch", arch}
                });
            }
            entry["architectures"] = architectures;

            entry["has_errors"] = false;
            if (!hentry.errors.empty()) {
                entry["has_errors"] = true;
                inja::json errors = inja::json::array();
                for (const auto &error : hentry.errors) {
                    errors.push_back(
                        inja::json{
                            {"error_tag",         error.tag    },
                            {"error_description", error.message}
                    });
                }
                entry["errors"] = errors;
            }

            entry["has_warnings"] = false;
            if (!hentry.warnings.empty()) {
                entry["has_warnings"] = true;
                inja::json warnings = inja::json::array();
                for (const auto &warning : hentry.warnings) {
                    warnings.push_back(
                        inja::json{
                            {"warning_tag",         warning.tag    },
                            {"warning_description", warning.message}
                    });
                }
                entry["warnings"] = warnings;
            }

            entry["has_infos"] = false;
            if (!hentry.infos.empty()) {
                entry["has_infos"] = true;
                inja::json infos = inja::json::array();
                for (const auto &info : hentry.infos) {
                    infos.push_back(
                        inja::json{
                            {"info_tag",         info.tag    },
                            {"info_description", info.message}
                    });
                }
                entry["infos"] = infos;
            }

            entries.push_back(entry);
        }
        context["entries"] = entries;

        renderPage("issues_page", exportName, context);
    }

    // write metadata info pages
    for (const auto &[pkgname, pkgEntries] : dsum.mdataEntries) {
        auto exportName = std::format("{}/{}/metainfo/{}", suiteName, section, pkgname);

        inja::json context;
        context["suite"] = suiteName;
        context["package_name"] = pkgname;
        context["section"] = section;
        // we know what we put on the page, so the syntax highlighting does not have to guess
        context["metadata_language"] = m_conf->metadataType == DataType::XML ? "xml" : "yaml";

        inja::json cpts = inja::json::array();
        for (const auto &[gcid, mentry] : pkgEntries) {
            inja::json cpt;
            cpt["component_id"] = std::format("{} - {}", mentry.identifier, mentry.version);

            inja::json architectures = inja::json::array();
            for (const auto &arch : mentry.archs) {
                architectures.push_back(
                    inja::json{
                        {"arch", Utils::escapeXml(arch)}
                });
            }
            cpt["architectures"] = architectures;
            cpt["metadata"] = Utils::escapeXml(mentry.data);

            auto cptMediaPath = m_mediaPoolDir / gcid;
            auto cptMediaUrl = std::format("{}/{}", m_mediaPoolUrl, gcid);
            std::string iconUrl;

            switch (mentry.kind) {
            case AS_COMPONENT_KIND_UNKNOWN:
                iconUrl = std::format("{}/{}/{}/{}", m_conf->htmlBaseUrl, "static", "img", "no-image.png");
                break;
            case AS_COMPONENT_KIND_DESKTOP_APP:
            case AS_COMPONENT_KIND_WEB_APP:
            case AS_COMPONENT_KIND_FONT:
            case AS_COMPONENT_KIND_OPERATING_SYSTEM: {
                auto iconPath = cptMediaPath / "icons" / "64x64" / mentry.iconName;
                if (fs::exists(iconPath)) {
                    iconUrl = std::format("{}/{}/{}/{}", cptMediaUrl, "icons", "64x64", mentry.iconName);
                } else {
                    iconUrl = std::format("{}/{}/{}/{}", m_conf->htmlBaseUrl, "static", "img", "no-image.png");
                }
                break;
            }
            default:
                iconUrl = std::format("{}/{}/{}/{}", m_conf->htmlBaseUrl, "static", "img", "cpt-nogui.png");
                break;
            }

            cpt["icon_url"] = iconUrl;
            cpts.push_back(cpt);
        }
        context["cpts"] = cpts;

        renderPage("metainfo_page", exportName, context);
    }

    // write hint overview page
    auto hindexExportName = std::format("{}/{}/issues/index", suiteName, section);
    inja::json hsummaryCtx;
    hsummaryCtx["suite"] = suiteName;
    hsummaryCtx["section"] = section;

    inja::json summaries = inja::json::array();
    for (const auto &[maintainer, pkgSummariesMap] : dsum.pkgSummaries) {
        inja::json summary;
        summary["maintainer"] = maintainer;
        summary["maintainer_anchor"] = std::regex_replace(maintainer, maintRE, "_");

        bool interesting = false;
        inja::json packages = inja::json::array();
        for (const auto &[pkgname, pkgSummary] : pkgSummariesMap) {
            if ((pkgSummary.infoCount == 0) && (pkgSummary.warningCount == 0) && (pkgSummary.errorCount == 0))
                continue;
            interesting = true;

            inja::json pkg;
            pkg["pkgname"] = pkgSummary.pkgname;

            // use conditionals for count display
            if (pkgSummary.infoCount > 0)
                pkg["has_info_count"] = true;
            if (pkgSummary.warningCount > 0)
                pkg["has_warning_count"] = true;
            if (pkgSummary.errorCount > 0)
                pkg["has_error_count"] = true;

            pkg["info_count"] = pkgSummary.infoCount;
            pkg["warning_count"] = pkgSummary.warningCount;
            pkg["error_count"] = pkgSummary.errorCount;

            packages.push_back(pkg);
        }

        if (interesting) {
            summary["packages"] = packages;
            summaries.push_back(summary);
        }
    }
    hsummaryCtx["summaries"] = summaries;
    renderPage("issues_index", hindexExportName, hsummaryCtx);

    // write metainfo overview page
    auto mindexExportName = std::format("{}/{}/metainfo/index", suiteName, section);
    inja::json msummaryCtx;
    msummaryCtx["suite"] = suiteName;
    msummaryCtx["section"] = section;

    inja::json metaSummaries = inja::json::array();
    for (const auto &[maintainer, pkgSummariesMap] : dsum.pkgSummaries) {
        inja::json metaSummary;
        metaSummary["maintainer"] = maintainer;
        metaSummary["maintainer_anchor"] = std::regex_replace(maintainer, maintRE, "_");

        inja::json packages = inja::json::array();
        for (const auto &[pkgname, pkgSummary] : pkgSummariesMap) {
            if (pkgSummary.cpts.empty())
                continue;

            inja::json pkg;
            pkg["pkgname"] = pkgSummary.pkgname;

            inja::json components = inja::json::array();
            for (const auto &cid : pkgSummary.cpts) {
                components.push_back(
                    inja::json{
                        {"cid", cid}
                });
            }
            pkg["components"] = components;

            packages.push_back(pkg);
        }

        metaSummary["packages"] = packages;
        metaSummaries.push_back(metaSummary);
    }
    msummaryCtx["summaries"] = metaSummaries;
    renderPage("metainfo_index", mindexExportName, msummaryCtx);

    // render section index page
    auto secIndexExportName = std::format("{}/{}/index", suiteName, section);
    inja::json secIndexCtx;
    secIndexCtx["suite"] = suiteName;
    secIndexCtx["section"] = section;

    secIndexCtx["health"] = buildHealthContext(dsum.cptsClean, dsum.cptsWarning, dsum.cptsRejected);

    secIndexCtx["metainfo_count"] = dsum.totalMetadata;
    secIndexCtx["error_count"] = dsum.totalErrors;
    secIndexCtx["warning_count"] = dsum.totalWarnings;
    secIndexCtx["info_count"] = dsum.totalInfos;

    renderPage("section_page", secIndexExportName, secIndexCtx);
}

ReportGenerator::DataSummary ReportGenerator::preprocessInformation(
    const std::string &suiteName,
    const std::string &section,
    const std::vector<std::shared_ptr<Package>> &pkgs)
{
    DataSummary dsum;

    LOG_INFO(m_log, "Collecting data about hints and available metainfo for {}/{}", suiteName, section);

    auto dtype = m_conf->metadataType;
    g_autoptr(AsMetadata) mdata = as_metadata_new();
    as_metadata_set_format_style(mdata, AS_FORMAT_STYLE_CATALOG);
    as_metadata_set_format_version(mdata, m_conf->formatVersion);

    for (const auto &pkg : pkgs) {
        const auto &pkid = pkg->id();

        auto gcids = m_dstore->getGCIDsForPackage(pkid);
        auto hintsData = m_dstore->getHints(pkid);
        if (gcids.empty() && hintsData.empty())
            continue;

        PkgSummary pkgsummary;
        pkgsummary.pkgname = pkg->name();

        // an existing summary is carried on, as its issue counts are for the whole package,
        // across all of the architectures and versions it exists in
        auto maintainerIt = dsum.pkgSummaries.find(pkg->maintainer());
        if (maintainerIt != dsum.pkgSummaries.end()) {
            auto pkgIt = maintainerIt->second.find(pkg->name());
            if (pkgIt != maintainerIt->second.end())
                pkgsummary = pkgIt->second;
        }

        // process component metadata for this package if there are any
        if (!gcids.empty()) {
            for (const auto &gcid : gcids) {
                auto cidOpt = Utils::getCidFromGlobalID(gcid);
                if (!cidOpt.has_value())
                    continue;

                auto cid = cidOpt.value();

                // A global component ID is derived from the component data itself, so it names
                // exactly one component, no matter which package version or architecture we
                // found it in. Don't do any work for one twice: a package can carry a different
                // version on every architecture (binNMUs), so keying these entries on the
                // version as well made us read and parse the metadata of all of its components
                // again for each version we came across.
                auto pkgIt = dsum.mdataEntries.find(pkg->name());
                if (pkgIt != dsum.mdataEntries.end()) {
                    auto meIt = pkgIt->second.find(gcid);
                    if (meIt != pkgIt->second.end()) {
                        // we already know this component, just note the architecture it is on
                        auto &archs = meIt->second.archs;
                        if (std::find(archs.begin(), archs.end(), pkg->arch()) == archs.end())
                            archs.push_back(pkg->arch());
                        continue;
                    }
                }

                // this component is new. We keep the set of components we counted separately
                // from the entries above, as a component is counted once for the entire
                // section, while the entries are per package and only used to render its pages.
                if (dsum.countedGcids.insert(gcid).second)
                    dsum.totalMetadata += 1;

                MetadataEntry me;
                me.identifier = cid;
                me.version = pkg->ver();
                me.data = m_dstore->getMetadata(dtype, gcid);

                as_metadata_clear_components(mdata);
                g_autoptr(GError) error = nullptr;
                if (dtype == DataType::YAML)
                    as_metadata_parse_data(mdata, me.data.c_str(), -1, AS_FORMAT_KIND_YAML, &error);
                else
                    as_metadata_parse_data(mdata, me.data.c_str(), -1, AS_FORMAT_KIND_XML, &error);

                if (error != nullptr) {
                    LOG_WARNING(m_log, "Failed to parse metadata for {}: {}", gcid, error->message);
                    continue;
                }

                auto cpt = as_metadata_get_component(mdata);
                if (cpt != nullptr) {
                    const auto iconsArr = as_component_get_icons(cpt);
                    assert(iconsArr != nullptr);
                    for (guint i = 0; i < iconsArr->len; i++) {
                        AsIcon *icon = AS_ICON(g_ptr_array_index(iconsArr, i));
                        if (as_icon_get_kind(icon) == AS_ICON_KIND_CACHED) {
                            me.iconName = as_icon_get_name(icon);
                            break;
                        }
                    }

                    me.kind = as_component_get_kind(cpt);
                } else {
                    me.kind = AS_COMPONENT_KIND_UNKNOWN;
                }

                me.archs.push_back(pkg->arch());
                dsum.mdataEntries[pkg->name()][gcid] = std::move(me);
                pkgsummary.cpts.emplace_back(std::format("{} - {}", cid, pkg->ver()));
            }
        }

        // process hints for this package, if there are any
        if (!hintsData.empty()) {
            try {
                auto hintsJson = json::parse(hintsData);

                if (!hintsJson.contains("hints") || !hintsJson["hints"].is_object())
                    continue;

                auto hintsNode = hintsJson["hints"];

                // Iterate through component IDs in hints
                for (const auto &[cid, jhintsNode] : hintsNode.items()) {
                    // don't add the same hints multiple times for multiple versions and architectures
                    auto pkgIt = dsum.hintEntries.find(pkg->name());
                    if (pkgIt != dsum.hintEntries.end()) {
                        auto heIt = pkgIt->second.find(cid);
                        if (heIt != pkgIt->second.end()) {
                            // we already have hints for this component ID, so all that is left
                            // to do is to note the architecture we have found them on as well
                            auto &archs = heIt->second.archs;
                            if (std::find(archs.begin(), archs.end(), pkg->arch()) == archs.end())
                                archs.push_back(pkg->arch());

                            // TODO: check if we have the same hints - if not, create a new entry.
                            continue;
                        }
                    }

                    HintEntry he;
                    he.identifier = cid;

                    if (jhintsNode.is_array()) {
                        // Iterate through hints array
                        for (const auto &jhintNode : jhintsNode) {
                            if (!jhintNode.is_object())
                                continue;

                            // Get tag
                            if (!jhintNode.contains("tag") || !jhintNode["tag"].is_string())
                                continue;

                            std::string tag = jhintNode["tag"];

                            g_autoptr(AscHint) hint = nullptr;
                            g_autoptr(GError) error = nullptr;
                            hint = asc_hint_new_for_tag(tag.c_str(), &error);
                            if (hint == nullptr) {
                                LOG_ERROR(
                                    m_log,
                                    "Encountered invalid tag '{}' in component '{}' of package '{}': {}",
                                    tag,
                                    cid,
                                    pkid,
                                    error ? error->message : "Unknown error");

                                // emit an internal error, invalid tags shouldn't happen
                                tag = "internal-unknown-tag";
                                hint = asc_hint_new_for_tag(tag.c_str(), nullptr);
                            }

                            // render the full message using the static template and data from the hint
                            if (jhintNode.contains("vars") && jhintNode["vars"].is_object()) {
                                for (const auto &[varKey, varValue] : jhintNode["vars"].items()) {
                                    if (varValue.is_string()) {
                                        std::string varValueStr = varValue;
                                        asc_hint_add_explanation_var(hint, varKey.c_str(), varValueStr.c_str());
                                    }
                                }
                            }

                            g_autofree gchar *msg = asc_hint_format_explanation(hint);
                            const auto severity = asc_hint_get_severity(hint);

                            // Add the new hint to the right category, and count it right here
                            // where we found it: the summary of a package accumulates over all
                            // of its versions and architectures, so adding that summary up per
                            // package would count the issues of every architecture we looked at
                            // before all over again.
                            if (severity == AS_ISSUE_SEVERITY_INFO) {
                                he.infos.emplace_back(tag, msg);
                                pkgsummary.infoCount++;
                                dsum.totalInfos += 1;
                            } else if (severity == AS_ISSUE_SEVERITY_WARNING) {
                                he.warnings.emplace_back(tag, msg);
                                pkgsummary.warningCount++;
                                dsum.totalWarnings += 1;
                            } else if (severity == AS_ISSUE_SEVERITY_PEDANTIC) {
                                // We ignore pedantic issues completely for now
                                continue;
                            } else {
                                he.errors.emplace_back(tag, msg);
                                pkgsummary.errorCount++;
                                dsum.totalErrors += 1;
                            }

                            if (severity > he.worstSeverity)
                                he.worstSeverity = severity;
                        }
                    }

                    he.archs.push_back(pkg->arch());
                    dsum.hintEntries[pkg->name()][cid] = std::move(he);
                }
            } catch (const std::exception &e) {
                LOG_ERROR(m_log, "Failed to parse hints JSON for package {}: {}", pkid, e.what());
            }
        }

        dsum.pkgSummaries[pkg->maintainer()][pkg->name()] = pkgsummary;
    }

    classifyComponents(dsum);

    return dsum;
}

void ReportGenerator::classifyComponents(DataSummary &dsum)
{
    // Sort every component into exactly one bucket, based on the worst issue it has.
    // The hints we collected are keyed by plain component ID, while the metadata is keyed
    // by global component ID - so we match them up via the plain ID we kept on every
    // metadata entry. Matching them is what keeps a component that errored out and produced
    // nothing from being counted twice, should it ever have metadata anyway.
    std::unordered_set<std::string> classifiedGcids;

    for (const auto &[pkgname, pkgEntries] : dsum.mdataEntries) {
        std::unordered_set<std::string> exportedCids;

        const auto pkgHintsIt = dsum.hintEntries.find(pkgname);
        const auto *pkgHints = pkgHintsIt == dsum.hintEntries.end() ? nullptr : &pkgHintsIt->second;

        for (const auto &[gcid, mentry] : pkgEntries) {
            exportedCids.insert(mentry.identifier);

            // a component is counted once for the whole section, just like totalMetadata is
            if (!classifiedGcids.insert(gcid).second)
                continue;

            AsIssueSeverity worst = AS_ISSUE_SEVERITY_UNKNOWN;
            if (pkgHints) {
                const auto heIt = pkgHints->find(mentry.identifier);
                if (heIt != pkgHints->end())
                    worst = heIt->second.worstSeverity;
            }

            // Anything below a warning leaves the component perfectly usable.
            // An error should have dropped it before it got here
            if (worst >= AS_ISSUE_SEVERITY_WARNING)
                dsum.cptsWarning += 1;
            else
                dsum.cptsClean += 1;
        }

        if (!pkgHints)
            continue;

        for (const auto &[cid, hentry] : *pkgHints) {
            if (hentry.worstSeverity == AS_ISSUE_SEVERITY_ERROR && !exportedCids.contains(cid))
                dsum.cptsRejected += 1;
        }
    }

    // an error means the component is dropped, so a package where everything failed has no
    // entry in @mdataEntries at all - its components still need to be counted
    for (const auto &[pkgname, pkgHints] : dsum.hintEntries) {
        if (dsum.mdataEntries.contains(pkgname))
            continue;
        for (const auto &[cid, hentry] : pkgHints) {
            if (hentry.worstSeverity == AS_ISSUE_SEVERITY_ERROR)
                dsum.cptsRejected += 1;
        }
    }
}

void ReportGenerator::saveStatistics(const std::string &suiteName, const std::string &section, const DataSummary &dsum)
{
    std::unordered_map<std::string, std::variant<std::int64_t, std::string, double>> statsData = {
        {"suite",         suiteName         },
        {"section",       section           },
        {"totalInfos",    dsum.totalInfos   },
        {"totalWarnings", dsum.totalWarnings},
        {"totalErrors",   dsum.totalErrors  },
        {"totalMetadata", dsum.totalMetadata},
        {"cptsClean",     dsum.cptsClean    },
        {"cptsWarning",   dsum.cptsWarning  },
        {"cptsRejected",  dsum.cptsRejected }
    };

    m_sstore->addStatistics(statsData);
}

ReportGenerator::StatsHistory ReportGenerator::collectStatistics()
{
    // A decade of history is already more than anyone reads off these charts, and the
    // entries stay in the database either way (so we have them if we ever need them)
    const auto cutoff = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now() - std::chrono::years{10});

    // The statistics database stores one entry per suite/section and run, holding a flat
    // set of counters. Regroup all of them into a per-suite, per-section timeline, so both
    // the exported data files and the rendered overview pages can work off the same thing.
    StatsHistory history;

    auto statsCollection = m_sstore->getStatistics(cutoff);
    std::sort(statsCollection.begin(), statsCollection.end(), [](const auto &a, const auto &b) -> bool {
        return a.time < b.time;
    });

    for (const auto &entry : statsCollection) {
        const auto &js = entry.data;

        const auto suiteIt = js.find("suite");
        const auto sectionIt = js.find("section");
        if (suiteIt == js.end() || sectionIt == js.end())
            continue;
        if (!std::holds_alternative<std::string>(suiteIt->second)
            || !std::holds_alternative<std::string>(sectionIt->second))
            continue;

        const auto &suite = std::get<std::string>(suiteIt->second);
        const auto &section = std::get<std::string>(sectionIt->second);
        if (suite.empty() || section.empty())
            continue;

        // older entries simply do not have the newer counters, which is fine: the series
        // they belong to just starts later
        const auto counter = [&js](const char *key) -> std::optional<int64_t> {
            const auto it = js.find(key);
            if (it == js.end() || !std::holds_alternative<std::int64_t>(it->second))
                return std::nullopt;
            return std::get<std::int64_t>(it->second);
        };

        StatsPoint point;
        point.time = static_cast<int64_t>(entry.time);
        point.metadata = counter("totalMetadata");
        point.errors = counter("totalErrors");
        point.warnings = counter("totalWarnings");
        point.infos = counter("totalInfos");
        point.cptsClean = counter("cptsClean");
        point.cptsWarning = counter("cptsWarning");
        point.cptsRejected = counter("cptsRejected");

        history[suite][section].push_back(std::move(point));
    }

    return history;
}

/**
 * Reduce a timeline to at most two points per day, keeping the newest state we recorded for
 * each day. We may run many times a day, and a decade of that is a lot of data to send to a
 * browser just to draw a line a few hundred pixels wide.
 */
static std::vector<ReportGenerator::StatsPoint> downsampleStats(const std::vector<ReportGenerator::StatsPoint> &points)
{
    constexpr int64_t secondsPer12h = 12 * 60 * 60;
    std::vector<ReportGenerator::StatsPoint> result;
    result.reserve(points.size());

    for (const auto &point : points) {
        if (!result.empty() && (result.back().time / secondsPer12h) == (point.time / secondsPer12h))
            result.back() = point;
        else
            result.push_back(point);
    }

    return result;
}

/**
 * Check whether a file of the template's static data is of any use to a browser.
 *
 * The JavaScript libraries we bundle ship their readable sources and a note on their
 * origin next to the minified builds our pages actually load. Publishing those only
 * bloats the export, so we leave them behind - unlike the licenses, which we have to
 * distribute alongside the code they cover.
 */
static bool staticFileNeeded(const fs::path &path)
{
    if (path.filename() == "README.source.md" || path.filename() == ".gitignore")
        return false;

    // drop a readable source if we also ship a minified build of the very same file
    if (path.extension() == ".js" && fs::exists(fs::path(path).replace_extension(".min.js")))
        return false;

    return true;
}

void ReportGenerator::exportStatistics(const StatsHistory &history)
{
    LOG_INFO(m_log, "Exporting statistical data.");

    // the series we publish, in the order the charts expect them "errors"/"warnings"/"infos"
    // count how often an issue occurred, the "cpts_" ones count component states
    static const std::array<std::pair<const char *, std::optional<int64_t> StatsPoint::*>, 7> seriesMap = {
        {{"metadata", &StatsPoint::metadata},
         {"errors", &StatsPoint::errors},
         {"warnings", &StatsPoint::warnings},
         {"infos", &StatsPoint::infos},
         {"cpts_clean", &StatsPoint::cptsClean},
         {"cpts_warning", &StatsPoint::cptsWarning},
         {"cpts_rejected", &StatsPoint::cptsRejected}}
    };

    for (const auto &[suiteName, sections] : history) {
        for (const auto &[sectionName, points] : sections) {
            const auto sampled = downsampleStats(points);

            // Columnar layout: the timestamps are shared by every series, so we only send
            // them once, and the result can be handed to the charting code as-is.
            auto sectionJson = json::object();
            auto timeArray = json::array();
            for (const auto &point : sampled)
                timeArray.push_back(point.time);
            sectionJson["time"] = std::move(timeArray);

            for (const auto &[name, member] : seriesMap) {
                auto valueArray = json::array();
                bool haveAny = false;
                for (const auto &point : sampled) {
                    const auto &value = point.*member;
                    if (value) {
                        valueArray.push_back(*value);
                        haveAny = true;
                    } else {
                        // a counter we only started recording later on: leave a gap
                        valueArray.push_back(nullptr);
                    }
                }
                if (haveAny)
                    sectionJson[name] = std::move(valueArray);
            }

            const auto statsFname = fs::path(m_htmlExportDir) / suiteName / sectionName / "statistics.json.gz";
            try {
                fs::create_directories(statsFname.parent_path());
                const auto data = sectionJson.dump();
                std::vector<uint8_t> bytes(data.begin(), data.end());
                compressAndSave(bytes, statsFname.string(), ArchiveType::GZIP);
            } catch (const std::exception &e) {
                LOG_WARNING(m_log, "Failed to write statistics data for {}/{}: {}", suiteName, sectionName, e.what());
            }
        }
    }
}

void ReportGenerator::processFor(
    const std::string &suiteName,
    const std::string &section,
    const std::vector<std::shared_ptr<Package>> &pkgs)
{
    // collect all needed information and save statistics
    auto dsum = preprocessInformation(suiteName, section, pkgs);
    saveStatistics(suiteName, section, dsum);

    // drop old pages
    auto suitSecPagesDest = fs::path(m_htmlExportDir) / suiteName / section;
    if (fs::exists(suitSecPagesDest))
        fs::remove_all(suitSecPagesDest);

    // render fresh info pages
    renderPagesFor(suiteName, section, dsum);
}

void ReportGenerator::updateIndexPages(const StatsHistory &history)
{
    LOG_INFO(m_log, "Updating HTML index pages and static data.");

    // render main overview
    inja::json context;

    // Suites are listed in the order the configuration lists them: that order is the
    // maintainer's, and for a distribution that writes the newest suite first it is more
    // useful than anything we could sort them into.
    const auto &suites = m_conf->suites;

    // the overview pages summarize what we last recorded for every section, we need the statistics for that
    inja::json suitesArray = inja::json::array();
    for (const auto &suite : suites) {
        inja::json secCtx;
        secCtx["suite"] = suite.name;

        // the start page shows each suite as a whole - which is just the sum of what we are
        // reading for its sections anyway, so it costs nothing to carry along
        bool suiteHasStats = false;
        int64_t suiteMetadata = 0;
        int64_t suiteClean = 0;
        int64_t suiteWarning = 0;
        int64_t suiteRejected = 0;

        const auto suiteHistIt = history.find(suite.name);

        inja::json sectionsArray = inja::json::array();
        for (const auto &section : suite.sections) {
            inja::json sectionCtx;
            sectionCtx["section"] = section;

            // a section we have never recorded anything for still needs its link on the page
            if (suiteHistIt == history.end()) {
                sectionsArray.push_back(sectionCtx);
                continue;
            }
            const auto sectionHistIt = suiteHistIt->second.find(section);
            if (sectionHistIt == suiteHistIt->second.end() || sectionHistIt->second.empty()) {
                sectionsArray.push_back(sectionCtx);
                continue;
            }

            const auto &points = sectionHistIt->second;
            const auto &latest = points.back();
            sectionCtx["metainfo_count"] = latest.metadata.value_or(0);
            sectionCtx["error_count"] = latest.errors.value_or(0);
            sectionCtx["warning_count"] = latest.warnings.value_or(0);
            sectionCtx["info_count"] = latest.infos.value_or(0);
            sectionCtx["health"] = buildHealthContext(
                latest.cptsClean.value_or(0), latest.cptsWarning.value_or(0), latest.cptsRejected.value_or(0));

            suiteHasStats = true;
            suiteMetadata += latest.metadata.value_or(0);
            suiteClean += latest.cptsClean.value_or(0);
            suiteWarning += latest.cptsWarning.value_or(0);
            suiteRejected += latest.cptsRejected.value_or(0);

            std::vector<int64_t> trend;
            const auto trendStart = points.size() > 12 ? points.size() - 12 : 0;
            for (auto i = trendStart; i < points.size(); ++i)
                trend.push_back(points[i].metadata.value_or(0));
            sectionCtx["sparkline"] = renderSparkline(trend);

            sectionsArray.push_back(sectionCtx);
        }
        secCtx["sections"] = sectionsArray;

        renderPage("sections_index", std::format("{}/index", suite.name), secCtx);

        // a suite we have never recorded anything for is just a link, with nothing to say
        // about it yet
        inja::json suiteCtx;
        suiteCtx["suite"] = suite.name;
        if (suiteHasStats) {
            suiteCtx["section_count"] = static_cast<int64_t>(suite.sections.size());
            suiteCtx["metainfo_count"] = suiteMetadata;
            suiteCtx["health"] = buildHealthContext(suiteClean, suiteWarning, suiteRejected);
        }
        suitesArray.push_back(std::move(suiteCtx));
    }
    context["suites"] = suitesArray;

    // ... and the same goes for the suites we no longer update
    const auto &oldsuites = m_conf->oldsuites;

    inja::json oldsuitesArray = inja::json::array();
    for (const auto &suite : oldsuites) {
        inja::json oldsuite;
        oldsuite["suite"] = suite;
        oldsuitesArray.push_back(oldsuite);
    }
    context["oldsuites"] = oldsuitesArray;

    renderPage("main", "index", context);

    // copy static data, if present
    auto staticSrcDir = fs::path(m_templateDir) / "static";
    if (fs::exists(staticSrcDir)) {
        auto staticDestDir = fs::path(m_htmlExportDir) / "static";
        if (fs::exists(staticDestDir))
            fs::remove_all(staticDestDir);

        for (const auto &entry : fs::recursive_directory_iterator(staticSrcDir)) {
            if (!entry.is_regular_file())
                continue;

            const auto relPath = fs::relative(entry.path(), staticSrcDir);
            if (!staticFileNeeded(entry.path())) {
                LOG_DEBUG(m_log, "Not publishing static file: {}", relPath.string());
                continue;
            }

            const auto destPath = staticDestDir / relPath;
            fs::create_directories(destPath.parent_path());
            Utils::copyFile(entry.path(), destPath);
        }
    }
}

} // namespace ASGenerator
