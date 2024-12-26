project(
	'lock_wrapper',
	'c',
	'vala',
	version: '0.0.1',
	license: 'GPLv3+',
	meson_version: '>=1.0.0',
	default_options: [
        'c_std=c11',
	],
)

gio      = dependency('gio-2.0')
gio_unix = dependency('gio-unix-2.0')
glib     = dependency('glib-2.0', version: '>=2.78')
gobject  = dependency('gobject-2.0')
posix    = meson.get_compiler('vala').find_library('posix')


add_project_arguments(['--vapidir', meson.current_source_dir()], language: 'vala')
add_project_arguments(['--pkg', 'simple_lock'], language: 'vala')

# wayland-scanner -- needed for using the ext-session-lock protocol
wayland_client = dependency('wayland-client', version: '>=1.1.91')
wayland_scanner = find_program('wayland-scanner')
wayland_protos = dependency('wayland-protocols', version: '>=1.25')
wl_protocol_dir = wayland_protos.get_variable('pkgdatadir')

subdir('gwater-wayland')

wayland_scanner_code = generator(
	wayland_scanner,
	output: '@BASENAME@-protocol.c',
	arguments: ['private-code', '@INPUT@', '@OUTPUT@'],
)

wayland_scanner_client = generator(
	wayland_scanner,
	output: '@BASENAME@-client-protocol.h',
	arguments: ['client-header', '@INPUT@', '@OUTPUT@'],
)

client_protocols = [
    wl_protocol_dir + '/staging/ext-session-lock/ext-session-lock-v1.xml'
]

wl_protos_client_src = []
wl_protos_headers = []

foreach p : client_protocols
	xml = join_paths(p)
	wl_protos_headers += wayland_scanner_client.process(xml)
	wl_protos_client_src += wayland_scanner_code.process(xml)
endforeach

lib_lock_protos = static_library('lock_protos', wl_protos_client_src + wl_protos_headers,
	dependencies: [wayland_client]) # for the include directory

protos = declare_dependency(
	link_with: lib_lock_protos,
	sources: wl_protos_headers,
)

simple_lock = static_library('simple_lock', 'simple_lock.c',
	dependencies: [wayland_client, protos, libgwater_wayland])

simple_lock_dep = declare_dependency(
	link_with: [simple_lock],
	include_directories: include_directories('.')
)

lock_wrapper = executable('wayland-screenlock-proxy', ['lock_wrapper.vala', 'dbus_interfaces.vala'],
		dependencies: [glib, gobject, gio, gio_unix, posix, simple_lock_dep],
		install: true, install_dir: 'libexec')

conf_data = configuration_data()
conf_data.set('libexec', get_option('prefix') / 'libexec')

configure_file(configuration: conf_data, input: 'wayland-screenlock-proxy.service.in',
	output: '@BASENAME@', install_dir: 'lib/systemd/user')


