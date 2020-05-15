
conf_data = configuration_data()
conf_data.set('datadir', join_paths(get_option('prefix'), get_option('datadir'), 'appstream'))
conf_data.set('asgen_version', asgen_version)
configure_file(input : 'defines.d.in',
               output: 'defines.d',
               configuration: conf_data
)

data_import_dirs = include_directories('../../data')

#
# Sources
#
asgen_sources = [
    '../app.d',
    'bindings/appstream_utils.d',
    'bindings/cairo.d',
    'bindings/fontconfig.d',
    'bindings/freetype.d',
    'bindings/freetypeTypes.d',
    'bindings/gdkpixbuf.d',
    'bindings/libarchive.d',
    'bindings/lmdb.d',
    'bindings/pango.d',
    'bindings/rsvg.d',
    'bindings/soup.d',
    'containers/package.d',
    'containers/hash.d',
    'containers/hashmap.d',
    'containers/lists.d',
    'config.d',
    'contentsstore.d',
    'datainjectpkg.d',
    'datastore.d',
    'downloader.d',
    'engine.d',
    'extractor.d',
    'font.d',
    'handlers/desktopparser.d',
    'handlers/fonthandler.d',
    'handlers/iconhandler.d',
    'handlers/localehandler.d',
    'handlers/metainfoparser.d',
    'handlers/metainfovalidator.d',
    'handlers/package.d',
    'handlers/screenshothandler.d',
    'hint.d',
    'image.d',
    'logging.d',
    'mustache.d',
    'reportgenerator.d',
    'result.d',
    'utils.d',
    'zarchive.d',
     join_paths(build_root, 'src', 'asgen', 'defines.d'),
]

backend_sources = [
    'backends/interfaces.d',

    'backends/dummy/package.d',
    'backends/dummy/dummypkg.d',
    'backends/dummy/pkgindex.d',

    'backends/alpinelinux/package.d',
    'backends/alpinelinux/apkindexutils.d',
    'backends/alpinelinux/apkpkg.d',
    'backends/alpinelinux/apkpkgindex.d',

    'backends/archlinux/package.d',
    'backends/archlinux/alpkg.d',
    'backends/archlinux/alpkgindex.d',
    'backends/archlinux/listfile.d',

    'backends/debian/package.d',
    'backends/debian/debpkg.d',
    'backends/debian/debpkgindex.d',
    'backends/debian/tagfile.d',
    'backends/debian/debutils.d',

    'backends/ubuntu/package.d',
    'backends/ubuntu/ubupkg.d',
    'backends/ubuntu/ubupkgindex.d',

    'backends/rpmmd/package.d',
    'backends/rpmmd/rpmpkg.d',
    'backends/rpmmd/rpmpkgindex.d',
]

#
# Build and test
#
asgen_exe = executable('appstream-generator',
    [asgen_sources,
     backend_sources],
    include_directories: [src_dir,
                          gir_bind_dir],
    dependencies: [glibd_dep,
                   appstream_dep,
                   lmdb_dep,
                   archive_dep,
                   soup_dep,
                   cairo_dep,
                   gdkpixbuf_dep,
                   rsvg_dep,
                   freetype_dep,
                   fontconfig_dep,
                   pango_dep],
    link_with: [girbind_lib],
    d_import_dirs: [data_import_dirs],
    install: true
)

asgen_test_exe = executable('asgen_test',
    [asgen_sources,
    backend_sources],
    include_directories: [src_dir,
                          gir_bind_dir],
    dependencies: [glibd_dep,
                   appstream_dep,
                   lmdb_dep,
                   archive_dep,
                   soup_dep,
                   cairo_dep,
                   gdkpixbuf_dep,
                   rsvg_dep,
                   freetype_dep,
                   fontconfig_dep,
                   pango_dep],
    link_with: [girbind_lib],
    d_import_dirs: [data_import_dirs],
    d_unittest: true
)
test('asgen_tests', asgen_test_exe)
