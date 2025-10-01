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

#include "defines.h"

#include <iostream>
#include <filesystem>
#include <format>
#include <vector>
#include <string>
#include <unistd.h>
#include <sys/stat.h>
#include <clocale>

#include <glib.h>

#ifdef HAVE_BACKWARD
#define BACKWARD_HAS_UNWIND 1
#include <backward.hpp>
#endif

#include "logging.h"
#include "config.h"
#include "engine.h"
#include "utils.h"

using namespace ASGenerator;

/**
 * Create XDG runtime directory if it doesn't exist.
 * Ubuntu's Snappy package manager doesn't create the runtime
 * data dir, and some of the libraries we depend on expect it
 * to be available. Try to create the directory.
 */
static void createXdgRuntimeDir()
{
    const char *xdgRuntimeDir = g_getenv("XDG_RUNTIME_DIR");
    if (!xdgRuntimeDir || xdgRuntimeDir[0] != '/')
        return; // nothing to do here

    if (fs::exists(xdgRuntimeDir))
        return; // directory already exists

    try {
        fs::create_directories(xdgRuntimeDir);
        // Set permissions to 700 (owner read/write/execute only)
        if (chmod(xdgRuntimeDir, S_IRWXU) == -1)
            logDebug("Failed to set permissions on XDG runtime dir: {}", std::strerror(errno));
    } catch (const std::filesystem::filesystem_error &e) {
        logWarning("Unable to create XDG runtime dir: {}", e.what());
        return;
    }

    logDebug("Created missing XDG runtime dir: {}", xdgRuntimeDir);
}

/**
 * Print version information to stdout.
 */
static void printVersion()
{
    std::cout << "Generator version: " << ASGEN_VERSION << std::endl;
}

/**
 * Ensure that suite and/or section parameters are set correctly.
 */
static void ensureSuiteAndOrSectionParameterSet(const std::vector<std::string> &args)
{
    if (args.size() < 3) {
        std::cerr << "Invalid number of parameters: You need to specify at least a suite name." << std::endl;
        std::exit(1);
    }
    if (args.size() > 4) {
        std::cerr << "Invalid number of parameters: You need to specify a suite name and (optionally) a section name."
                  << std::endl;
        std::exit(1);
    }
}

/**
 * Execute the specified command with the given arguments.
 */
static int executeCommand(const std::string &command, const std::vector<std::string> &args, bool forceAction)
{
    auto engine = std::make_unique<Engine>();
    engine->setForced(forceAction);

    if (command == "run" || command == "process") {
        if (args.size() == 2) {
            // process all suites
            engine->run();
        } else {
            ensureSuiteAndOrSectionParameterSet(args);
            if (args.size() == 3)
                engine->run(args[2]);
            else
                engine->run(args[2], args[3]);
        }
    } else if (command == "process-file") {
        if (args.size() < 5) {
            std::cerr << "Invalid number of parameters: You need to specify a suite name, a section name and at least "
                         "one file to process."
                      << std::endl;
            return 1;
        }
        std::vector<std::string> files(args.begin() + 4, args.end());
        engine->processFile(args[2], args[3], files);
    } else if (command == "publish") {
        ensureSuiteAndOrSectionParameterSet(args);
        if (args.size() == 3)
            engine->publish(args[2]);
        else
            engine->publish(args[2], args[3]);
    } else if (command == "cleanup") {
        engine->runCleanup();
    } else if (command == "remove-found") {
        if (args.size() != 3) {
            std::cerr << "Invalid number of parameters: You need to specify a suite name." << std::endl;
            return 1;
        }
        engine->removeHintsComponents(args[2]);
    } else if (command == "forget") {
        if (args.size() != 3) {
            std::cerr << "Invalid number of parameters: You need to specify a package-id (partial IDs are allowed)."
                      << std::endl;
            return 1;
        }
        engine->forgetPackage(args[2]);
    } else if (command == "info") {
        if (args.size() != 3) {
            std::cerr << "Invalid number of parameters: You need to specify a package-id." << std::endl;
            return 1;
        }
        engine->printPackageInfo(args[2]);
    } else {
        std::cerr << std::format("The command '{}' is unknown.", command) << std::endl;
        return 1;
    }

    return 0;
}

/**
 * Main function
 */
int main(int argc, char **argv)
{
    gboolean verbose = FALSE;
    gboolean showHelp = FALSE;
    gboolean showVersion = FALSE;
    gboolean forceAction = FALSE;
    g_autofree gchar *wdir = nullptr;
    g_autofree gchar *exportDir = nullptr;
    g_autofree gchar *configFname = nullptr;

    // Initialize locale for proper UTF-8 handling
    if (!setlocale(LC_ALL, "")) {
        // If system locale fails, try to set a UTF-8 locale explicitly
        logInfo("No locale set, falling back to C.UTF-8.");
        if (!setlocale(LC_ALL, "C.UTF-8") && !setlocale(LC_ALL, "en_US.UTF-8"))
            logWarning("Warning: Could not set UTF-8 locale. UTF-8 text may be corrupted.");
    }
    // Make sure nothing localizes numbers by accident
    std::setlocale(LC_NUMERIC, "C");

    try {
        std::locale loc("");
        std::locale::global(loc);
        std::cout.imbue(loc);
        std::cerr.imbue(loc);
    } catch (...) {
        // Non-fatal; iostreams will just use the classic locale
    }

#ifdef HAVE_BACKWARD
    backward::SignalHandling sh;
    if (sh.loaded())
        logDebug("Backward registered for stack-trace printing.");
#endif

    GOptionEntry entries[] = {
        {"help", 'h', 0, G_OPTION_ARG_NONE, &showHelp, "Show help options", nullptr},
        {"verbose", 0, 0, G_OPTION_ARG_NONE, &verbose, "Show extra debugging information", nullptr},
        {"version", 0, 0, G_OPTION_ARG_NONE, &showVersion, "Show the program version", nullptr},
        {"force", 0, 0, G_OPTION_ARG_NONE, &forceAction, "Force action", nullptr},
        {"workspace", 'w', 0, G_OPTION_ARG_STRING, &wdir, "Define the workspace location", "DIR"},
        {"config", 'c', 0, G_OPTION_ARG_STRING, &configFname, "Use the given configuration file", "FILE"},
        {"export-dir", 0, 0, G_OPTION_ARG_STRING, &exportDir, "Override the workspace root export directory", "DIR"},
        {nullptr}
    };

    g_autoptr(GError) error = nullptr;
    g_autoptr(GOptionContext) context = g_option_context_new("<subcommand> - AppStream Generator");

    // Set program description
    g_option_context_set_description(
        context,
        "Subcommands:\n"
        "  run [SUITE] [SECTION]   - Process new metadata for the given distribution suite and publish it.\n"
        "  process-file SUITE SECTION FILE1 [FILE2 ...]\n"
        "                          - Process new metadata for the given package file.\n"
        "  cleanup                 - Cleanup old metadata and media files.\n"
        "  publish SUITE [SECTION] - Export all metadata and publish reports in the export directories.\n"
        "  remove-found SUITE      - Drop all valid processed metadata and hints.\n"
        "  forget PKID             - Drop all information we have about this (partial) package-id.\n"
        "  info PKID               - Show information associated with this (full) package-id.\n");

    g_option_context_set_summary(context, "AppStream Metadata Generator");
    g_option_context_add_main_entries(context, entries, nullptr);
    g_option_context_set_help_enabled(context, TRUE);

    if (!g_option_context_parse(context, &argc, &argv, &error)) {
        std::cerr << "Unable to parse parameters: " << error->message << std::endl;
        return 1;
    }

    if (showHelp) {
        g_autofree gchar *helpText = g_option_context_get_help(context, TRUE, nullptr);
        std::cout << helpText << std::endl;
        return 0;
    }

    if (showVersion) {
        printVersion();
        return 0;
    }

    if (argc < 2) {
        std::cerr << "No subcommand specified!" << std::endl;
        g_autofree gchar *helpText = g_option_context_get_help(context, TRUE, nullptr);
        std::cerr << helpText << std::endl;
        return 1;
    }

    // Convert remaining arguments to vector of strings
    std::vector<std::string> args;
    args.reserve(argc);
    for (int i = 0; i < argc; ++i)
        args.emplace_back(argv[i]);

    // globally enable verbose mode, if requested
    if (verbose)
        setVerbose(true);

    auto &conf = Config::get();
    std::string configFilename;
    if (configFname) {
        configFilename = configFname;
    } else {
        // if we don't have an explicit config file set, and also no
        // workspace, take the current directory
        std::string workspaceDir;
        if (wdir) {
            workspaceDir = wdir;
        } else {
            workspaceDir = fs::current_path().string();
        }
        configFilename = fs::path(workspaceDir) / "asgen-config.json";
    }

    std::string workspaceDirStr = wdir ? wdir : "";
    std::string exportDirStr = exportDir ? exportDir : "";

    try {
        conf.loadFromFile(configFilename, workspaceDirStr, exportDirStr);
    } catch (const std::exception &e) {
        std::cerr << std::format("Unable to load configuration: {}", e.what()) << std::endl;
        return 4;
    }

    // ensure runtime dir exists, in case we are installed with Snappy
    createXdgRuntimeDir();

    int result = 0;
    if (isVerbose()) {
        result = executeCommand(args[1], args, forceAction);
    } else {
        try {
            result = executeCommand(args[1], args, forceAction);
        } catch (const std::exception &e) {
            std::cerr << std::format("Error executing command: {}", e.what()) << std::endl;
            result = 1;
        }
    }

    return result;
}
