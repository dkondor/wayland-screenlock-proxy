libgwater_wayland_inc = include_directories('.')
libgwater_wayland_dep = [ wayland_client, glib ]
libgwater_wayland_lib = static_library('libgwater-wayland', files(
        'libgwater-wayland.h',
        'libgwater-wayland.c',
    ),
    dependencies: libgwater_wayland_dep,
    include_directories: libgwater_wayland_inc,
)

libgwater_wayland = declare_dependency(link_with: libgwater_wayland_lib, include_directories: libgwater_wayland_inc, dependencies: libgwater_wayland_dep)
