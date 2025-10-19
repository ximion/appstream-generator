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

#include "interfaces.h"

#include <format>
#include <algorithm>

namespace ASGenerator
{

// GStreamer implementation
GStreamer::GStreamer()
    : m_decoders(),
      m_encoders(),
      m_elements(),
      m_uriSinks(),
      m_uriSources()
{
}

GStreamer::GStreamer(
    const std::vector<std::string> &decoders,
    const std::vector<std::string> &encoders,
    const std::vector<std::string> &elements,
    const std::vector<std::string> &uriSinks,
    const std::vector<std::string> &uriSources)
    : m_decoders(decoders),
      m_encoders(encoders),
      m_elements(elements),
      m_uriSinks(uriSinks),
      m_uriSources(uriSources)
{
}

bool GStreamer::isNotEmpty() const noexcept
{
    return !(
        m_decoders.empty() && m_encoders.empty() && m_elements.empty() && m_uriSinks.empty() && m_uriSources.empty());
}

PackageKind Package::kind() const noexcept
{
    return PackageKind::Physical;
}

const std::unordered_map<std::string, std::string> &Package::summary() const
{
    static const std::unordered_map<std::string, std::string> empty_map;
    return empty_map;
}

std::optional<GStreamer> Package::gst() const
{
    return std::nullopt;
}

std::unordered_map<std::string, std::string> Package::getDesktopFileTranslations(
    GKeyFile *desktopFile,
    const std::string &text)
{
    return {};
}

bool Package::hasDesktopFileTranslations() const
{
    return false;
}

// Package implementation
const std::string &Package::id() const
{
    if (m_pkid.empty())
        m_pkid = std::format("{}/{}/{}", name(), ver(), arch());

    return m_pkid;
}

bool Package::isValid() const
{
    return !name().empty() && !ver().empty() && !arch().empty();
}

std::string Package::toString() const
{
    return id();
}

std::string PackageIndex::dataPrefix() const
{
    return "/usr";
}

} // namespace ASGenerator
