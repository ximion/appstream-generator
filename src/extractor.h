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

#include <memory>
#include <appstream-compose.h>
#include <glib.h>

#include "config.h"
#include "datastore.h"
#include "iconhandler.h"
#include "result.h"
#include "backends/interfaces.h"
#include "cptmodifiers.h"
#include "dataunits.h"

namespace ASGenerator
{

/**
 * Class for extracting AppStream metadata from packages.
 */
class DataExtractor
{
public:
    DataExtractor(
        std::shared_ptr<DataStore> db,
        std::shared_ptr<IconHandler> iconHandler,
        AsgLocaleUnit *localeUnit,
        std::shared_ptr<InjectedModifications> modInjInfo = nullptr);
    ~DataExtractor();

    /**
     * Process a package and extract AppStream metadata from it.
     *
     * @param pkg The package to process
     * @return GeneratorResult containing the extraction results
     */
    GeneratorResult processPackage(std::shared_ptr<Package> pkg);

    // Delete copy constructor and assignment operator
    DataExtractor(const DataExtractor &) = delete;
    DataExtractor &operator=(const DataExtractor &) = delete;

private:
    Config *m_conf;
    AscCompose *m_compose;
    DataType m_dtype;
    std::shared_ptr<DataStore> m_dstore;
    std::shared_ptr<IconHandler> m_iconh;
    std::shared_ptr<InjectedModifications> m_modInj;
    AsgLocaleUnit *m_l10nUnit;

    /**
     * Helper function for early asgen-specific metadata manipulation.
     * This is a C callback function used by AppStream Compose.
     */
    static void checkMetadataIntermediate(AscResult *cres, const AscUnit *cunit, void *userData);

    /**
     * Helper function for translating desktop file text.
     * This is a C callback function for desktop entry translation.
     */
    static GPtrArray *translateDesktopTextCallback(const GKeyFile *dePtr, const char *text, void *userData);
};

} // namespace ASGenerator
