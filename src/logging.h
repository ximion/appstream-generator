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
#include <format>
#include <chrono>
#include <mutex>
#include <iostream>

namespace ASGenerator
{

enum class LogSeverity {
    DEBUG,
    INFO,
    WARNING,
    ERROR
};

void setVerbose(bool verbose);
bool isVerbose();

std::string logSeverityToString(LogSeverity severity);

template<typename... Args>
void logMessage(LogSeverity severity, const std::string &tmpl, Args &&...args)
{
    using namespace std::chrono;
    auto now = system_clock::now();
    auto t = system_clock::to_time_t(now);
    std::tm tm = *std::localtime(&t);
    std::ostringstream timeStr;
    timeStr << std::put_time(&tm, "%Y-%m-%d %H:%M:%S");
    std::string formatted = std::vformat(tmpl, std::make_format_args(args...));
    std::cout << timeStr.str() << " - " << logSeverityToString(severity) << ": " << formatted << std::endl;
}

inline void logDebug(const std::string &tmpl)
{
    if (isVerbose())
        logMessage(LogSeverity::DEBUG, tmpl);
}

template<typename... Args>
inline void logDebug(const std::string &tmpl, Args &&...args)
{
    if (isVerbose())
        logMessage(LogSeverity::DEBUG, tmpl, std::forward<Args>(args)...);
}

inline void logInfo(const std::string &tmpl)
{
    logMessage(LogSeverity::INFO, tmpl);
}

template<typename... Args>
inline void logInfo(const std::string &tmpl, Args &&...args)
{
    logMessage(LogSeverity::INFO, tmpl, std::forward<Args>(args)...);
}

inline void logWarning(const std::string &tmpl)
{
    logMessage(LogSeverity::WARNING, tmpl);
}

template<typename... Args>
inline void logWarning(const std::string &tmpl, Args &&...args)
{
    logMessage(LogSeverity::WARNING, tmpl, std::forward<Args>(args)...);
}

inline void logError(const std::string &tmpl)
{
    logMessage(LogSeverity::ERROR, tmpl);
}

template<typename... Args>
inline void logError(const std::string &tmpl, Args &&...args)
{
    logMessage(LogSeverity::ERROR, tmpl, std::forward<Args>(args)...);
}

} // namespace ASGenerator
