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

#include "extractor.h"

#include <format>
#include <string_view>
#include <algorithm>
#include <sstream>
#include <appstream.h>
#include <appstream-compose.h>
#include <glib.h>

#include "config.h"
#include "logging.h"
#include "hintregistry.h"
#include "result.h"
#include "backends/interfaces.h"
#include "datastore.h"
#include "iconhandler.h"
#include "utils.h"
#include "cptmodifiers.h"

namespace ASGenerator
{

DataExtractor::DataExtractor(
    std::shared_ptr<DataStore> db,
    std::shared_ptr<IconHandler> iconHandler,
    AsgLocaleUnit *localeUnit,
    std::shared_ptr<InjectedModifications> modInjInfo)
    : m_compose(nullptr),
      m_dstore(std::move(db)),
      m_iconh(std::move(iconHandler)),
      m_modInj(std::move(modInjInfo)),
      m_l10nUnit(nullptr)
{
    m_conf = &Config::get();
    m_dtype = m_conf->metadataType;
    if (localeUnit != nullptr)
        m_l10nUnit = g_object_ref(localeUnit);

    m_compose = asc_compose_new();

    asc_compose_set_media_result_dir(m_compose, m_dstore->mediaExportPoolDir().string().c_str());
    asc_compose_set_media_baseurl(m_compose, "");

    // Set callback for intermediate metadata checking
    asc_compose_set_check_metadata_early_func(m_compose, &checkMetadataIntermediate, this);

    AscComposeFlags flags = static_cast<AscComposeFlags>(
        ASC_COMPOSE_FLAG_IGNORE_ICONS |             // we do custom icon processing
        ASC_COMPOSE_FLAG_PROCESS_UNPAIRED_DESKTOP | // handle desktop-entry files without metainfo data
        ASC_COMPOSE_FLAG_NO_FINAL_CHECK);           // we trigger the final check manually
    asc_compose_add_flags(m_compose, flags);

    // we handle all threading, so the compose process doesn't also have to be threaded
    asc_compose_remove_flags(m_compose, ASC_COMPOSE_FLAG_USE_THREADS);

    // set CAInfo for any download operations performed by this AscCompose
    if (!m_conf->caInfo.empty())
        asc_compose_set_cainfo(m_compose, m_conf->caInfo.c_str());

    // set dummy locale unit for advanced locale processing
    if (m_l10nUnit)
        asc_compose_set_locale_unit(m_compose, ASC_UNIT(m_l10nUnit));

    // set max screenshot size in bytes, if size is limited
    if (m_conf->maxScrFileSize != 0) {
        auto maxSize = static_cast<gssize>(m_conf->maxScrFileSize * 1024 * 1024);
        asc_compose_set_max_screenshot_size(m_compose, maxSize);
    }

    // enable or disable user-defined features
    if (m_conf->feature.validate)
        asc_compose_add_flags(m_compose, ASC_COMPOSE_FLAG_VALIDATE);
    else
        asc_compose_remove_flags(m_compose, ASC_COMPOSE_FLAG_VALIDATE);

    if (m_conf->feature.noDownloads)
        asc_compose_remove_flags(m_compose, ASC_COMPOSE_FLAG_ALLOW_NET);
    else
        asc_compose_add_flags(m_compose, ASC_COMPOSE_FLAG_ALLOW_NET);

    if (m_conf->feature.processLocale)
        asc_compose_add_flags(m_compose, ASC_COMPOSE_FLAG_PROCESS_TRANSLATIONS);
    else
        asc_compose_remove_flags(m_compose, ASC_COMPOSE_FLAG_PROCESS_TRANSLATIONS);

    if (m_conf->feature.processFonts)
        asc_compose_add_flags(m_compose, ASC_COMPOSE_FLAG_PROCESS_FONTS);
    else
        asc_compose_remove_flags(m_compose, ASC_COMPOSE_FLAG_PROCESS_FONTS);

    if (m_conf->feature.storeScreenshots)
        asc_compose_add_flags(m_compose, ASC_COMPOSE_FLAG_STORE_SCREENSHOTS);
    else
        asc_compose_remove_flags(m_compose, ASC_COMPOSE_FLAG_STORE_SCREENSHOTS);

    if (m_conf->feature.screenshotVideos)
        asc_compose_add_flags(m_compose, ASC_COMPOSE_FLAG_ALLOW_SCREENCASTS);
    else
        asc_compose_remove_flags(m_compose, ASC_COMPOSE_FLAG_ALLOW_SCREENCASTS);

    if (m_conf->feature.propagateMetaInfoArtifacts)
        asc_compose_add_flags(m_compose, ASC_COMPOSE_FLAG_PROPAGATE_ARTIFACTS);
    else
        asc_compose_remove_flags(m_compose, ASC_COMPOSE_FLAG_PROPAGATE_ARTIFACTS);

    // override icon policy with our own, possible user-modified one
    asc_compose_set_icon_policy(m_compose, m_conf->iconPolicy());

    // register allowed custom keys with the composer
    if (!m_conf->allowedCustomKeys.empty()) {
        asc_compose_add_flags(m_compose, ASC_COMPOSE_FLAG_PROPAGATE_CUSTOM);
        for (const auto &[key, _] : m_conf->allowedCustomKeys)
            asc_compose_add_custom_allowed(m_compose, key.c_str());
    } else {
        asc_compose_remove_flags(m_compose, ASC_COMPOSE_FLAG_PROPAGATE_CUSTOM);
    }
}

DataExtractor::~DataExtractor()
{
    g_object_unref(m_compose);
    if (m_l10nUnit)
        g_object_unref(m_l10nUnit);
}

void DataExtractor::checkMetadataIntermediate(AscResult *cres, const AscUnit *cunit, void *userData)
{
    auto self = static_cast<DataExtractor *>(userData);

    auto cptsPtrArray = asc_result_fetch_components(cres);
    for (guint i = 0; i < cptsPtrArray->len; i++) {
        auto cpt = AS_COMPONENT(g_ptr_array_index(cptsPtrArray, i));
        auto gcid = asc_result_gcid_for_component(cres, cpt);

        // don't run expensive operations later if the metadata already exists
        auto existingMData = self->m_dstore->getMetadata(self->m_dtype, gcid);

        // skip if no existing metadata is present
        if (existingMData.empty())
            continue;

        const auto bundleId = asc_result_get_bundle_id(cres);
        if (bundleId && std::string(bundleId) == EXTRA_METAINFO_FAKE_PKGNAME) {
            // the "package" was injected and therefore has likely already been unlinked
            // and we will want to reprocess it unconditionally. Therefore, we just skip
            // all following checks on same-package and duplicate IDs and just continue
            // processing the metadata without modifications.
            continue;
        }

        // To account for packages which change their package name, we
        // also need to check if the package this component is associated
        // with matches ours.
        // If it doesn't, we can't just link the package to the component.
        bool samePkg = false;
        if (self->m_dtype == DataType::YAML) {
            if (existingMData.find(std::format("Package: {}\n", bundleId)) != std::string::npos)
                samePkg = true;
        } else {
            if (existingMData.find(std::format("<pkgname>{}</pkgname>", bundleId)) != std::string::npos)
                samePkg = true;
        }

        if ((!samePkg) && (as_component_get_kind(cpt) != AS_COMPONENT_KIND_WEB_APP)) {
            // The exact same metadata exists in a different package already, we emit an error hint.
            // ATTENTION: This does not cover the case where *different* metadata (as in, different summary etc.)
            // but with the *same ID* exists.
            // We only catch that kind of problem later.

            g_autoptr(AsMetadata) cdata = as_metadata_new();
            as_metadata_set_format_style(cdata, AS_FORMAT_STYLE_CATALOG);
            as_metadata_set_format_version(cdata, self->m_conf->formatVersion);

            g_autoptr(GError) error = nullptr;
            if (self->m_dtype == DataType::YAML)
                as_metadata_parse_data(cdata, existingMData.c_str(), -1, AS_FORMAT_KIND_YAML, &error);
            else
                as_metadata_parse_data(cdata, existingMData.c_str(), -1, AS_FORMAT_KIND_XML, &error);

            if (error)
                throw std::runtime_error(
                    std::format("Failed to parse existing metadata for duplicate check: {}", error->message));

            auto ecpt = as_metadata_get_component(cdata);
            if (!ecpt)
                continue;

            auto pkgNames = as_component_get_pkgnames(ecpt);
            std::string pkgName = "(none)";
            if (pkgNames && pkgNames[0])
                pkgName = pkgNames[0];

            asc_result_add_hint(
                cres,
                cpt,
                "metainfo-duplicate-id",
                "cid",
                as_component_get_id(cpt),
                "pkgname",
                pkgName.c_str(),
                nullptr);
        }

        // drop the component as we already have processed it, but keep its
        // global ID so we can still register the ID with this package.
        asc_result_remove_component_full(cres, cpt, FALSE);
    }
}

GPtrArray *DataExtractor::translateDesktopTextCallback(GKeyFile *dePtr, const char *text, void *userData)
{
    auto pkg = *static_cast<Package **>(userData);
    auto res = g_ptr_array_new_with_free_func(g_free);

    auto translations = pkg->getDesktopFileTranslations(dePtr, std::string(text));
    for (const auto &[key, value] : translations) {
        g_ptr_array_add(res, g_strdup(key.c_str()));
        g_ptr_array_add(res, g_strdup(value.c_str()));
    }

    return res;
}

GeneratorResult DataExtractor::processPackage(std::shared_ptr<Package> pkg)
{
    // reset compose instance to clear data from any previous invocation
    asc_compose_reset(m_compose);

    // set external desktop-entry translation function, if needed
    const bool externalL10n = pkg->hasDesktopFileTranslations();
    Package *pkgPtr = pkg.get();
    asc_compose_set_desktop_entry_l10n_func(
        m_compose, externalL10n ? &translateDesktopTextCallback : nullptr, externalL10n ? &pkgPtr : nullptr);

    // wrap package into unit, so AppStream Compose can work with it
    auto unit = asg_package_unit_new(pkg);
    asc_compose_add_unit(m_compose, ASC_UNIT(unit));

    // process all data
    g_autoptr(GError) error = nullptr;
    if (!asc_compose_run(m_compose, nullptr, &error))
        throw std::runtime_error(
            std::format("Failed to run compose process: {}", error ? error->message : "Unknown error"));

    auto resultsArray = asc_compose_get_results(m_compose);

    // we processed one unit, so should always generate one result
    if (resultsArray->len != 1)
        throw std::runtime_error(
            std::format("Expected 1 result for data extraction, but retrieved {}.", resultsArray->len));

    // create result wrapper
    auto ascResult = ASC_RESULT(g_ptr_array_index(resultsArray, 0));
    GeneratorResult gres(ascResult, pkg);

    // process icons and perform additional refinements
    g_autoptr(GPtrArray) cptsPtrArray = gres.fetchComponents();
    for (guint i = 0; i < cptsPtrArray->len; i++) {
        auto cpt = AS_COMPONENT(g_ptr_array_index(cptsPtrArray, i));
        const auto ckind = as_component_get_kind(cpt);

        auto context = as_component_get_context(cpt);
        if (!context) {
            context = as_context_new();
            as_component_set_context(cpt, context);
        }

        // find & store icons
        m_iconh->process(gres, cpt);
        if (gres.isIgnored(cpt))
            continue;

        // add fallback long descriptions only for desktop apps, console apps and web apps
        if (as_component_get_merge_kind(cpt) != AS_MERGE_KIND_NONE)
            continue;
        if (ckind != AS_COMPONENT_KIND_DESKTOP_APP && ckind != AS_COMPONENT_KIND_CONSOLE_APP
            && ckind != AS_COMPONENT_KIND_WEB_APP)
            continue;

        // inject package descriptions, if needed
        auto valueFlags = as_context_get_value_flags(context);
        valueFlags = static_cast<AsValueFlags>(valueFlags | AS_VALUE_FLAG_NO_TRANSLATION_FALLBACK);
        as_context_set_value_flags(context, valueFlags);
        as_context_set_locale(context, "C");
        const auto cptDesc = as_component_get_description(cpt);
        if (cptDesc != nullptr && cptDesc[0] != '\0')
            continue;

        // component doesn't have a long description, add one from the packaging.
        bool desc_added = false;
        for (const auto &[lang, desc] : pkg->description()) {
            as_component_set_description(cpt, desc.c_str(), lang.c_str());
            desc_added = true;
        }

        if (desc_added) {
            // we only add the "description-from-package" tag if we haven't already
            // emitted a "no-metainfo" tag, to avoid two hints explaining the same thing
            if (!gres.hasHint(cpt, "no-metainfo")) {
                if (!gres.addHint(cpt, "description-from-package"))
                    continue;
            }
        } else {
            std::string kindStr = as_component_kind_to_string(ckind);
            if (!gres.addHint(
                    cpt,
                    "description-missing",
                    {
                        {"kind", kindStr}
            }))
                continue;
        }
    }

    // handle GStreamer integration (usually for Ubuntu)
    if (m_conf->feature.processGStreamer && pkg->gst().has_value() && pkg->gst()->isNotEmpty()) {
        std::ostringstream data;
        data.str().reserve(200);

        g_autoptr(AsComponent) cpt = as_component_new();
        as_component_set_id(cpt, pkg->name().c_str());
        as_component_set_kind(cpt, AS_COMPONENT_KIND_CODEC);
        as_component_set_name(cpt, "GStreamer Multimedia Codecs", "C");

        for (const auto &[lang, desc] : pkg->summary()) {
            as_component_set_summary(cpt, desc.c_str(), lang.c_str());
            data << desc;
        }

        gres.addComponentWithString(cpt, data.str());
    }

    // perform final checks
    asc_compose_finalize_results(m_compose);

    // do our own final validation
    g_ptr_array_unref(g_steal_pointer(&cptsPtrArray));
    cptsPtrArray = gres.fetchComponents();
    for (guint i = 0; i < cptsPtrArray->len; i++) {
        auto cpt = AS_COMPONENT(g_ptr_array_index(cptsPtrArray, i));
        const auto ckind = as_component_get_kind(cpt);
        const auto cid = as_component_get_id(cpt);

        if (m_modInj) {
            // drop component that the repository owner wants to remove
            if (m_modInj->isComponentRemoved(cid)) {
                gres.removeComponent(cpt);
                continue;
            }

            // inject custom fields from the repository owner, if we have any
            auto injectedCustom = m_modInj->injectedCustomData(cid);
            if (injectedCustom.has_value()) {
                for (const auto &[key, value] : injectedCustom.value())
                    as_component_insert_custom_value(cpt, key.c_str(), value.c_str());
            }
        }

        if (as_component_get_merge_kind(cpt) != AS_MERGE_KIND_NONE)
            continue;

        auto pkgnames = as_component_get_pkgnames(cpt);
        if (!pkgnames || !pkgnames[0]) {
            // no packages are associated with this component

            if (ckind != AS_COMPONENT_KIND_WEB_APP && ckind != AS_COMPONENT_KIND_OPERATING_SYSTEM
                && ckind != AS_COMPONENT_KIND_REPOSITORY) {
                // this component is not allowed to have no installation candidate
                if (!as_component_has_bundle(cpt)) {
                    if (!gres.addHint(cpt, "no-install-candidate"))
                        continue;
                }
            }
        } else {
            // packages are associated with this component

            if (pkg->kind() == PackageKind::Fake) {
                // drop any association with the dummy package
                std::vector<std::string> filteredPkgnames;
                for (int j = 0; pkgnames[j] != nullptr; j++) {
                    if (std::string(pkgnames[j]) != EXTRA_METAINFO_FAKE_PKGNAME)
                        filteredPkgnames.push_back(pkgnames[j]);
                }

                // We only keep the C++ vector for memory management purposes,
                // as calling as_component_set_pkgnames() will free the originally
                // referenced data.
                g_autoptr(GStrvBuilder) builder = g_strv_builder_new();
                for (const auto &pkgname : filteredPkgnames)
                    g_strv_builder_add(builder, pkgname.c_str());
                g_auto(GStrv) filteredArray = g_strv_builder_end(builder);
                as_component_set_pkgnames(cpt, filteredArray);
            }
        }
    }

    // clean up and return result
    pkg->finish();
    return gres;
}

} // namespace ASGenerator
