/*
 * idle_notify.h -- wrapper to use the ext_idle_notify protocol
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


#ifndef IDLE_WRAPPER_H
#define IDLE_WRAPPER_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Try to initialize the idle notify interface. */
bool idle_notify_init (void);

/* Set a callback to signal idleness. */
typedef void (*IdleNotifyCallback) (void*);
void idle_notify_set_callback (IdleNotifyCallback cb, void *user_data);

/* Set the idle timeout (in seconds). Note: if there was already a
 * timeout, this will restart waiting for idle.
 * A timeout of 0 disables notifications */
void idle_notify_set_timeout (unsigned int timeout);

/* free all resources */
void idle_notify_fini (void);

#ifdef __cplusplus
}
#endif

#endif


