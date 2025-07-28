
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

# static library of bindings automatically generated from GIR
asgencpp_lib = static_library(
  'asgencpp',
  [asgencpp_src, asgencpp_hdr],
  dependencies: [
    glib_dep,
    appstream_dep,
    ascompose_dep,
    lmdb_dep,
    archive_dep,
    curl_dep
  ],
)


# D code
#subdir('asgen')
