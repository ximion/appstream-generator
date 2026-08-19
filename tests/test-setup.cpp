/*
 * Copyright (C) 2016-2026 Matthias Klumpp <matthias@tenstral.net>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#include <catch2/catch_test_macros.hpp>
#include <catch2/reporters/catch_reporter_event_listener.hpp>
#include <catch2/reporters/catch_reporter_registrars.hpp>

#include "logging.h"

namespace ASGenerator
{

/**
 * Set up the pieces of global state that every test binary needs.
 * This is compiled into all test executables.
 */
class TestSetupListener : public Catch::EventListenerBase
{
public:
    using Catch::EventListenerBase::EventListenerBase;

    void testRunStarting(const Catch::TestRunInfo &) override
    {
        // tests are always verbose, so we get debug messages in case anything fails
        initializeLogging(quill::LogLevel::Debug);
    }

    void testRunEnded(const Catch::TestRunStats &) override
    {
        shutdownLogging();
    }
};

} // namespace ASGenerator

CATCH_REGISTER_LISTENER(ASGenerator::TestSetupListener)
