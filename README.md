# wayland-screenlock-proxy
Simple proxy service to better integrate Wayland screenlockers with systemd-logind.

This is achieved by connecting to the [DBus interface](https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.login1.html)
of `systemd-logind` (available at the `org.freedesktop.login1` address) and reacting to relevant events.

The following are supported:
 - Locking the screen in response to the `Lock` signal on the current session (e.g. when running `loginctl lock-session`).
 - Unlocking the screen in response to the `Unlock` signal (e.g. when running `loginctl unlock-session` -- only if the screenlocker allows a clean exit; not available with `waylock`).
 - Locking the screen when the system is suspended (in response to the `PrepareForSleep` signal), and delaying suspend until the screen is succesfully locked.
 - Locking the screen after being idle for a specified time (using the `ext-idle-notify-v1` protocol)
 - Setting the `LockedHint` property on the corresponding session according to the lock state.
 - Restarting a screenlocker that crashed or exited without unlocking the screen.
 - Running as a systemd service.
 - Plugin to integrate with Wayfire and allow graphical configuration with WCM.

## Requirements

You need to be running a [systemd](https://systemd.io) session. You can check this by e.g. running `loginctl session-status`.
See e.g. [here](https://github.com/dkondor/wayfire-gnome) for setting up a minimal systemd session with [Wayfire](https://github.com/WayfireWM/wayfire).

One of the supported screenlockers need to be installed:
 - [Swaylock](https://github.com/swaywm/swaylock)
 - [Gtklock](https://github.com/jovanlanik/gtklock)
 - [Waylock](https://codeberg.org/ifreund/waylock) (note: unlocking in response to a signal is not supported)

You need to be running a compositor that supports the `ext-session-lock-v1` protocol, such as a recent verson of
[Wayfire](https://github.com/WayfireWM/wayfire), [Labwc](https://labwc.github.io/), [sway](https://swaywm.org/), etc.

Dependencies:
 - [meson](https://mesonbuild.com)
 - [Valac](https://gitlab.gnome.org/GNOME/vala)
 - Libraries (should be standard on most systems) `gio-2.0, gio-unix-2.0, glib-2.0 (version >= 2.78), gobject-2.0, wayland-client, wayland-scanner`
 - [wayland-protocols](https://gitlab.freedesktop.org/wayland/wayland-protocols) version >= 1.27
 - optionally [Wayfire](https://github.com/WayfireWM/wayfire) to build a plugin for better integration and [WCM](https://github.com/WayfireWM/wcm) for graphical configuration

## Building and installing

The standard way to build is with Meson:

```
meson setup -Dbuildtype=release build
ninja -C build
sudo ninja -C build install
```

Note: the Wayfire plugin will be built automatically if Wayfire is detected. You can explicitly disable (or enable) it with the `-Denable_wayfire_plugin` option.


## Running

The `wayland-screenlock-proxy` binary is installed in the `libexec` directory in the installation prefix, e.g. `/usr/local/libexec/` by default.
It can be run manually by specifying the full path. The recommended way to run it is with systemd:
```
systemctl --user start wayland-screenlock-proxy.service
```

To stop it, run (note that this will unlock the screen):
```
systemctl --user stop wayland-screenlock-proxy.service
```

To start automatically, run:
```
systemctl --user enable wayland-screenlock-proxy.service
```
or alternatively, add a `Wants=wayland-screenlock-proxy.service` to the systemd target of your desktop session.
Note: it is important that wayland-screenlock-proxy is started after your Wayland compositor and that the `WAYLAND_DISPLAY`
environment variable is set in your systemd environment. This is typically achieved by making a systemd unit for your compositor
that is a prerequisite of the `graphical-session.target` and running `systemctl --user import-environment WAYLAND_DISPLAY`
from the compositor once it has initialized. See e.g. [here](https://github.com/swaywm/sway/wiki#systemd-and-dbus-activation-environments)
for the case of Sway, but similar considerations apply to other cases.

If `wayland-screenlock-proxy` is running, you can lock your screen by the following command:
```
loginctl lock-session
```
E.g. you can set a keybinding in your compositor's configuration (or see below for using the Wayfire plugin).

If enabled in the configuration, you can also unlock the screen, by running (e.g. from a different TTY):
```
loginctl unlock-session
```


## Configuration

### Stand-alone mode

Configuration is read from `$XDG_CONFIG_HOME/wayland-screenlock-proxy/config.ini` (by default `~/.config/wayland-screenlock-proxy/config.ini`).
An example configuration is in the `config.ini` file provided here (installed under `{prefix}/share/wayland-screenlock-proxy/config.ini`). Currently,
the following options are supported (all should be in the `General` section of the file):
 - `allow_unlock`: whether to allow unlocking the screen in response to the "Unlock" signal from systemd (e.g. by running `loginctl unlock-session`). If this is false, unlocking is only possible from the screen locker (default: false)
 - `backend`: name of the screenlocker program to use (see below; default: try all in the order shown below)
 - `idle_lock_timeout`: automatically lock the screen after being idle for this time (in seconds; 0 to disable automatic locking)

Configuration will be dynamically updated whenever the config file is edited.

### Wayfire plugin mode

If the Wayfire plugin is installed and wayland-screenlock-proxy is running under Wayfire, configuration will
be instead stored in Wayfire's config file (by deafult `~/.config/wayfire.ini`). This allows changing options
graphically with WCM: you can use the "Lockscreen integration" panel in the "Desktop" category and set the
above settings from there. The same keys are used as in stand-alone mode, stored under the `screenlock_integration`
section.

Notes:
 - Configuration will always be read from Wayfire's config, regardless whether the plugin is enabled or not.
 - Enabling the plugin will ensure that wayland-screenlock-proxy is started automatically, and also allows setting a keybinding to lock the screen directly (so no need to set it up using the "Command" plugin).
 - When running under any other compositor, the stand-alone config file is used.
 - Whether running under Wayfire will be determined by the presence of the `WAYFIRE_CONFIG_FILE` environment variable. Wayfire sets it for any app launched by itself. If wayland-screenlock-proxy is launched as a systemd service, you might need to ensure that this environment variable is set, by either:
   * Setting it in your session's startup script or environment configuration.
   * Ensuring that Wayfire calls `systemctl --user import-environment` including the `WAYFIRE_CONFIG_FILE` variable, e.g. having the following among the autostart items (of course you might want to add more variables if needed):
        ```
        a002_systemd = systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY WAYFIRE_SOCKET WAYFIRE_CONFIG_FILE && systemd-notify --ready
        ```
 - You can manually disable using Wayfire's config by creating a config file named `screenlock_integration.ini` under `$XDG_CONFIG_HOME/wayland-screenlock-proxy` with the following contents: 
    ```
    [compositor_integration]
    wayfire = false
    ```

### Command line options

If run from the command line, the following parameters can be used:
 - `-u`: allow unlocking
 - `-b [backend]`: select the screenlocker to use
 - `-I [timeout]`: set the idleness timeout

E.g. to use swaylock, run as:
```
/usr/local/libexec/wayland-screenlock-proxy -b swaylock
```

These take precedence over any value set in the configuration files.


### Supported backends for locking the screen

The following backends are supported:
 - `swaylock`: https://github.com/swaywm/swaylock
 - `gtklock`: https://github.com/jovanlanik/gtklock
 - `waylock`: https://codeberg.org/ifreund/waylock (does not support unlocking in response to a signal)
 - `gdm`: experimental backend that locks the screen without displaying any UI and switches to the gdm login manager to do authentication.
This requires that you use actually use [gdm](https://gitlab.gnome.org/GNOME/gdm) and also a compositor which will create an empty lock surface if
none is provided by the `ext-session-lock-v1` client. Note that this is not built by default, you need to enable it by adding the `-Denable_gdm=true`
option to meson.

## Planned features

 - Make the gdm backend more robust and add support for other display managers as well.

