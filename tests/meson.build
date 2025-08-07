
# Miscellaneous tests
tests_misc = executable(
    'tests-misc',
    'tests-misc.cpp',
    dependencies: [catch2_dep, tbb_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('Miscellaneous', tests_misc)

# Database/Cache tests
tests_db = executable(
    'tests-db',
    'tests-db.cpp',
    dependencies: [catch2_dep, tbb_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('Databases', tests_db)

# Network-dependent tests
tests_net = executable(
    'tests-net',
    'tests-net.cpp',
    dependencies: [catch2_dep, tbb_dep, asgen_lib_dep],
    include_directories: [src_dir],
)
test('Network', tests_net)
