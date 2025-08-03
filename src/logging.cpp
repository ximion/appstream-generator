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

#include "logging.h"

#include <iomanip>
#include <sstream>
#include <atomic>

namespace ASGenerator
{

std::atomic_bool __verboseFlag{false};

void setVerbose(bool verbose)
{
    __verboseFlag.store(verbose);
}

bool isVerbose()
{
    return __verboseFlag.load();
}

std::string logSeverityToString(LogSeverity severity)
{
    switch (severity) {
    case LogSeverity::DEBUG:
        return "DEBUG";
    case LogSeverity::INFO:
        return "INFO";
    case LogSeverity::WARNING:
        return "WARNING";
    case LogSeverity::ERROR:
        return "ERROR";
    default:
        return "UNKNOWN";
    }
}

} // namespace ASGenerator
