/*
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
 * Copyright (C) The APT development team.
 * Copyright (C) 2016 Canonical Ltd
 *   Author(s): Iain Lane <iain@orangesquash.org.uk>
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

#include "debutils.h"

#include <filesystem>
#include <format>
#include <stdexcept>
#include <cctype>
#include <cstring>
#include <vector>

#include "../../logging.h"
#include "../../downloader.h"
#include "../../utils.h"

namespace ASGenerator
{

std::string downloadIfNecessary(
    const std::string &prefix,
    const std::string &destPrefix,
    const std::string &suffix,
    Downloader *downloader)
{
    if (downloader == nullptr)
        downloader = &Downloader::get();

    const std::vector<std::string> exts = {"xz", "bz2", "gz"};

    for (const auto &ext : exts) {
        // Replace {} with the extension suffix
        std::string formattedSuffix = suffix;
        std::size_t pos = formattedSuffix.find("{}");
        if (pos != std::string::npos)
            formattedSuffix.replace(pos, 2, ext);

        const std::string fileName = (fs::path(prefix) / formattedSuffix).string();
        const std::string destFileName = (fs::path(destPrefix) / (formattedSuffix + "." + ext)).string();

        if (Utils::isRemote(fileName)) {
            try {
                downloader->downloadFile(fileName, destFileName);
                return destFileName;
            } catch (const std::exception &e) {
                logDebug("Unable to download: {}", e.what());
            }
        } else {
            if (fs::exists(fileName))
                return fileName;
        }
    }

    /* all extensions failed, so we failed */
    throw std::runtime_error(
        std::format("Could not obtain any file matching {}", (fs::path(prefix) / suffix).string()));
}

/**
 * This compares a fragment of the version. This is a slightly adapted
 * version of what dpkg uses in dpkg/lib/dpkg/version.c.
 * In particular, the a | b = NULL check is removed as we check this in the
 * caller, we use an explicit end for a | b strings and we check ~ explicit.
 */
static int order(char c)
{
    if (std::isdigit(c))
        return 0;
    else if (std::isalpha(c))
        return c;
    else if (c == '~')
        return -1;
    else if (c)
        return c + 256;

    return 0;
}

/**
 * Iterate over the whole string
 * What this does is to split the whole string into groups of
 * numeric and non numeric portions. For instance:
 *    a67bhgs89
 * Has 4 portions 'a', '67', 'bhgs', '89'. A more normal:
 *    2.7.2-linux-1
 * Has '2', '.', '7', '.' ,'-linux-','1'
 */
static int cmpFragment(const char *a, const char *aEnd, const char *b, const char *bEnd)
{
    const char *lhs = a;
    const char *rhs = b;

    while (lhs != aEnd && rhs != bEnd) {
        int first_diff = 0;

        while (lhs != aEnd && rhs != bEnd && (!std::isdigit(*lhs) || !std::isdigit(*rhs))) {
            int vc = order(*lhs);
            int rc = order(*rhs);

            if (vc != rc)
                return vc - rc;
            ++lhs;
            ++rhs;
        }

        while (*lhs == '0')
            ++lhs;
        while (*rhs == '0')
            ++rhs;
        while (std::isdigit(*lhs) && std::isdigit(*rhs)) {
            if (!first_diff)
                first_diff = *lhs - *rhs;
            ++lhs;
            ++rhs;
        }

        if (std::isdigit(*lhs))
            return 1;
        if (std::isdigit(*rhs))
            return -1;
        if (first_diff)
            return first_diff;
    }

    // The strings must be equal
    if (lhs == aEnd && rhs == bEnd)
        return 0;

    // lhs is shorter
    if (lhs == aEnd) {
        if (*rhs == '~')
            return 1;
        return -1;
    }

    // rhs is shorter
    if (rhs == bEnd) {
        if (*lhs == '~')
            return -1;
        return 1;
    }

    // Shouldn't happen
    return 1;
}

/**
 * Compare two Debian-style version numbers.
 */
int compareVersions(const std::string &a, const std::string &b)
{
    const char *ac = a.c_str();
    const char *bc = b.c_str();

    const char *aEnd = ac + a.length();
    const char *bEnd = bc + b.length();

    // Strip off the epoch and compare it
    const char *lhs = static_cast<const char *>(std::memchr(ac, ':', aEnd - ac));
    const char *rhs = static_cast<const char *>(std::memchr(bc, ':', bEnd - bc));

    if (lhs == nullptr)
        lhs = ac;
    if (rhs == nullptr)
        rhs = bc;

    // Special case: a zero epoch is the same as no epoch,
    // so remove it.
    if (lhs != ac) {
        for (; ac != lhs && *ac == '0'; ++ac)
            ;
        if (ac == lhs) {
            ++lhs;
            ++ac;
        }
    }

    if (rhs != bc) {
        for (; bc != rhs && *bc == '0'; ++bc)
            ;
        if (bc == rhs) {
            ++rhs;
            ++bc;
        }
    }

    // Compare the epoch
    int res = cmpFragment(ac, lhs, bc, rhs);
    if (res != 0)
        return res;

    // Skip the ':'
    if (lhs != ac)
        lhs++;
    if (rhs != bc)
        rhs++;

    // Find the last '-' in the version - use manual reverse search since memrchr isn't standard
    const char *dlhs = nullptr;
    const char *drhs = nullptr;

    // Search backwards for last '-'
    for (const char *p = aEnd - 1; p >= lhs; --p) {
        if (*p == '-') {
            dlhs = p;
            break;
        }
    }
    for (const char *p = bEnd - 1; p >= rhs; --p) {
        if (*p == '-') {
            drhs = p;
            break;
        }
    }

    if (dlhs == nullptr)
        dlhs = aEnd;
    if (drhs == nullptr)
        drhs = bEnd;

    // Compare the main version
    res = cmpFragment(lhs, dlhs, rhs, drhs);
    if (res != 0)
        return res;

    // Skip the '-'
    if (dlhs != aEnd)
        dlhs++;
    if (drhs != bEnd)
        drhs++;

    // Compare the revision
    return cmpFragment(dlhs, aEnd, drhs, bEnd);
}

} // namespace ASGenerator
