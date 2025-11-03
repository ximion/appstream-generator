
# Miscellaneous tests
tests_misc = executable(
    'tests-misc',
    'tests-misc.cpp',
    dependencies: [catch2_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('Miscellaneous', tests_misc)

# Database/Cache tests
tests_db = executable(
    'tests-db',
    'tests-db.cpp',
    dependencies: [catch2_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('Databases', tests_db)

# Network-dependent tests
tests_net = executable(
    'tests-net',
    'tests-net.cpp',
    dependencies: [catch2_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('Network', tests_net, args: ['--allow-running-no-tests'])

# Report generator tests
tests_report = executable(
    'tests-report',
    'tests-report.cpp',
    dependencies: [catch2_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('ReportGenerator', tests_report)

# Icon handler tests
tests_icons = executable(
    'tests-icons',
    'tests-icons.cpp',
    dependencies: [catch2_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('IconHandler', tests_icons)

# Engine tests
tests_engine = executable(
    'tests-engine',
    'tests-engine.cpp',
    dependencies: [catch2_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('Engine', tests_engine)

# Debian backend tests
tests_backend_debian = executable(
    'tests-backend-debian',
    'tests-backend-debian.cpp',
    dependencies: [catch2_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('Backend - Debian', tests_backend_debian)

# Debian backend tests
tests_backend_misc = executable(
    'tests-backend-misc',
    'tests-backend-misc.cpp',
    dependencies: [catch2_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('Backend - Misc Tests', tests_backend_misc, args: ['--order', 'decl'])
