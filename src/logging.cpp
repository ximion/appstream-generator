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

#include <atomic>
#include <chrono>
#include <format>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <syncstream>

namespace ASGenerator
{

// helper to avoid the "static initialization order fiasco"
static std::atomic_bool &verboseFlag() noexcept
{
    static std::atomic_bool flag{false};
    return flag;
}

void setVerbose(bool verbose) noexcept
{
    verboseFlag().store(verbose, std::memory_order_relaxed);
}

bool isVerbose() noexcept
{
    return verboseFlag().load(std::memory_order_relaxed);
}

constexpr std::string_view logSeverityToString(LogSeverity severity) noexcept
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

void logMessageImpl(LogSeverity severity, const std::string &message)
{
    // Use synchronized output stream for thread safety
    std::osyncstream sync_out{std::cout};

    auto now = std::chrono::system_clock::now();
    auto time_t = std::chrono::system_clock::to_time_t(now);
    auto tm = *std::localtime(&time_t);

    std::ostringstream time_stream;
    time_stream << std::put_time(&tm, "%Y-%m-%d %H:%M:%S");

    sync_out << time_stream.str() << " - " << logSeverityToString(severity) << ": " << message << '\n';
}

static void printTextbox(
    std::string_view title,
    std::string_view tl,
    std::string_view hline,
    std::string_view tr,
    std::string_view vline,
    std::string_view bl,
    std::string_view br)
{
    const auto tlen = title.length();
    const auto hline_count = 10 + tlen;

    std::string output;
    output.reserve(128 + tlen + hline_count * hline.length() * 2); // Rough estimate

    // Top line
    output += '\n';
    output += tl;
    for (size_t i = 0; i < hline_count; ++i)
        output += hline;
    output += tr;
    output += '\n';

    // Middle line with title
    output += vline;
    output += "  ";
    output += title;
    output += std::string(8, ' ');
    output += vline;
    output += '\n';

    // Bottom line
    output += bl;
    for (size_t i = 0; i < hline_count; ++i)
        output += hline;
    output += br;
    output += '\n';

    std::cout.write(output.data(), output.size());
    std::cout.flush();
}

void printHeaderBox(std::string_view title)
{
    printTextbox(title, "╔", "═", "╗", "║", "╚", "╝");
}

void printSectionBox(std::string_view title)
{
    printTextbox(title, "┌", "─", "┐", "│", "└", "┘");
}

} // namespace ASGenerator
