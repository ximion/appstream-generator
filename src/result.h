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
#include <vector>
#include <unordered_map>
#include <memory>
#include <appstream.h>

#include "backends/interfaces.h"

typedef struct _AscResult AscResult;

namespace ASGenerator
{

/**
 * Represents the result of processing a package for AppStream metadata generation.
 * This class ties together a package instance and compose result.
 */
class GeneratorResult
{
public:
    /**
     * Constructor with package.
     */
    explicit GeneratorResult(std::shared_ptr<Package> pkg);

    /**
     * Constructor with result and package.
     */
    GeneratorResult(AscResult *result, std::shared_ptr<Package> pkg);

    /**
     * Destructor.
     */
    ~GeneratorResult();

    // Delete copy constructor and assignment operator
    GeneratorResult(const GeneratorResult &) = delete;
    GeneratorResult &operator=(const GeneratorResult &) = delete;

    // Move constructor and assignment operator
    GeneratorResult(GeneratorResult &&other) noexcept;
    GeneratorResult &operator=(GeneratorResult &&other) noexcept;

    /**
     * Get the package ID.
     */
    std::string pkid() const;

    /**
     * Get the package instance.
     */
    std::shared_ptr<Package> getPackage() const
    {
        return m_pkg;
    }

    /**
     * Get the AscResult instance.
     */
    AscResult *getResult() const
    {
        return m_res;
    }

    /**
     * Add an issue hint to this result.
     * @param id The component-id or component itself this tag is assigned to.
     * @param tag The hint tag.
     * @param vars Dictionary of parameters to insert into the issue report.
     * @return True if the hint did not cause the removal of the component, False otherwise.
     */
    bool addHint(
        const std::string &id,
        const std::string &tag,
        const std::unordered_map<std::string, std::string> &vars = {});

    /**
     * Add an issue hint to this result.
     * @param cpt The component this tag is assigned to.
     * @param tag The hint tag.
     * @param vars Dictionary of parameters to insert into the issue report.
     * @return True if the hint did not cause the removal of the component, False otherwise.
     */
    bool addHint(
        AsComponent *cpt,
        const std::string &tag,
        const std::unordered_map<std::string, std::string> &vars = {});

    /**
     * Add an issue hint to this result with a simple message.
     * @param id The component-id or component itself this tag is assigned to.
     * @param tag The hint tag.
     * @param msg An error message to add to the report.
     * @return True if the hint did not cause the removal of the component, False otherwise.
     */
    bool addHint(const std::string &id, const std::string &tag, const std::string &msg);

    /**
     * Add an issue hint to this result with a simple message.
     * @param cpt The component this tag is assigned to.
     * @param tag The hint tag.
     * @param msg An error message to add to the report.
     * @return True if the hint did not cause the removal of the component, False otherwise.
     */
    bool addHint(AsComponent *cpt, const std::string &tag, const std::string &msg);

    /**
     * Create JSON metadata for the hints found for the package
     * associated with this GeneratorResult.
     */
    std::string hintsToJson() const;

    // Delegate methods to AscResult
    std::uint32_t hintsCount() const;
    std::uint32_t componentsCount() const;
    std::vector<std::string> getComponentIdsWithHints() const;
    bool hasHint(const std::string &componentId, const std::string &tag) const;
    bool hasHint(AsComponent *cpt, const std::string &tag) const;
    void addComponent(AsComponent *cpt) const;
    void removeComponent(AsComponent *cpt) const;
    bool isIgnored(AsComponent *cpt) const;
    std::string gcidForComponent(AsComponent *cpt) const;
    std::vector<std::string> getComponentGcids() const;

private:
    std::shared_ptr<Package> m_pkg;
    AscResult *m_res;
};

} // namespace ASGenerator
