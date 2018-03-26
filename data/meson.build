
# data
install_data('asgen-hints.json', install_dir: 'share/appstream')
install_data('hicolor-theme-index.theme', install_dir: 'share/appstream')
install_data('org.freedesktop.appstream.generator.metainfo.xml', install_dir: join_paths (get_option ('datadir'), 'metainfo'))

# templates
#install_subdir('data/templates/', install_dir: 'share/appstream') # FIXME: Doesn't handle dir symlinks correctly
meson.add_install_script(source_root + '/contrib/setup/meson-install-templates.sh')
