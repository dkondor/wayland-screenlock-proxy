/*
 * simple_lock.h -- simple wrapper for ext-session-lock without creating actual lock surfaces
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


#ifndef SIMPLE_LOCK_H
#define SIMPLE_LOCK_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Try to initialize the session lock interface. */
bool simple_lock_init (void);

/* Try to lock the screen. */
void simple_lock_lock (void);

/* Unlock the screen. */
void simple_lock_unlock (void);

/* Set a callback to signal when the screen is locked / unlocked. */
typedef void (*SimpleLockCallback) (bool, void*);
void simple_lock_set_callback (SimpleLockCallback cb, void *user_data);

/* free all resources */
void simple_lock_fini (void);

#ifdef __cplusplus
}
#endif

#endif

