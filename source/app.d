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

import std.stdio;
import std.path;
import std.getopt;
import std.string : format;
import core.stdc.stdlib;

import ag.config;
import ag.engine;


void main(string[] args)
{
    string command;
    bool verbose;
    bool help;
    string wdir = getcwd ();

    // parse command-line options
    try {
        getopt (args,
            "verbose", &verbose,
            "help|h", &help,
            "workspace|w", &wdir);
    } catch (Exception e) {
        writeln ("Unable to parse parameters: ", e.msg);
        exit (1);
    }

    if (help) {
        // (currently) give some useless advice
        writeln ("Just believe in yourself!");
        return;
    }

    if (args.length < 2) {
        writeln ("No subcommand specified!");
        return;
    }

    auto conf = Config.get ();
    try {
        conf.loadFromFile ("asgen-config.yml");
    } catch (Exception e) {
        writefln ("Unable to load configuration: %s", e.msg);
        exit (4);
    }
    scope (exit) {
        import std.file;
        if (exists (conf.getTmpDir ()))
            rmdirRecurse (conf.getTmpDir ());
    }

    command = args[1];
    switch (command) {
        case "run":
        case "process":
            auto engine = new Engine ();
            break;
        default:
            writeln (format ("The command '%s' is unknown.", command));
            exit (1);
            break;
    }
}
