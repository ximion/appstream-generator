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

// Backend headers must come before logging.h to avoid partial specialization
// conflicts: DeferredFormatCodec.h (pulled in by logging.h) triggers instantiation
// of fmtquill formatters before format.h can partially specialize them.
#include <quill/Backend.h>
#include <quill/Frontend.h>
#include <quill/sinks/ConsoleSink.h>

#include "logging.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <glib.h>

namespace ASGenerator
{

static std::shared_ptr<quill::Sink> g_consoleSink = nullptr;
static quill::LogLevel g_defaultLogLevel = quill::LogLevel::Info;
static quill::Logger *g_plainLogger = nullptr;

quill::Logger *getLogger(const std::string &name)
{
    if (QUILL_UNLIKELY(!g_consoleSink)) {
        std::cerr << "FATAL: Requested logger '" << name
                  << "' before the ASGenerator logging system was initialized. "
                     "ASGenerator::initializeLogging() must be called first."
                  << std::endl;
        std::abort();
    }

    auto logger = quill::Frontend::get_logger(name);
    if (logger != nullptr)
        return logger;

    quill::PatternFormatterOptions fmtOpt{
        "%(time) %(log_level_short_code) %(logger): %(message)", "%Y-%m-%d %H:%M:%S.%Qms"};
    logger = quill::Frontend::create_or_get_logger(name, g_consoleSink, fmtOpt);
    logger->set_log_level(g_defaultLogLevel);

    return logger;
}

quill::Logger *getLogger(const char *name)
{
    return getLogger(std::string(name));
}

void removeLogger(quill::Logger *logger)
{
    quill::Frontend::remove_logger_blocking(logger);
}

static GLogWriterOutput glibLogWriter(GLogLevelFlags log_level, const GLogField *fields, gsize n_fields, gpointer)
{
    std::string domainStr;
    std::string msgStr;
    const char *file = "";
    const char *func = "";
    int line = 0;

    auto assignFieldStr = [](std::string &dst, const GLogField &f) {
        if (!f.value)
            return;
        const auto s = static_cast<const char *>(f.value);
        if (f.length < 0)
            dst.assign(s);
        else
            dst.assign(s, static_cast<size_t>(f.length));
    };

    // only accept NUL-terminated field data, as we pass it on as a plain string
    auto assignFieldCStr = [](const char *&dst, const GLogField &f) {
        if (f.value && f.length < 0)
            dst = static_cast<const char *>(f.value);
    };

    for (gsize i = 0; i < n_fields; ++i) {
        const auto &f = fields[i];
        if (!f.key)
            continue;

        if (std::strcmp(f.key, "GLIB_DOMAIN") == 0) {
            assignFieldStr(domainStr, f);
        } else if (std::strcmp(f.key, "MESSAGE") == 0) {
            assignFieldStr(msgStr, f);
        } else if (std::strcmp(f.key, "CODE_FILE") == 0) {
            assignFieldCStr(file, f);
        } else if (std::strcmp(f.key, "CODE_FUNC") == 0) {
            assignFieldCStr(func, f);
        } else if (std::strcmp(f.key, "CODE_LINE") == 0) {
            std::string lineStr;
            assignFieldStr(lineStr, f);
            if (!lineStr.empty())
                line = static_cast<int>(std::strtol(lineStr.c_str(), nullptr, 10));
        }
    }

    auto logger = getLogger(domainStr.empty() ? "glog" : domainStr);

    quill::LogLevel level;
    switch (log_level & G_LOG_LEVEL_MASK) {
    case G_LOG_LEVEL_ERROR:
        level = quill::LogLevel::Critical;
        break;
    case G_LOG_LEVEL_CRITICAL:
        level = quill::LogLevel::Error;
        break;
    case G_LOG_LEVEL_WARNING:
        level = quill::LogLevel::Warning;
        break;
    case G_LOG_LEVEL_MESSAGE:
    case G_LOG_LEVEL_INFO:
        level = quill::LogLevel::Info;
        break;
    case G_LOG_LEVEL_DEBUG:
        level = quill::LogLevel::Debug;
        break;
    default:
        level = quill::LogLevel::Info;
        break;
    }

    if ((log_level & G_LOG_FLAG_FATAL) != 0)
        level = quill::LogLevel::Critical;

    QUILL_LOG_RUNTIME_METADATA_CALL(
        quill::MacroMetadata::Event::LogWithRuntimeMetadataShallowCopy,
        logger,
        level,
        file,
        line,
        func,
        "",
        "{}",
        msgStr.empty() ? "" : msgStr.c_str());

    return G_LOG_WRITER_HANDLED;
}

void initializeLogging(quill::LogLevel consoleLogLevel)
{
    // trying to initialize the log system twice is a critical error
    if (g_consoleSink) {
        std::cerr << "Tried to initialize the ASGenerator logging system twice. This is not allowed!" << std::endl;
        abort();
        return;
    }

    quill::BackendOptions backendOptn;

    // we want to log UTF-8 characters, so disable sanitization
    backendOptn.check_printable_char = {};

    // start Quill's async logging backend
    quill::Backend::start(backendOptn);

    // register our console sink. Quill colors info messages green by default, but those are
    // ordinary progress output and should look like plain terminal text.
    quill::ConsoleSinkConfig::Colours colours;
    colours.assign_colour_to_log_level(quill::LogLevel::Info, "");

    quill::ConsoleSinkConfig consoleCfg;
    consoleCfg.set_colours(colours);

    g_consoleSink = quill::Frontend::create_or_get_sink<quill::ConsoleSink>("asgen-console", consoleCfg);

    // configure defaults *before* any logger is created below: getLogger() stamps each new
    // logger with g_defaultLogLevel at creation time, so this must be set first or early
    // loggers would be stuck at the old default and silently drop messages below it.
    g_defaultLogLevel = consoleLogLevel;
    g_consoleSink->set_log_level_filter(consoleLogLevel);

    // Logger without any metadata prefix, used for the header/section boxes. It shares the
    // console sink, so the boxes stay correctly ordered relative to regular log messages
    g_plainLogger = quill::Frontend::create_or_get_logger(
        "asgen-plain",
        g_consoleSink,
        quill::PatternFormatterOptions{
            "%(message)",
            "",
            quill::Timezone::LocalTime,
            false, // do not re-prefix every line of the multi-line boxes
            '\n'});
    g_plainLogger->set_log_level(quill::LogLevel::TraceL3);

    // forward any GLib log messages
    g_log_set_writer_func(glibLogWriter, nullptr, nullptr);
}

void shutdownLogging()
{
    // NOTE: It is forbidden to reset the GLib log handler, so we don't do that.
    // This shutdown function must be called last in a program, after no more
    // logging is possible (or never).

    quill::Backend::stop();
}

void flushLogs()
{
    // logging may not be running (yet), in which case there is nothing to flush
    if (!g_consoleSink)
        return;

    // this flushes the whole backend queue, not just this logger's messages
    getDefaultLogger()->flush_log();
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

    LOG_NOTICE(g_plainLogger, "{}", output);
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
