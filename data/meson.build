
# data
install_data('asgen-hints.json', install_dir: 'share/appstream')
install_data('hicolor-theme-index.theme', install_dir: 'share/appstream')

metainfo_file = files('org.freedesktop.appstream.generator.metainfo.xml')
install_data(metainfo_file, install_dir: join_paths (get_option ('datadir'), 'metainfo'))
appstreamcli_exe = find_program('appstreamcli', required: false)
if appstreamcli_exe.found()
  # Validate our MetaInfo file
  test('asgen-validate_metainfo',
    appstreamcli_exe,
    args: ['validate',
           '--no-net', '--pedantic',
           metainfo_file]
  )
endif

# templates
#install_subdir('data/templates/', install_dir: 'share/appstream') # FIXME: Doesn't handle dir symlinks correctly
meson.add_install_script(source_root + '/contrib/setup/meson-install-templates.sh')
