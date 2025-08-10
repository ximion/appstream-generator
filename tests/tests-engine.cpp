/*
 * Copyright (C) 2019-2025 Matthias Klumpp <matthias@tenstral.net>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#define CATCH_CONFIG_MAIN
#include <catch2/catch_all.hpp>

#include <filesystem>
#include "logging.h"

using namespace ASGenerator;
namespace fs = std::filesystem;

static struct TestSetup {
    TestSetup()
    {
        setVerbose(true);
    }
} testSetup;
