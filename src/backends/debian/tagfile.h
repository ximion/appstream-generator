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
#include <cstdint>

namespace ASGenerator
{

/**
 * Parser for Debian's RFC2822-style metadata.
 */
class TagFile
{
private:
    std::vector<std::string> m_content;
    std::size_t m_pos;
    std::unordered_map<std::string, std::string> m_currentBlock;
    std::string m_fname;

    void readCurrentBlockData();

public:
    TagFile();

    void open(const std::string &fname, bool compressed = true);

    const std::string &fname() const
    {
        return m_fname;
    }

    void load(const std::string &data);

    void first();

    bool nextSection();

    bool eof() const;

    std::string readField(const std::string &fieldName, const std::string &defaultValue = "") const;

    bool hasField(const std::string &fieldName) const;

    const std::unordered_map<std::string, std::string> &currentBlock() const
    {
        return m_currentBlock;
    }
};

} // namespace ASGenerator
