
subdir('backends')

asgencpp_src = files(
  'config.cpp',
  'contentsstore.cpp',
  'cptmodifiers.cpp',
  'datainjectpkg.cpp',
  'datastore.cpp',
  'dataunits.cpp',
  'downloader.cpp',
  'engine.cpp',
  'extractor.cpp',
  'hintregistry.cpp',
  'iconhandler.cpp',
  'logging.cpp',
  'reportgenerator.cpp',
  'result.cpp',
  'utils.cpp',
  'yaml-utils.cpp',
  'zarchive.cpp',
  'backends/interfaces.cpp',
)

asgencpp_hdr = files(
  'config.h',
  'contentsstore.h',
  'cptmodifiers.h',
  'datainjectpkg.h',
  'datastore.h',
  'dataunits.h',
  'downloader.h',
  'engine.h',
  'extractor.h',
  'hintregistry.h',
  'iconhandler.h',
  'logging.h',
  'reportgenerator.h',
  'result.h',
  'utils.h',
  'yaml-utils.h',
  'zarchive.h',
  'backends/interfaces.h',
)

conf_data = configuration_data()
conf_data.set_quoted('DATADIR', join_paths(get_option('prefix'), get_option('datadir'), 'appstream'))
conf_data.set_quoted('ASGEN_VERSION', asgen_version)
conf_data.set('HAVE_BACKWARD', backward_dep.found())
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
  tbb_dep,
  icu_dep,
  inja_dep,
  libxml2_dep,
]

asgen_args = [
  '-DI_KNOW_THE_APPSTREAM_COMPOSE_API_IS_SUBJECT_TO_CHANGE'
]

asgen_lib = static_library(
  'asgenlib',
  [asgencpp_src, asgencpp_hdr, defines_h, backends_src],
  dependencies: asgen_deps,
  cpp_args: asgen_args,
)

asgen_lib_dep = declare_dependency(
  link_with: asgen_lib,
  include_directories: [src_dir],
  dependencies: asgen_deps,
  compile_args: asgen_args,
)

asgen_exe = executable('appstream-generator',
  ['main.cpp'],
  dependencies: [
    asgen_lib_dep,
    backward_deps,
  ],
  install: true
)
