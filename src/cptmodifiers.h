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

#pragma once

#include <string>
#include <unordered_map>
#include <optional>
#include <shared_mutex>
#include <appstream.h>

#include "config.h"

namespace ASGenerator
{

class GeneratorResult;

/**
 * Helper class to provide information about repository-specific metadata modifications.
 * Instances of this class must be thread safe.
 */
class InjectedModifications
{
public:
    InjectedModifications();
    ~InjectedModifications();

    void loadForSuite(std::shared_ptr<Suite> suite);

    bool hasRemovedComponents() const;

    /**
     * Test if component was marked for deletion.
     */
    bool isComponentRemoved(const std::string &cid) const;

    /**
     * Get injected custom data entries.
     */
    std::optional<std::unordered_map<std::string, std::string>> injectedCustomData(const std::string &cid) const;

    void addRemovalRequestsToResult(GeneratorResult *gres) const;

    // Delete copy constructor and assignment operator
    InjectedModifications(const InjectedModifications &) = delete;
    InjectedModifications &operator=(const InjectedModifications &) = delete;

private:
    std::unordered_map<std::string, AsComponent *> m_removedComponents;
    std::unordered_map<std::string, std::unordered_map<std::string, std::string>> m_injectedCustomData;

    bool m_hasRemovedCpts;
    bool m_hasInjectedCustom;

    mutable std::shared_mutex m_mutex;
};

} // namespace ASGenerator
