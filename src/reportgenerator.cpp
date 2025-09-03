/*
 * Copyright (C) 2016-2022 Matthias Klumpp <matthias@tenstral.net>
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
#include <optional>

#include <glib.h>
#include <appstream.h>
#include <appstream-compose.h>

#include "defines.h"
#include "logging.h"
#include "utils.h"
#include "hintregistry.h"

namespace ASGenerator
{

ReportGenerator::ReportGenerator(DataStore *db)
    : m_dstore(db),
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

    logDebug("Rendering HTML page: {}", exportName);
    try {
        auto data = activeEnv->render_file(pageID + ".html", fullContext);

        std::ofstream f(fname);
        f << data;
        f.close();
    } catch (const std::exception &e) {
        logError("Failed to render template {}: {}", pageID, e.what());
    }
}

void ReportGenerator::renderPagesFor(const std::string &suiteName, const std::string &section, const DataSummary &dsum)
{
    if (m_templateDir.empty()) {
        logError("Can not render HTML: No page templates found.");
        return;
    }

    logInfo("Rendering HTML for {}/{}", suiteName, section);
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
                architectures.push_back(inja::json{
                    {"arch", arch}
                });
            }
            entry["architectures"] = architectures;

            entry["has_errors"] = false;
            if (!hentry.errors.empty()) {
                entry["has_errors"] = true;
                inja::json errors = inja::json::array();
                for (const auto &error : hentry.errors) {
                    errors.push_back(inja::json{
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
                    warnings.push_back(inja::json{
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
                    infos.push_back(inja::json{
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
    for (const auto &[pkgname, pkgMVerEntries] : dsum.mdataEntries) {
        auto exportName = std::format("{}/{}/metainfo/{}", suiteName, section, pkgname);

        inja::json context;
        context["suite"] = suiteName;
        context["package_name"] = pkgname;
        context["section"] = section;

        inja::json cpts = inja::json::array();
        for (const auto &[ver, mEntries] : pkgMVerEntries) {
            for (const auto &[gcid, mentry] : mEntries) {
                inja::json cpt;
                cpt["component_id"] = std::format("{} - {}", mentry.identifier, ver);

                inja::json architectures = inja::json::array();
                for (const auto &arch : mentry.archs) {
                    architectures.push_back(inja::json{
                        {"arch", arch}
                    });
                }
                cpt["architectures"] = architectures;
                cpt["metadata"] = Utils::escapeXml(
                    mentry.data); // FIXME: Set html-autoescape in Inja once we can depend on a newer version, and don't
                                  // use explicit escapeXml() here

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
                components.push_back(inja::json{
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

    float percOne = 100.0f
                    / static_cast<float>(dsum.totalMetadata + dsum.totalInfos + dsum.totalWarnings + dsum.totalErrors);
    secIndexCtx["valid_percentage"] = dsum.totalMetadata * percOne;
    secIndexCtx["info_percentage"] = dsum.totalInfos * percOne;
    secIndexCtx["warning_percentage"] = dsum.totalWarnings * percOne;
    secIndexCtx["error_percentage"] = dsum.totalErrors * percOne;

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

    logInfo("Collecting data about hints and available metainfo for {}/{}", suiteName, section);

    auto dtype = m_conf->metadataType;
    g_autoptr(AsMetadata) mdata = as_metadata_new();
    as_metadata_set_format_style(mdata, AS_FORMAT_STYLE_CATALOG);
    as_metadata_set_format_version(mdata, m_conf->formatVersion);

    for (const auto &pkg : pkgs) {
        const auto pkid = pkg->id();

        auto gcids = m_dstore->getGCIDsForPackage(pkid);
        auto hintsData = m_dstore->getHints(pkid);
        if (gcids.empty() && hintsData.empty())
            continue;

        PkgSummary pkgsummary;
        bool newInfo = false;

        pkgsummary.pkgname = pkg->name();

        auto maintainerIt = dsum.pkgSummaries.find(pkg->maintainer());
        if (maintainerIt != dsum.pkgSummaries.end()) {
            auto pkgIt = maintainerIt->second.find(pkg->name());
            if (pkgIt != maintainerIt->second.end()) {
                pkgsummary = pkgIt->second;
            } else {
                newInfo = true;
            }
        }

        // process component metadata for this package if there are any
        if (!gcids.empty()) {
            for (const auto &gcid : gcids) {
                auto cidOpt = Utils::getCidFromGlobalID(gcid);
                if (!cidOpt.has_value())
                    continue;

                auto cid = cidOpt.value();

                // don't add the same entry multiple times for multiple versions
                auto pkgIt = dsum.mdataEntries.find(pkg->name());
                if (pkgIt != dsum.mdataEntries.end()) {
                    auto verIt = pkgIt->second.find(pkg->ver());
                    if (verIt != pkgIt->second.end()) {
                        auto meIt = verIt->second.find(gcid);
                        if (meIt == verIt->second.end()) {
                            // this component is new
                            dsum.totalMetadata += 1;
                            newInfo = true;
                        } else {
                            // we already have a component with this gcid
                            auto &archs = meIt->second.archs;
                            if (std::find(archs.begin(), archs.end(), pkg->arch()) == archs.end()) {
                                archs.push_back(pkg->arch());
                            }
                            continue;
                        }
                    }
                } else {
                    // we will add a new component
                    dsum.totalMetadata += 1;
                }

                MetadataEntry me;
                me.identifier = cid;
                me.data = m_dstore->getMetadata(dtype, gcid);

                as_metadata_clear_components(mdata);
                g_autoptr(GError) error = nullptr;
                if (dtype == DataType::YAML)
                    as_metadata_parse_data(mdata, me.data.c_str(), -1, AS_FORMAT_KIND_YAML, &error);
                else
                    as_metadata_parse_data(mdata, me.data.c_str(), -1, AS_FORMAT_KIND_XML, &error);

                if (error != nullptr) {
                    logWarning("Failed to parse metadata for {}: {}", gcid, error->message);
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
                dsum.mdataEntries[pkg->name()][pkg->ver()][gcid] = me;
                pkgsummary.cpts.push_back(std::format("{} - {}", cid, pkg->ver()));
            }
        }

        // process hints for this package, if there are any
        if (!hintsData.empty()) {
            try {
                auto hintsJson = inja::json::parse(hintsData);

                if (!hintsJson.contains("hints") || !hintsJson["hints"].is_object())
                    continue;

                auto hintsNode = hintsJson["hints"];

                // Iterate through component IDs in hints
                for (const auto &[cid, jhintsNode] : hintsNode.items()) {
                    HintEntry he;

                    // don't add the same hints multiple times for multiple versions and architectures
                    auto pkgIt = dsum.hintEntries.find(pkg->name());
                    if (pkgIt != dsum.hintEntries.end()) {
                        auto heIt = pkgIt->second.find(cid);
                        if (heIt != pkgIt->second.end()) {
                            he = heIt->second;
                            // we already have hints for this component ID
                            he.archs.push_back(pkg->arch());

                            // TODO: check if we have the same hints - if not, create a new entry.
                            continue;
                        }
                        newInfo = true;
                    } else {
                        newInfo = true;
                    }

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
                                logError(
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

                            // add the new hint to the right category
                            if (severity == AS_ISSUE_SEVERITY_INFO) {
                                he.infos.push_back(HintTag{tag, msg});
                                pkgsummary.infoCount++;
                            } else if (severity == AS_ISSUE_SEVERITY_WARNING) {
                                he.warnings.push_back(HintTag{tag, msg});
                                pkgsummary.warningCount++;
                            } else if (severity == AS_ISSUE_SEVERITY_PEDANTIC) {
                                // We ignore pedantic issues completely for now
                            } else {
                                he.errors.push_back(HintTag{tag, msg});
                                pkgsummary.errorCount++;
                            }
                        }
                    }

                    if (newInfo)
                        he.archs.push_back(pkg->arch());

                    dsum.hintEntries[pkg->name()][he.identifier] = he;
                }
            } catch (const std::exception &e) {
                logError("Failed to parse hints JSON for package {}: {}", pkid, e.what());
            }
        }

        dsum.pkgSummaries[pkg->maintainer()][pkg->name()] = pkgsummary;
        if (newInfo) {
            dsum.totalInfos += pkgsummary.infoCount;
            dsum.totalWarnings += pkgsummary.warningCount;
            dsum.totalErrors += pkgsummary.errorCount;
        }
    }

    return dsum;
}

void ReportGenerator::saveStatistics(const std::string &suiteName, const std::string &section, const DataSummary &dsum)
{
    std::unordered_map<std::string, std::variant<std::int64_t, std::string, double>> statsData = {
        {"suite",         suiteName         },
        {"section",       section           },
        {"totalInfos",    dsum.totalInfos   },
        {"totalWarnings", dsum.totalWarnings},
        {"totalErrors",   dsum.totalErrors  },
        {"totalMetadata", dsum.totalMetadata}
    };

    m_dstore->addStatistics(statsData);
}

void ReportGenerator::exportStatistics()
{
    logInfo("Exporting statistical data.");

    // return all statistics we have from the database
    auto statsCollection = m_dstore->getStatistics();

    // Sort statsCollection by timestamp in ascending order
    std::sort(statsCollection.begin(), statsCollection.end(), [](const auto &a, const auto &b) -> bool {
        return a.time < b.time;
    });

    std::unordered_map<std::string, std::unordered_map<std::string, std::vector<std::array<int64_t, 2>>>> suiteData;

    // Group data by suite and section
    for (const auto &entry : statsCollection) {
        const auto &js = entry.data;
        const auto timestamp = static_cast<int64_t>(entry.time);

        // Extract suite and section from the data
        std::string suite, section;
        int64_t totalErrors = 0, totalWarnings = 0, totalInfos = 0, totalMetadata = 0;

        auto suiteIt = js.find("suite");
        if (suiteIt != js.end() && std::holds_alternative<std::string>(suiteIt->second))
            suite = std::get<std::string>(suiteIt->second);

        auto sectionIt = js.find("section");
        if (sectionIt != js.end() && std::holds_alternative<std::string>(sectionIt->second))
            section = std::get<std::string>(sectionIt->second);

        auto errorsIt = js.find("totalErrors");
        if (errorsIt != js.end() && std::holds_alternative<std::int64_t>(errorsIt->second))
            totalErrors = std::get<std::int64_t>(errorsIt->second);

        auto warningsIt = js.find("totalWarnings");
        if (warningsIt != js.end() && std::holds_alternative<std::int64_t>(warningsIt->second))
            totalWarnings = std::get<std::int64_t>(warningsIt->second);

        auto infosIt = js.find("totalInfos");
        if (infosIt != js.end() && std::holds_alternative<std::int64_t>(infosIt->second))
            totalInfos = std::get<std::int64_t>(infosIt->second);

        auto metadataIt = js.find("totalMetadata");
        if (metadataIt != js.end() && std::holds_alternative<std::int64_t>(metadataIt->second))
            totalMetadata = std::get<std::int64_t>(metadataIt->second);

        if (suite.empty() || section.empty())
            continue;

        // Store data points
        suiteData[suite][section + "_errors"].push_back({timestamp, totalErrors});
        suiteData[suite][section + "_warnings"].push_back({timestamp, totalWarnings});
        suiteData[suite][section + "_infos"].push_back({timestamp, totalInfos});
        suiteData[suite][section + "_metadata"].push_back({timestamp, totalMetadata});
    }

    inja::json jsonOutput = inja::json::object();
    for (const auto &[suiteName, sections] : suiteData) {
        // Group by section
        std::unordered_map<std::string, std::unordered_map<std::string, std::vector<std::array<int64_t, 2>>>>
            sectionGroups;
        for (const auto &[key, data] : sections) {
            auto underscorePos = key.rfind('_');
            if (underscorePos != std::string::npos) {
                std::string sectionName = key.substr(0, underscorePos);
                std::string dataType = key.substr(underscorePos + 1);
                sectionGroups[sectionName][dataType] = data;
            }
        }

        inja::json suiteJson = inja::json::object();
        for (const auto &[sectionName, dataTypes] : sectionGroups) {
            inja::json sectionJson = inja::json::object();
            for (const auto &[dataType, dataPoints] : dataTypes) {
                inja::json dataArray = inja::json::array();
                for (const auto &point : dataPoints) {
                    dataArray.push_back(inja::json::array({point[0], point[1]}));
                }
                sectionJson[dataType] = dataArray;
            }
            suiteJson[sectionName] = sectionJson;
        }
        jsonOutput[suiteName] = suiteJson;
    }

    auto fname = fs::path(m_htmlExportDir) / "statistics.json";
    fs::create_directories(fname.parent_path());

    std::ofstream sf(fname);
    // Use dump() without indentation for compact output
    sf << jsonOutput.dump();
    sf.flush();
    sf.close();
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

void ReportGenerator::updateIndexPages()
{
    logInfo("Updating HTML index pages and static data.");

    // render main overview
    inja::json context;

    // Get sorted suites
    auto suites = m_conf->suites;
    std::sort(suites.begin(), suites.end(), [](const Suite &a, const Suite &b) {
        return a.name > b.name;
    });

    inja::json suitesArray = inja::json::array();
    for (const auto &suite : suites) {
        suitesArray.push_back(inja::json{
            {"suite", suite.name}
        });

        inja::json secCtx;
        secCtx["suite"] = suite.name;

        inja::json sectionsArray = inja::json::array();
        for (const auto &section : suite.sections) {
            sectionsArray.push_back(inja::json{
                {"section", section}
            });
        }
        secCtx["sections"] = sectionsArray;

        renderPage("sections_index", std::format("{}/index", suite.name), secCtx);
    }
    context["suites"] = suitesArray;

    // Get sorted old suites
    auto oldsuites = m_conf->oldsuites;
    std::sort(oldsuites.begin(), oldsuites.end());

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

        Utils::copyDir(staticSrcDir, staticDestDir);
    }
}

} // namespace ASGenerator
