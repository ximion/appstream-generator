
tests_misc = executable(
    'tests-misc',
    'tests-misc.cpp',
    dependencies: [catch2_dep],
    link_with: [asgencpp_lib],
    include_directories: [src_dir],
)
test('Miscellaneous', tests_misc)
