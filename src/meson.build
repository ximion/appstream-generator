
asgencpp_src = files(
  'config.cpp',
  'downloader.cpp',
  'logging.cpp',
  'utils.cpp',
  'zarchive.cpp',
)

asgencpp_hdr = files(
  'config.h',
  'downloader.h',
  'logging.h',
  'utils.h',
  'zarchive.h',
)

conf_data = configuration_data()
conf_data.set_quoted('DATADIR', join_paths(get_option('prefix'), get_option('datadir'), 'appstream'))
conf_data.set_quoted('ASGEN_VERSION', asgen_version)
conf_data.set('BUILD_RPMMD', get_option('rpmmd'))
defines_h = configure_file(
  output: 'defines.h',
  configuration: conf_data
)

asgen_deps = [
  glib_dep,
  appstream_dep,
  ascompose_dep,
  fyaml_dep,
  lmdb_dep,
  archive_dep,
  curl_dep,
  inja_dep,
]

# static library of bindings automatically generated from GIR
asgen_lib = static_library(
  'asgenlib',
  [asgencpp_src, asgencpp_hdr, defines_h],
  dependencies: asgen_deps,
  cpp_args: [
    '-DI_KNOW_THE_APPSTREAM_COMPOSE_API_IS_SUBJECT_TO_CHANGE'
  ],
)

asgen_lib_dep = declare_dependency(
  link_with: asgen_lib,
  include_directories: [src_dir],
  dependencies: asgen_deps,
  compile_args: [
    '-DI_KNOW_THE_APPSTREAM_COMPOSE_API_IS_SUBJECT_TO_CHANGE'
  ],
)


# D code
#subdir('asgen')
