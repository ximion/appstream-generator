
conf_data = configuration_data()
conf_data.set('datadir', join_paths(get_option('prefix'), get_option('datadir'), 'appstream'))
conf_data.set('asgen_version', asgen_version)
configure_file(input : 'defines.d.in',
               output: 'defines.d',
               configuration: conf_data
)
