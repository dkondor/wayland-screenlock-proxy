/*
 * simple_lock.c -- simple wrapper for ext-session-lock without creating actual lock surfaces
 * 
 * Copyright 2024 Daniel Kondor <kondor.dani@gmail.com>
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


#include <simple_lock.h>
#include <string.h>
#include <wayland-client.h>
#include <libgwater-wayland.h>
#include <ext-session-lock-v1-client-protocol.h>

static GWaterWaylandSource *source = NULL;
static struct ext_session_lock_manager_v1 *manager = NULL;
static struct ext_session_lock_v1 *current_lock = NULL;
static bool is_locked = false;
static SimpleLockCallback s_cb = NULL;
static void *s_cb_data = NULL;

static void _add (void*, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t) {
	if (strcmp (interface, ext_session_lock_manager_v1_interface.name) == 0)
		manager = (struct ext_session_lock_manager_v1*)wl_registry_bind (registry, name, &ext_session_lock_manager_v1_interface, 1u);
}

static void _remove (void*, struct wl_registry*, uint32_t) { }

static struct wl_registry_listener listener = { &_add, &_remove };


static void _locked (void*, struct ext_session_lock_v1*)
{
	is_locked = true;
	if (s_cb) s_cb (true, s_cb_data);
}

static void _finished (void*, struct ext_session_lock_v1*)
{
	simple_lock_unlock ();
}

static struct ext_session_lock_v1_listener lock_listener = { &_locked, &_finished };



/* Try to initialize the session lock interface. */
bool simple_lock_init ()
{
	if (source) return false;

	source = g_water_wayland_source_new (NULL, NULL);
	if (!source)
	{
		g_log ("LockWrapper", G_LOG_LEVEL_CRITICAL, "Cannot connect to Wayland display, not running in a Wayland session?");
		return false;
	}
	struct wl_display* display = g_water_wayland_source_get_display (source);
	if (!display) goto error;
	
	struct wl_registry* registry = wl_display_get_registry (display);
	if (!registry) goto error;

	wl_registry_add_listener (registry, &listener, NULL);
	wl_display_dispatch (display);
	wl_display_roundtrip (display);
	if (!manager) goto error;
	return true;
	
error:
	simple_lock_fini ();
	return false;
}

/* Try to lock the screen. */
void simple_lock_lock ()
{
	if (current_lock) return;
	if (!manager) return;
	is_locked = false;
	current_lock = ext_session_lock_manager_v1_lock (manager);
	ext_session_lock_v1_add_listener (current_lock, &lock_listener, NULL);
}

/* Unlock the screen. */
void simple_lock_unlock ()
{
	if (!current_lock) return;
	if (is_locked) ext_session_lock_v1_unlock_and_destroy (current_lock);
	else ext_session_lock_v1_destroy (current_lock);
	current_lock = NULL;
	if (s_cb) s_cb (false, s_cb_data);
}

void simple_lock_set_callback (SimpleLockCallback cb, void *user_data)
{
	s_cb = cb;
	s_cb_data = user_data;
}

void simple_lock_fini ()
{
	simple_lock_unlock ();
	
	if (manager)
	{
		ext_session_lock_manager_v1_destroy (manager);
		manager = NULL;
	}
	
	if (source)
	{
		g_water_wayland_source_free (source);
		source = NULL;
	}
}

