/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
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

module ag.logging;

import std.stdio;
import std.string : format;
import std.datetime;

enum LogSeverity : string
{
    DEBUG = "DEBUG",
    INFO = "INFO",
    WARNING = "WARNING",
    ERROR = "ERROR"
}

void log (LogSeverity, string, Args...) (LogSeverity severity, string tmpl, Args args)
{
    auto time = Clock.currTime ();
    auto timeStr = format ("%d-%02d-%02d %02d:%02d.%02d", time.year, time.month, time.day, time.hour,time.minute, time.second);
    writeln (timeStr, " - ", severity, ": ", format (tmpl, args));
}

void debugmsg (string, Args...) (string tmpl, Args args)
{
    debug {
        log (LogSeverity.DEBUG, tmpl, args);
    }
}

void info (string, Args...) (string tmpl, Args args)
{
    log (LogSeverity.INFO, tmpl, args);
}

void warning (string, Args...) (string tmpl, Args args)
{
    log (LogSeverity.WARNING, tmpl, args);
}

void error (string, Args...) (string tmpl, Args args)
{
    log (LogSeverity.ERROR, tmpl, args);
}
