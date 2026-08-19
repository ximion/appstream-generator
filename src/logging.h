/*
 * Copyright (C) 2016-2026 Matthias Klumpp <matthias@tenstral.net>
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

#include <quill/LogMacros.h>
#include <quill/Logger.h>

namespace ASGenerator
{

using QuillLogger = quill::Logger;

#define logRoot ::ASGenerator::getDefaultLogger()

quill::Logger *getLogger(const std::string &name);
quill::Logger *getLogger(const char *name);

/**
 * Retrieve the default ("root") logger.
 */
inline quill::Logger *getDefaultLogger()
{
    static quill::Logger *const rootLogger = getLogger("root");
    return rootLogger;
}

/**
 * Remove a logger explicitly. Should usually not be needed.
 */
void removeLogger(quill::Logger *logger);

/**
 * Initialize the logging system. Must only ever be called once, at program startup,
 * before any logger is requested.
 */
void initializeLogging(quill::LogLevel consoleLogLevel = quill::LogLevel::Info);

/**
 * Shut the logging system down and flush all pending messages.
 * Must be called last in a program, as logging is not possible afterwards.
 */
void shutdownLogging();

/**
 * Block until all pending log messages have been written out.
 */
void flushLogs();

/**
 * Print a header box with the given title to stdout.
 * @param title Title text
 */
void printHeaderBox(std::string_view title);

/**
 * Print a section box with the given title to stdout.
 * @param title Title text
 */
void printSectionBox(std::string_view title);

} // namespace ASGenerator
