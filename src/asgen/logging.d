/*
 * Copyright (C) 2016-2021 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.logging;

import std.stdio;
import std.string : format;
import std.datetime;


private __gshared bool __verbose = false;

enum LogSeverity : string
{
    DEBUG = "DEBUG",
    INFO = "INFO",
    WARNING = "WARNING",
    ERROR = "ERROR"
}

@trusted
void logMessage (LogSeverity, string, Args...) (const LogSeverity severity, const string tmpl, const Args args)
{
    auto time = Clock.currTime ();
    auto timeStr = "%d-%02d-%02d %02d:%02d:%02d".format (time.year, time.month, time.day, time.hour,time.minute, time.second);
    writeln (timeStr, " - ", severity, ": ", format (tmpl, args));
}

@trusted
void logDebug (string, Args...) (const string tmpl, const Args args)
{
    if (__verbose)
        logMessage (LogSeverity.DEBUG, tmpl, args);
}

@safe
void logInfo (string, Args...) (const string tmpl, const Args args)
{
    logMessage (LogSeverity.INFO, tmpl, args);
}

@safe
void logWarning (string, Args...) (const string tmpl, const Args args)
{
    logMessage (LogSeverity.WARNING, tmpl, args);
}

@safe
void logError (string, Args...) (const string tmpl, const Args args)
{
    logMessage (LogSeverity.ERROR, tmpl, args);
}

@trusted
void setVerbose (const bool enabled)
{
    __verbose = enabled;
}
