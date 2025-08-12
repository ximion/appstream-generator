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
#include <string_view>
#include <format>

namespace ASGenerator
{

enum class LogSeverity {
    DEBUG,
    INFO,
    WARNING,
    ERROR
};

void setVerbose(bool verbose) noexcept;
bool isVerbose() noexcept;

constexpr std::string_view logSeverityToString(LogSeverity severity) noexcept;

// Base logging function that handles the actual output
void logMessageImpl(LogSeverity severity, const std::string &message);

template<typename... Args>
void logMessage(LogSeverity severity, std::string_view fmt, Args &&...args)
{
    std::string formatted_msg;
    if constexpr (sizeof...(Args) > 0)
        formatted_msg = std::vformat(fmt, std::make_format_args(args...));
    else
        formatted_msg = std::string{fmt};
    logMessageImpl(severity, formatted_msg);
}

template<typename... Args>
inline void logDebug(std::string_view fmt, Args &&...args)
{
    if (isVerbose())
        logMessage(LogSeverity::DEBUG, fmt, std::forward<Args>(args)...);
}

template<typename... Args>
inline void logInfo(std::string_view fmt, Args &&...args)
{
    logMessage(LogSeverity::INFO, fmt, std::forward<Args>(args)...);
}

template<typename... Args>
inline void logWarning(std::string_view fmt, Args &&...args)
{
    logMessage(LogSeverity::WARNING, fmt, std::forward<Args>(args)...);
}

template<typename... Args>
inline void logError(std::string_view fmt, Args &&...args)
{
    logMessage(LogSeverity::ERROR, fmt, std::forward<Args>(args)...);
}

// Convenience overloads for simple string messages (no template arguments)
inline void logDebug(std::string_view msg)
{
    if (isVerbose())
        logMessageImpl(LogSeverity::DEBUG, std::string{msg});
}

inline void logInfo(std::string_view msg)
{
    logMessageImpl(LogSeverity::INFO, std::string{msg});
}

inline void logWarning(std::string_view msg)
{
    logMessageImpl(LogSeverity::WARNING, std::string{msg});
}

inline void logError(std::string_view msg)
{
    logMessageImpl(LogSeverity::ERROR, std::string{msg});
}

} // namespace ASGenerator
