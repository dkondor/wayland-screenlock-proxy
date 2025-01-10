
wayfire  = dependency('wayfire', version: '>=0.8.0')

locklib = shared_module('screenlock_integration', 'screenlock_integration.cpp',
	dependencies: [wayfire],
	install: true,
	install_dir: wayfire.get_variable(pkgconfig: 'plugindir'),
	cpp_args: ['-Wno-unused-parameter', '-Wno-format-security','-DWAYFIRE_PLUGIN', '-DWLR_USE_UNSTABLE'],
	link_args: '-rdynamic')

install_data('screenlock_integration.xml', install_dir: wayfire.get_variable(pkgconfig: 'metadatadir'))
install_data('screenlock_integration.ini')
