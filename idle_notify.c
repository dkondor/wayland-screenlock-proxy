/*
 * idle_notify.c -- wrapper to use the ext_idle_notify protocol
 * 
 * Copyright 2025 Daniel Kondor  <kondor.dani@gmail.com>
 * 
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 * 
 */

#include <idle_notify.h>
#include <string.h>
#include <wayland-client.h>
#include <libgwater-wayland.h>
#include <ext-idle-notify-v1-client-protocol.h>

static GWaterWaylandSource *source = NULL;
static struct ext_idle_notifier_v1 *manager = NULL;
static struct ext_idle_notification_v1 *notify = NULL;
static struct wl_seat* seat = NULL;
static IdleNotifyCallback s_cb = NULL;
static void *s_user_data = NULL;

static void _add (void*, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	if (strcmp (interface, ext_idle_notifier_v1_interface.name) == 0)
		manager = (struct ext_idle_notifier_v1*)wl_registry_bind (registry, name, &ext_idle_notifier_v1_interface, 1u);
	else if (strcmp (interface, wl_seat_interface.name) == 0)
		seat = (struct wl_seat*)wl_registry_bind (registry, name, &wl_seat_interface, version);
}

static void _remove (void*, struct wl_registry*, uint32_t) { }

static struct wl_registry_listener listener = { &_add, &_remove };


static void _idled (void*, struct ext_idle_notification_v1*)
{
	if (s_cb) s_cb (s_user_data);
}

static void _resumed (void*, struct ext_idle_notification_v1*) { }

static struct ext_idle_notification_v1_listener notify_listener = { &_idled, &_resumed };



/* Try to initialize the idle notify interface. */
bool idle_notify_init (void)
{
	if (source) return false;
	
	source = g_water_wayland_source_new (NULL, NULL);
	if (!source)
	{
		g_log ("IdleNotify", G_LOG_LEVEL_CRITICAL, "Cannot connect to Wayland display, not running in a Wayland session?");
		return false;
	}
	struct wl_display* display = g_water_wayland_source_get_display (source);
	if (!display) goto error;
	
	struct wl_registry* registry = wl_display_get_registry (display);
	if (!registry) goto error;

	wl_registry_add_listener (registry, &listener, NULL);
	wl_display_dispatch (display);
	wl_display_roundtrip (display);
	if (! (manager && seat) ) goto error;
	return true;
	
error:
	idle_notify_fini ();
	return false;
}

void idle_notify_set_callback (IdleNotifyCallback cb, void *user_data)
{
	s_cb = cb;
	s_user_data = user_data;
}

void idle_notify_set_timeout (unsigned int timeout)
{
	if (notify)
	{
		ext_idle_notification_v1_destroy (notify);
		notify = NULL;
	}
	if (!timeout) return;
	// timeout parameter below should be in ms
	if (timeout >= UINT_MAX / 1000) timeout = UINT_MAX;
	else timeout *= 1000;
	
	notify = ext_idle_notifier_v1_get_idle_notification (manager, timeout, seat);
	ext_idle_notification_v1_add_listener (notify, &notify_listener, NULL);
}

void idle_notify_fini (void)
{
	if (notify)
	{
		ext_idle_notification_v1_destroy (notify);
		notify = NULL;
	}
	
	if (manager)
	{
		ext_idle_notifier_v1_destroy (manager);
		manager = NULL;
	}
	
	if (seat)
	{
		wl_seat_release (seat);
		seat = NULL;
	}
	
	if (source)
	{
		g_water_wayland_source_free (source);
		source = NULL;
	}
	
	s_cb = NULL;
	s_user_data = NULL;
}


