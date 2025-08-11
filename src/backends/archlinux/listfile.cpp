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

#include "listfile.h"

#include "../../utils.h"

namespace ASGenerator
{

ListFile::ListFile() {}

void ListFile::loadData(const std::vector<std::uint8_t> &data)
{
    std::string dataStr(data.begin(), data.end());
    auto content = splitString(dataStr, '\n');

    std::string blockName;
    for (const auto &line : content) {
        if (line.starts_with("%") && line.ends_with("%")) {
            blockName = line.substr(1, line.length() - 2);
            continue;
        }

        if (line.empty()) {
            blockName.clear();
            continue;
        }

        if (!blockName.empty()) {
            auto it = m_entries.find(blockName);
            if (it != m_entries.end()) {
                it->second += "\n" + line;
            } else {
                m_entries[blockName] = line;
            }
        }
    }
}

std::string ListFile::getEntry(const std::string &name)
{
    auto it = m_entries.find(name);
    if (it != m_entries.end())
        return it->second;

    return {};
}

} // namespace ASGenerator
