/*
 * Copyright (C) 2016-2017 Matthias Klumpp <matthias@tenstral.net>
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
import std.path : getcwd, buildPath;
import std.getopt;
import std.string : format;
import std.array : empty;
import core.stdc.stdlib : exit;

import asgen.logging;
import asgen.config;
import asgen.engine;
import asgen.defines : ASGEN_VERSION;


private immutable helpText =
"Usage:
  appstream-generator <subcommand> [OPTION...] - AppStream Generator.

AppStream Metadata Generator

Subcommands:
  process SUITE [SECTION] - Process new metadata for the given distribution suite.
  cleanup                 - Cleanup old metadata and media files.
  remove-found SUITE      - Drop all valid processed metadata and hints.
  forget PKID             - Drop all information we have about this (partial) package-id.
  info PKID               - Show information associated with this (full) package-id.

Help Options:
  -h, --help       Show help options

Application Options:
  --version        Show the program version.
  --verbose        Show extra debugging information.
  --force          Force action.
  -w|--workspace   Define the workspace location.
  -c|--config      Use the given configuration file.";

version (unittest) {
void main () {}
} else {

void main(string[] args)
{
    string command;
    bool verbose;
    bool showHelp;
    bool showVersion;
    bool forceAction;
    string wdir;
    string configFname;

    // parse command-line options
    try {
        getopt (args,
            "help|h", &showHelp,
            "verbose", &verbose,
            "version", &showVersion,
            "force", &forceAction,
            "workspace|w", &wdir,
            "config|c", &configFname);
    } catch (Exception e) {
        writeln ("Unable to parse parameters: ", e.msg);
        exit (1);
    }

    if (showHelp) {
        writeln (helpText);
        return;
    }

    if (showVersion) {
        writeln ("Generator version: ", ASGEN_VERSION);
        return;
    }

    if (args.length < 2) {
        writeln ("No subcommand specified!");
        return;
    }

    auto conf = Config.get ();
    if (configFname.empty) {
        // if we don't have an explicit config file set, and also no
        // workspace, take the current directory
        if (wdir.empty)
            wdir = getcwd ();
        configFname = buildPath (wdir, "asgen-config.json");
    }

    try {
        conf.loadFromFile (configFname, wdir);
    } catch (Exception e) {
        writefln ("Unable to load configuration: %s", e.msg);
        exit (4);
    }
    scope (exit) {
        // ensure we clean up when the generator is done
        import std.file : rmdirRecurse, exists;
        if (conf.getTmpDir.exists)
            rmdirRecurse (conf.getTmpDir ());
    }

    // globally enable verbose mode, if requested
    if (verbose) {
        asgen.logging.setVerbose (true);
    }

    auto engine = new Engine ();
    engine.forced = forceAction;

    command = args[1];
    switch (command) {
        case "run":
        case "process":
            if (args.length < 3) {
                writeln ("Invalid number of parameters: You need to specify at least a suite name.");
                exit (1);
            }
            if (args.length > 4) {
                writeln ("Invalid number of parameters: You need to specify a suite name and (optionally) a section name.");
                exit (1);
            }
            if (args.length == 3)
                engine.run (args[2]);
            else
                engine.run (args[2], args[3]);
            break;
        case "cleanup":
            engine.runCleanup ();
            break;
        case "remove-found":
            if (args.length != 3) {
                writeln ("Invalid number of parameters: You need to specify a suite name.");
                exit (1);
            }
            engine.removeHintsComponents (args[2]);
            break;
        case "forget":
            if (args.length != 3) {
                writeln ("Invalid number of parameters: You need to specify a package-id (partial IDs are allowed).");
                exit (1);
            }
            engine.forgetPackage (args[2]);
            break;
        case "info":
            if (args.length != 3) {
                writeln ("Invalid number of parameters: You need to specify a package-id.");
                exit (1);
            }
            engine.printPackageInfo (args[2]);
            break;
        default:
            writeln (format ("The command '%s' is unknown.", command));
            exit (1);
            break;
    }
}

}
