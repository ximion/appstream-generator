
asgencpp_src = files(
  'logging.cpp',
  'utils.cpp',
  'zarchive.cpp',
)

asgencpp_hdr = files(
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
  lmdb_dep,
  archive_dep,
  curl_dep
]

# static library of bindings automatically generated from GIR
asgen_lib = static_library(
  'asgenlib',
  [asgencpp_src, asgencpp_hdr, defines_h],
  dependencies: asgen_deps,
)

asgen_lib_dep = declare_dependency(
  link_with: asgen_lib,
  include_directories: [src_dir],
  dependencies: asgen_deps,
)


# D code
#subdir('asgen')
