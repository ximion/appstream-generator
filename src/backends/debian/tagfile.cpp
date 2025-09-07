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

#include "tagfile.h"

#include <fstream>
#include <sstream>
#include <algorithm>
#include <format>

#include "../../logging.h"
#include "../../zarchive.h"
#include "../../utils.h"

namespace ASGenerator
{

TagFile::TagFile()
    : m_pos(0)
{
    m_currentBlock.clear();
}

void TagFile::open(const std::string &fname, bool compressed)
{
    m_fname = fname;

    if (compressed) {
        auto data = decompressFile(fname);
        load(data);
    } else {
        std::ifstream file(fname);
        if (!file.is_open())
            throw std::runtime_error(std::format("Could not open file: {}", fname));

        std::ostringstream buffer;
        buffer << file.rdbuf();
        load(buffer.str());
    }
}

void TagFile::load(const std::string &data)
{
    m_content = Utils::splitString(data, '\n');
    m_pos = 0;
    readCurrentBlockData();
}

void TagFile::first()
{
    m_pos = 0;
    readCurrentBlockData();
}

void TagFile::readCurrentBlockData()
{
    m_currentBlock.clear();
    const auto clen = m_content.size();

    for (auto i = m_pos; i < clen; i++) {
        if (m_content[i].empty())
            break;

        // check whether we are in a multiline value field, and just skip forward in that case
        if (m_content[i].starts_with(" "))
            continue;

        const auto separatorIndex = m_content[i].find(':');
        if (separatorIndex == std::string::npos || separatorIndex == 0)
            continue;

        auto fieldName = m_content[i].substr(0, separatorIndex);
        auto fieldData = m_content[i].substr(separatorIndex + 1);

        // remove whitespace
        fieldData = Utils::trimString(fieldData);

        // check if we have a multiline field
        for (auto j = i + 1; j < clen; j++) {
            if (m_content[j].empty())
                break;
            if (!m_content[j].starts_with(" "))
                break;

            // we have a multiline field
            auto data = m_content[j].substr(1); // remove the leading space
            if (data == ".")
                fieldData += "\n"; // just a dot means empty line
            else
                fieldData += "\n" + data;
            i = j; // skip forward
        }

        m_currentBlock[fieldName] = std::move(fieldData);
    }
}

bool TagFile::nextSection()
{
    const auto clen = m_content.size();

    // find next section
    auto i = m_pos;
    for (; i < clen; i++) {
        if (m_content[i].empty()) {
            i++;
            break;
        }
    }

    if (i >= clen)
        return false;

    m_pos = i;
    readCurrentBlockData();
    return !m_currentBlock.empty();
}

bool TagFile::eof() const
{
    return m_pos >= m_content.size();
}

std::string TagFile::readField(const std::string &fieldName, const std::string &defaultValue) const
{
    const auto it = m_currentBlock.find(fieldName);
    if (it != m_currentBlock.end())
        return it->second;
    return defaultValue;
}

bool TagFile::hasField(const std::string &fieldName) const
{
    return m_currentBlock.find(fieldName) != m_currentBlock.end();
}

} // namespace ASGenerator
