/*
 * Copyright (C) 2026 Victor Fuentes <vlinkz@snowflakeos.org>
 *
 * Based on the archlinux and alpinelinux backends, which are:
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
 * Copyright (C) 2020-2025 Rasmus Thomsen <oss@cogitri.dev>
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

#include "nixindexutils.h"

#include <filesystem>
#include <fstream>
#include <format>
#include <regex>
#include <cstdlib>
#include <array>
#include <thread>
#include <sys/wait.h>

#include <glib.h>
#include <gio/gio.h>

#include "../../logging.h"
#include "../../utils.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

namespace
{

/**
 * Execute a command and returns exit code and output string.
 */
std::pair<int, std::string> executeCommand(const std::vector<std::string> &args, const std::string &workDir = "")
{
    if (args.empty())
        return {-1, "No command specified"};

    std::vector<char *> argv;
    argv.reserve(args.size() + 1);
    for (const auto &arg : args)
        argv.push_back(const_cast<char *>(arg.c_str()));
    argv.push_back(nullptr);

    g_autofree gchar *stdoutData = nullptr;
    g_autofree gchar *stderrData = nullptr;
    gint exitStatus = 0;
    g_autoptr(GError) error = nullptr;

    gboolean success = g_spawn_sync(
        workDir.empty() ? nullptr : workDir.c_str(),
        argv.data(),
        nullptr,
        static_cast<GSpawnFlags>(G_SPAWN_SEARCH_PATH),
        nullptr,
        nullptr,
        &stdoutData,
        &stderrData,
        &exitStatus,
        &error);

    if (!success) {
        std::string errMsg = error ? error->message : "Unknown error";
        return {-1, errMsg};
    }

    int exitCode = WIFEXITED(exitStatus) ? WEXITSTATUS(exitStatus) : -1;
    std::string output;
    if (stdoutData)
        output += stdoutData;
    if (exitCode != 0 && stderrData)
        output += stderrData;
    return {exitCode, output};
}

/**
 * Execute a command and return binary stdout data.
 */
std::pair<int, std::vector<std::uint8_t>> executeBinaryCommand(
    const std::vector<std::string> &args,
    const std::string &workDir = "")
{
    if (args.empty())
        return {-1, {}};

    std::vector<const char *> argv;
    argv.reserve(args.size() + 1);
    for (const auto &arg : args)
        argv.push_back(arg.c_str());
    argv.push_back(nullptr);

    g_autoptr(GError) error = nullptr;
    g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new(
        static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE));

    if (!workDir.empty()) {
        g_subprocess_launcher_set_cwd(launcher, workDir.c_str());
    }

    g_autoptr(GSubprocess) subprocess = g_subprocess_launcher_spawnv(launcher, argv.data(), &error);

    if (!subprocess) {
        logError("executeBinaryCommand spawn failed: {}", error ? error->message : "Unknown error");
        return {-1, {}};
    }

    g_autoptr(GBytes) stdoutBytes = nullptr;
    g_autoptr(GBytes) stderrBytes = nullptr;

    gboolean success = g_subprocess_communicate(
        subprocess,
        nullptr, // stdin
        nullptr, // cancellable
        &stdoutBytes,
        &stderrBytes,
        &error);

    if (!success) {
        logError("executeBinaryCommand communicate failed: {}", error ? error->message : "Unknown error");
        return {-1, {}};
    }

    int exitCode = -1;
    if (g_subprocess_get_if_exited(subprocess)) {
        exitCode = g_subprocess_get_exit_status(subprocess);
    }

    if (exitCode != 0 && stderrBytes) {
        gsize stderrLen;
        const char *stderrData = static_cast<const char *>(g_bytes_get_data(stderrBytes, &stderrLen));
        if (stderrLen > 0) {
            logDebug("executeBinaryCommand stderr: {}", std::string(stderrData, stderrLen));
        }
    }

    std::vector<std::uint8_t> result;
    if (stdoutBytes) {
        gsize len;
        const guint8 *data = static_cast<const guint8 *>(g_bytes_get_data(stdoutBytes, &len));
        result.assign(data, data + len);
    }

    return {exitCode, result};
}

/**
 * Execute nix-env and write wrapped JSON output to a file.
 * Wraps the nix-env JSON output in {"version":2,"packages":...} format.
 */
int executeNixEnvToPackagesJson(const std::vector<std::string> &args, const std::string &outputPath)
{
    if (args.empty())
        return -1;

    std::vector<const char *> argv;
    argv.reserve(args.size() + 1);
    for (const auto &arg : args)
        argv.push_back(arg.c_str());
    argv.push_back(nullptr);

    g_autoptr(GError) error = nullptr;
    g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new(
        static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE));

    // Only pass NIX_PATH environment variable
    const char *nixPath = getenv("NIX_PATH");
    if (nixPath) {
        logDebug("executeNixEnvToPackagesJson NIX_PATH: {}", nixPath);
        g_subprocess_launcher_setenv(launcher, "NIX_PATH", nixPath, TRUE);
    }

    g_autoptr(GSubprocess) subprocess = g_subprocess_launcher_spawnv(launcher, argv.data(), &error);

    if (!subprocess) {
        logError("Failed to execute nix-env: {}", error ? error->message : "Unknown error");
        return -1;
    }

    fs::path outPath(outputPath);
    fs::path tmpPath = outPath;
    tmpPath += ".tmp";

    std::ofstream outFile(tmpPath);
    if (!outFile.is_open())
        return -1;

    outFile << "{\"version\":2,\"packages\":";
    GInputStream *stdoutStream = g_subprocess_get_stdout_pipe(subprocess);
    std::array<char, 8192> buffer{};
    while (true) {
        gssize bytesRead = g_input_stream_read(stdoutStream, buffer.data(), buffer.size(), nullptr, &error);
        if (bytesRead > 0) {
            outFile.write(buffer.data(), bytesRead);
        } else if (bytesRead == 0) {
            break;
        } else {
            logError("Failed to read nix-env output: {}", error ? error->message : "Unknown error");
            outFile.close();
            std::error_code ec;
            fs::remove(tmpPath, ec);
            return -1;
        }
    }

    outFile << "}";
    outFile.close();

    if (!g_subprocess_wait(subprocess, nullptr, &error)) {
        logError("Failed waiting for nix-env: {}", error ? error->message : "Unknown error");
        std::error_code ec;
        fs::remove(tmpPath, ec);
        return -1;
    }

    int exitCode = g_subprocess_get_exit_status(subprocess);
    if (exitCode != 0) {
        std::error_code ec;
        fs::remove(tmpPath, ec);
        return exitCode;
    }

    std::error_code ec;
    fs::rename(tmpPath, outPath, ec);
    if (ec) {
        fs::remove(tmpPath, ec);
        return -1;
    }

    return exitCode;
}

} // anonymous namespace

std::string findNixExecutable()
{
    gchar *path = g_find_program_in_path("nix");
    if (path) {
        std::string result(path);
        g_free(path);
        return result;
    }
    return "";
}

std::string findNixEnvExecutable()
{
    gchar *path = g_find_program_in_path("nix-env");
    if (path) {
        std::string result(path);
        g_free(path);
        return result;
    }
    return "";
}

std::string generateNixPackagesIfNecessary(
    const std::string &nixExe,
    const std::string &suite,
    const std::string &section,
    const std::string &destFilePath)
{
    if (fs::exists(destFilePath))
        return destFilePath;

    const std::string nixEnvExe = findNixEnvExecutable();
    if (nixEnvExe.empty())
        throw std::runtime_error("nix-env binary not found. Cannot extract packages.json");

    auto [evalExitCode, nixpkgsPath] = executeCommand(
        {nixExe,
         "--extra-experimental-features",
         "nix-command flakes",
         "eval",
         "--quiet",
         std::format("{}/{}#path", suite, section)});

    if (evalExitCode != 0)
        throw std::runtime_error(std::format("nix eval failed: {}", nixpkgsPath));

    nixpkgsPath = Utils::trimString(nixpkgsPath);
    nixpkgsPath = fs::path(nixpkgsPath).lexically_normal().string();

    logDebug("Building nixpkgs packages.json, this may take a while");

    fs::create_directories(fs::path(destFilePath).parent_path());

    int exitCode = executeNixEnvToPackagesJson(
        {nixEnvExe,
         "-qaP",
         "--out-path",
         "--meta",
         "--json",
         "--file",
         nixpkgsPath,
         "--arg",
         "config",
         std::format("import {}/pkgs/top-level/packages-config.nix", nixpkgsPath)},
        destFilePath);

    if (exitCode != 0)
        throw std::runtime_error("nix-env failed to generate packages.json");

    return destFilePath;
}

std::unordered_map<std::string, NixPkgInfo> getInterestingNixPkgs(
    const std::string &nixExe,
    const std::string &indexPath,
    const std::string &storeUrl,
    const nlohmann::json &packagesJson)
{
    std::unordered_map<std::string, NixPkgInfo> interestingPkgs;

    // Build a map of packages to check
    std::unordered_map<std::string, std::string> pkgsToCheck;

    if (!packagesJson.contains("packages") || !packagesJson["packages"].is_object())
        return interestingPkgs;

    static const std::regex skipPrefixRegex(
        R"(^(python3.*Packages|haskellPackages|rPackages|emacsPackages|sbclPackages|texlivePackages|typstPackages)"
        R"(|vimPlugins|linuxKernel|perl5Packages|ocamlPackages.*|rubyPackages.*|lua\d*Packages|luajitPackages)"
        R"(|nodePackages.*|php\d*Extensions|phpExtensions|androidenv|chickenPackages.*|vscode-extensions)"
        R"(|akkuPackages|azure-cli-extensions|terraform-providers|tree-sitter-grammars|hunspellDicts)"
        R"(|aspellDicts|hyphenDicts|nltk-data|dotnetCorePackages|coqPackages|idrisPackages|rocmPackages)"
        R"(|kodiPackages|darwin)\.)");

    for (const auto &[attr, pkg] : packagesJson["packages"].items()) {
        if (std::regex_search(attr, skipPrefixRegex))
            continue;

        if (pkg.contains("outputs") && pkg["outputs"].is_object()) {
            for (const auto &[output, outPath] : pkg["outputs"].items()) {
                if (outPath.is_string())
                    pkgsToCheck[std::format("{}.{}", attr, output)] = outPath.get<std::string>();
            }
        }
    }

    std::vector<std::string> pathsToIndex;

    if (!fs::exists(indexPath)) {
        logDebug("Index {} directory doesn't exist, indexing all packages", indexPath);
        fs::create_directories(indexPath);

        for (const auto &[attr, outPath] : pkgsToCheck) {
            if (outPath.starts_with("/nix/store/") && outPath.find('\n') == std::string::npos)
                pathsToIndex.push_back(outPath);
        }
    } else {
        logDebug("Index directory exists, checking for missing entries...");

        for (const auto &[attr, outPath] : pkgsToCheck) {
            if (!outPath.starts_with("/nix/store/") || outPath.find('\n') != std::string::npos)
                continue;

            std::string basename = fs::path(outPath).filename().string();
            fs::path indexFile = fs::path(indexPath) / (basename + ".json");

            if (!fs::exists(indexFile))
                pathsToIndex.push_back(outPath);
        }

        if (!pathsToIndex.empty())
            logDebug("Found {} new packages to index", pathsToIndex.size());
        else
            logDebug("Index cache is up to date");
    }

    if (!pathsToIndex.empty()) {
        logDebug("Running parallel nix store ls for {} packages...", pathsToIndex.size());

        unsigned int numThreads = std::thread::hardware_concurrency();
        if (numThreads == 0)
            numThreads = 4;

        // Process packages in parallel using xargs
        // Using xargs is significantly faster than spawning individual processes
        std::string shScript = std::format(
            "xargs -P {} -I @ sh -c '"
            "result=$({} --extra-experimental-features nix-command store ls --store \"{}\" @ --json -R --quiet "
            "2>/dev/null) && "
            "[ -n \"$result\" ] && echo \"$result\" > \"{}/$(basename @).json\" || "
            "echo \"{{}}\" > \"{}/$(basename @).json\"'",
            numThreads,
            nixExe,
            storeUrl,
            indexPath,
            indexPath);

        std::string stdinData;
        for (const auto &outPath : pathsToIndex) {
            stdinData += outPath + "\n";
        }

        std::vector<const char *> argv = {"sh", "-c", shScript.c_str(), nullptr};
        g_autoptr(GError) error = nullptr;
        g_autoptr(GSubprocess) subprocess = g_subprocess_newv(argv.data(), G_SUBPROCESS_FLAGS_STDIN_PIPE, &error);

        if (!subprocess) {
            logError("Failed to start nix indexing process: {}", error ? error->message : "Unknown error");
            return interestingPkgs;
        }

        g_autoptr(GBytes) stdinBytes = g_bytes_new(stdinData.c_str(), stdinData.size());
        gboolean success = g_subprocess_communicate(
            subprocess,
            stdinBytes,
            nullptr, // cancellable
            nullptr, // stdout
            nullptr, // stderr
            &error);

        if (!success) {
            logError("Failed to communicate with nix indexing process: {}", error ? error->message : "Unknown error");
            return interestingPkgs;
        }

        if (!g_subprocess_get_successful(subprocess))
            logWarning("xargs indexing process exited with non-zero status");

        logDebug("Parallel nix store ls completed");
    }

    // Process the cached index files
    for (const auto &entry : fs::directory_iterator(indexPath)) {
        if (entry.path().extension() != ".json")
            continue;

        try {
            std::ifstream file(entry.path());
            if (!file.is_open())
                continue;

            nlohmann::json paths;
            file >> paths;

            std::string outPath = "/nix/store/" + entry.path().stem().string();

            std::string attr;
            int bestScore = std::numeric_limits<int>::max();
            for (const auto &[a, p] : pkgsToCheck) {
                if (p == outPath) {
                    int score = packagePriority(a);
                    if (score < bestScore) {
                        bestScore = score;
                        attr = a;
                    }
                }
            }

            if (attr.empty()) {
                // This can happen when index cache has entries from previous runs
                // that don't match current package filter
                logDebug("Skipping cached index with no matching attribute: {}", outPath);
                continue;
            }

            // Check if this package has share/applications
            if (!paths.contains("entries") || !paths["entries"].is_object())
                continue;

            const auto &entries = paths["entries"];
            if (!entries.contains("share") || !entries["share"].is_object())
                continue;

            const auto &share = entries["share"];
            if (!share.contains("type") || !share["type"].is_string())
                continue;

            // Helper to check if a symlink target belongs to the same package (or variant)
            // Helper to follow a symlink and get applications directory contents
            auto getApplicationsFromSymlink = [&](const std::string &target) -> nlohmann::json {
                try {
                    auto lsResult = nixStoreLs(nixExe, storeUrl, target, indexPath);
                    if (lsResult.contains("entries") && lsResult["entries"].is_object())
                        return lsResult["entries"];
                } catch (const std::exception &) {
                    // Failed to follow symlink
                }
                return nlohmann::json();
            };

            const std::string shareType = share["type"].get<std::string>();
            nlohmann::json applicationsJson;

            if (shareType == "symlink") {
                // share is a symlink - follow it to get applications directory
                if (!share.contains("target") || !share["target"].is_string())
                    continue;

                std::string target = share["target"].get<std::string>() + "/applications";
                applicationsJson = getApplicationsFromSymlink(target);
            } else if (shareType == "directory") {
                if (!share.contains("entries") || !share["entries"].is_object())
                    continue;

                const auto &shareEntries = share["entries"];
                if (!shareEntries.contains("applications"))
                    continue;

                const auto &applications = shareEntries["applications"];
                if (!applications.is_object() || !applications.contains("type"))
                    continue;

                const std::string appsType = applications["type"].get<std::string>();
                if (appsType == "symlink") {
                    // share/applications is a symlink - follow it
                    if (!applications.contains("target") || !applications["target"].is_string())
                        continue;

                    std::string target = applications["target"].get<std::string>();
                    applicationsJson = getApplicationsFromSymlink(target);
                } else if (appsType == "directory" && applications.contains("entries")) {
                    applicationsJson = applications["entries"];
                } else {
                    continue;
                }
            } else {
                continue;
            }

            if (!applicationsJson.is_object())
                continue;

            std::set<std::string> desktopFiles;
            for (const auto &[filename, fileInfo] : applicationsJson.items()) {
                if (!filename.ends_with(".desktop"))
                    continue;
                if (!fileInfo.is_object() || !fileInfo.contains("type"))
                    continue;
                const std::string fileType = fileInfo["type"].get<std::string>();
                if (fileType == "symlink" || fileType == "regular")
                    desktopFiles.insert(filename);
            }

            if (desktopFiles.empty())
                continue;

            interestingPkgs[attr] = {outPath, std::move(desktopFiles)};
        } catch (const std::exception &e) {
            logWarning("Failed to process result file {}: {}", entry.path().string(), e.what());
        }
    }

    return interestingPkgs;
}

std::vector<std::uint8_t> nixStoreCat(
    const std::string &nixExe,
    const std::string &storeUrl,
    const std::string &path,
    const std::string &workDir)
{
    auto [exitCode, data] = executeBinaryCommand(
        {nixExe, "--extra-experimental-features", "nix-command", "store", "cat", "--store", storeUrl, "--quiet", path},
        workDir);

    if (exitCode != 0) {
        logDebug("nix store cat failed for path: {}", path);
        return {' '};
    }

    return data;
}

nlohmann::json nixStoreLs(
    const std::string &nixExe,
    const std::string &storeUrl,
    const std::string &path,
    const std::string &workDir)
{
    auto [exitCode, output] = executeCommand(
        {nixExe,
         "--extra-experimental-features",
         "nix-command",
         "store",
         "ls",
         "--store",
         storeUrl,
         "--recursive",
         "--json",
         "--quiet",
         path},
        workDir);

    if (exitCode != 0)
        throw std::runtime_error(std::format("nix store ls failed: {}", output));

    return nlohmann::json::parse(output);
}

int packagePriority(const std::string &name)
{
    int score = 0;

    score += static_cast<int>(name.length());

    // Qt6/KDE preferred over Qt5
    if (name.starts_with("qt6Packages.") || name.starts_with("kdePackages.") || name.find("-qt6") != std::string::npos
        || name.find("_qt6") != std::string::npos) {
        score -= 50;
    } else if (
        name.starts_with("libsForQt5.") || name.find("-qt5") != std::string::npos
        || name.find("_qt5") != std::string::npos) {
        score += 50;
    }

    // Penalize sub-attributes
    size_t dotCount = std::count(name.begin(), name.end(), '.');
    if (dotCount > 0 && !name.starts_with("qt6Packages.") && !name.starts_with("kdePackages.")
        && !name.starts_with("libsForQt5.")) {
        score += static_cast<int>(dotCount) * 20;
    }

    // Penalize common variant suffixes
    static const std::regex variantSuffix(
        R"(-(full|minimal|unwrapped|wrapped|unstable|bin|gtk|sdl|wayland|xine|nox|pgtk)$)");
    if (std::regex_search(name, variantSuffix)) {
        score += 30;
    }

    return score;
}

} // namespace ASGenerator
