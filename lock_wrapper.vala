/*
 * lock-wrapper.vala -- simple proxy between systemd-logind and a screen locker
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

using GLib;

abstract class lock_wrapper_backend : Object
{
	public bool is_locked { get; protected set; default = false; }
	public MainLoop loop { get; construct; }
	public bool init_failed { get; protected set; default = false; }
	
	protected interfaces.Manager manager = null;
	protected interfaces.Session session = null;
	protected UnixInputStream inhibitor  = null;
	protected bool should_stop_inhibitor = false;
	private string session_id = null;
	protected GLib.ObjectPath session_path = null;
	
	public abstract void do_lock ();
	public abstract void do_unlock ();
	
	protected lock_wrapper_backend (string _session_id, bool allow_unlock)
	{
		session_id = _session_id;
		
		try
		{
			manager = Bus.get_proxy_sync (BusType.SYSTEM, "org.freedesktop.login1", "/org/freedesktop/login1");
			session_path = manager.get_session (session_id);
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_DEBUG, "session_path: %s\n", (string)session_path);
			session = Bus.get_proxy_sync (BusType.SYSTEM, "org.freedesktop.login1", session_path);
		}
		catch (Error e)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot create Dbus proxies: %s\n", e.message);
			loop.quit();
			init_failed = true;
			return;
		}
		
		manager.prepare_for_sleep.connect (sleep_status_changed);
		try { inhibitor = manager.inhibit ("sleep", "lock_wrapper", "Ensure screen is locked before sleep", "delay"); }
		catch (Error e)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot create sleep inhibitor: %s\n", e.message);
		}
		session.lock.connect (do_lock);
		if (allow_unlock) session.unlock.connect (do_unlock);
	}
	
	construct { loop = new MainLoop (); }
	
	private void sleep_status_changed (bool start)
	{
		if (start)
		{
			if (is_locked)
			{
				stop_inhibitor ();
				return;
			}
			should_stop_inhibitor = true;
			do_lock ();
		}
		else
		{
			try { inhibitor = manager.inhibit ("sleep", "lock_wrapper", "Ensure screen is locked before sleep", "delay"); }
			catch (Error e)
			{
				log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot create sleep inhibitor: %s\n", e.message);
			}
		}
	}
	
	protected void stop_inhibitor ()
	{
		try { inhibitor.close(); }
		catch (Error e)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_WARNING, "Error releasing inhibitor: %s\n", e.message);
		}
		inhibitor = null;
		should_stop_inhibitor = false;
	}
	
	protected void check_child_status (int status)
	{
		bool res = true;
		try { res = Process.check_wait_status (status); }
		catch (Error e) { res = false; } // we don't differentiate between non-zero exit and crash
		
		if (res)
		{
			// successful exit, we are now unlocked
			is_locked = false;
			try { session.set_locked_hint (false); }
			catch (Error e)
			{
				log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Error with DBus communication: %s\n", e.message);
				loop.quit (); // it does not make sense to try to continue, might be better to try respawning
			}
		}
		else
		{
			// try to lock again, since the screenlocker crashing will
			// leave the screen in a locked state
			do_lock ();
		}
	}
	
	~lock_wrapper_backend ()
	{
		manager.prepare_for_sleep.disconnect (sleep_status_changed);
		if (inhibitor != null) stop_inhibitor ();
	}
}

class pipefd_backend_base : lock_wrapper_backend
{
	private Pid child_pid = -1;
	protected string exec = null;
	protected string pipe_arg = null;
	protected int sig = Posix.Signal.TERM;
	
	protected pipefd_backend_base (string _session_id, bool allow_unlock)
	{
		base (_session_id, allow_unlock);
	}
	
	public override void do_lock ()
	{
		if (child_pid > 0) return; // already locked
		
		int pipe_fds[2];
		try
		{
			if (!Unix.open_pipe (pipe_fds, Posix.O_CLOEXEC))
			{
				log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot open a pipe!\n");
				return;
			}
		}
		catch (Error e)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot open a pipe: %s\n", e.message);
			return;
		}
		
		int fds[1];
		fds[0] = pipe_fds[1]; // write end of the pipe
		
		string args[] = {exec, pipe_arg, fds[0].to_string(), null};
		try
		{
			Process.spawn_async_with_pipes_and_fds (null, args, null, SpawnFlags.DO_NOT_REAP_CHILD | SpawnFlags.SEARCH_PATH /* | SpawnFlags.STDOUT_TO_DEV_NULL  | SpawnFlags.STDERR_TO_DEV_NULL  */,
				null, -1, -1, -1, fds, fds, out child_pid, null, null, null);
		} catch (SpawnError err)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot start %s: %s\n\n", args[0], err.message);
		}
		
		FileUtils.close(pipe_fds[1]);
		
		IOChannel ready = new IOChannel.unix_new (pipe_fds[0]);
		ready.set_close_on_unref (true);
		ready.add_watch (IOCondition.IN, (ch, cond) => {
			try
			{
				if (child_pid > 0)
				{
					session.set_locked_hint (true);
					is_locked = true;
					if (should_stop_inhibitor) stop_inhibitor ();
				}
			} catch (Error e)
			{
				log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Error with DBus communication: %s\n", e.message);
				loop.quit (); // it does not make sense to try to continue, might be better to try restarting
			}
			return false;
		});
		
		ChildWatch.add (child_pid, (pid, status) => {
			Process.close_pid (pid);
			// this can be false if we receive an unlock and a lock request
			// in short succession and we spawn a new instance of swaylock
			// before the previous one exited
			if (child_pid == pid)
			{
				child_pid = -1;
				check_child_status (status);
			}
		});
	}
	
	public override void do_unlock ()
	{
		if (child_pid == -1) return;
		if (sig == -1) return; // e.g. waylock does not support a clean shutdown
		Posix.kill (child_pid, sig);
		child_pid = -1; // so that we are able to lock again right away
	}
}

class swaylock_backend : pipefd_backend_base
{
	public swaylock_backend (string _session_id, bool allow_unlock)
	{
		base (_session_id, allow_unlock);
		exec = "swaylock";
		pipe_arg = "-R";
		sig = Posix.Signal.USR1;
	}
}

class waylock_backend : pipefd_backend_base
{
	public waylock_backend (string _session_id, bool allow_unlock)
	{
		base (_session_id, allow_unlock); // note: allow_unlock is ignored
		exec = "waylock";
		pipe_arg = "-ready-fd";
		sig = -1; // not possible to unlock by us
	}
}

class gtklock_backend : lock_wrapper_backend
{
	private Pid child_pid = -1;
	private interfaces.Properties props = null;
	
	public gtklock_backend (string _session_id, bool allow_unlock)
	{
		base (_session_id, allow_unlock);
		
		try { props = Bus.get_proxy_sync (BusType.SYSTEM, "org.freedesktop.login1", session_path); }
		catch (Error e)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Failed to create DBus proxies: %s\n", e.message);
			loop.quit ();
			init_failed = true;
			return;
		}
		props.properties_changed.connect (props_changed);
	}
	
	public override void do_lock ()
	{
		if (child_pid > 0) return; // already locked
		
		string args[] = {"gtklock", "-L", "dbus-send --system --print-reply --dest=org.freedesktop.login1 /org/freedesktop/login1/session/_32 org.freedesktop.login1.Session.SetLockedHint boolean:true", null};
		try
		{
			Process.spawn_async (null, args, null, SpawnFlags.DO_NOT_REAP_CHILD | SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL, // | SpawnFlags.STDERR_TO_DEV_NULL
				null, out child_pid);
		} catch (SpawnError err)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot start gtklock: %s\n\n", err.message);
		}
		
		ChildWatch.add (child_pid, (pid, status) => {
			Process.close_pid (pid);
			// this can be false if we receive an unlock and a lock request
			// in short succession and we spawn a new instance of swaylock
			// before the previous one exited
			if (child_pid == pid)
			{
				child_pid = -1;
				check_child_status (status);
			}
		});
	}
	
	public override void do_unlock ()
	{
		if (child_pid == -1) return;
		Posix.kill (child_pid, Posix.Signal.TERM);
		child_pid = -1; // so that we are able to lock again right away
	}
	
	private void props_changed (string interface_name, GLib.HashTable<string, GLib.Variant> changed_properties, string[] invalidated_properties)
	{
		if (interface_name == "org.freedesktop.login1.Session")
		{
			unowned GLib.Variant? val = changed_properties.get ("LockedHint");
			if (val != null && val.get_boolean())
			{
				// successfully locked, might need to remove our inhibitor
				if (should_stop_inhibitor) stop_inhibitor ();
			}
		}
	}
}

#if ENABLE_GDM
class gdm_lock : lock_wrapper_backend
{
	private interfaces.LocalDisplayFactory dsp = null;
	
	public gdm_lock (string _session_id, bool allow_unlock)
	{
		base (_session_id, true); // always need to allow to unlock the screen
		
		if (!SimpleLock.init ()) init_failed = true;
		else
		{
			try { dsp = Bus.get_proxy_sync (BusType.SYSTEM, "org.gnome.DisplayManager", "/org/gnome/DisplayManager/LocalDisplayFactory"); }
			catch (Error e)
			{
				log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot create Gdm DBus proxy: %s\n", e.message);
				init_failed = true;
			}
		}
	}
	
	public override void do_lock ()
	{
		SimpleLock.lock ();
		try { dsp.create_transient_display(); }
		catch (Error e)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Error communicating with Gdm: %s\n", e.message);
			// note: in this case, we don't know if we could switch to Gdm's VT
			// if this happened, it is better to stay locked to ensure a VT switch
			// does not result in an unlocked session
		}
	}
	
	public override void do_unlock ()
	{
		SimpleLock.unlock ();
	}
	
	~gdm_lock ()
	{
		SimpleLock.fini ();
	}
}
#endif

static bool check_backend (string backend)
{
	string args[] = {"which", "-s", backend, null};
	int status;
	bool res = false;
	try {
		if (Process.spawn_sync (null, args, null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL,
				null, null, null, out status))
			res = Process.check_wait_status (status);
	}
	catch (Error e)
	{
		log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot run 'which': %s\n", e.message);
	}
	return res;
}

public static int main(string[] args)
{
	string session_id = null;
	string backend = null;
	bool allow_unlock = false;
	uint idle_timeout = 0;
	
	// read config
	try
	{
		string config_location = Environment.get_variable ("XDG_CONFIG_HOME");
		if (config_location == null) config_location = Environment.get_variable ("HOME") + "/.config";
		config_location += "/wayland-screenlock-proxy/config.ini";
		
		KeyFile config = new KeyFile ();
		config.load_from_file (config_location, KeyFileFlags.NONE);
		
		if (config.has_group ("General"))
		{
			if (config.has_key ("General", "allow_unlock")) allow_unlock = config.get_boolean ("General", "allow_unlock");
			if (config.has_key ("General", "backend")) backend = config.get_string ("General", "backend");
			if (config.has_key ("General", "idle_lock_timeout"))
			{
				int tmp = config.get_integer ("General", "idle_lock_timeout");
				idle_timeout = tmp > 0 ? tmp : 0;
			}
		}
	}
	catch (Error e)
	{
		log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_WARNING, "Cannot read config file, will use defaults (%s)\n", e.message);
	}
	
	// process command line (overrides config)
	for (int i = 1; i < args.length; i++)
	{
		if (args[i] == "-i")
		{
			session_id = args[i+1];
			i++;
		}
		else if (args[i] == "-b")
		{
			backend = args[i+1];
			i++;
		}
		else if (args[i] == "-u")
		{
			allow_unlock = true;
		}
		else if (args[i] == "-I")
		{
			if (! uint.try_parse (args[i+1], out idle_timeout))
			{
				stderr.printf ("Invalid timeout argument: %s\n", args[i+1]);
				return 1;
			}
			i++;
		}
		else
		{
			stderr.printf ("Unknown parameter: %s\n", args[i]);
			return 1;
		}
	}
	
	if (session_id == null)
	{
		session_id = Environment.get_variable ("XDG_SESSION_ID");
		if (session_id == null)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "No session ID provided!\n");
			return 1;
		}
	}
	
	if (backend != null)
	{
		if (backend == "swaylock" || backend == "gtklock" || backend == "waylock")
		{
			if (! check_backend (backend))
			{
				log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Requested screenlocker ('%s') is not available\n", backend);
				return 1;
			}
		}
		else
#if ENABLE_GDM
		if (backend != "gdm")
#endif
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Unknown screenlocker backend requested: %s\n", backend);
			return 1;
		}
	} else
	{
		if (check_backend ("gtklock")) backend = "gtklock";
		else if (check_backend ("swaylock")) backend = "swaylock";
		else if (check_backend ("waylock")) backend = "waylock";
		else
		{
			//  note: Gdm backend is not used by default
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "No supported screenlocker found");
			return 1;
		}
	}
	
	lock_wrapper_backend lw = null;
#if ENABLE_GDM
	if (backend == "gdm") lw = new gdm_lock (session_id, true); // always allow unlocking
	else
#endif
	if (backend == "swaylock") lw = new swaylock_backend (session_id, allow_unlock);
	else if (backend == "waylock") lw = new waylock_backend (session_id, allow_unlock);
	else lw = new gtklock_backend (session_id, allow_unlock);
	if (lw.init_failed) return 1; // error message already displayed
	
	if (idle_timeout > 0)
	{
		if (!IdleNotify.init())
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Compositor does not support the ext-idle-notify-v1 protocol, cannot automatically lock the screen on inactivity");
		}
		else
		{
			IdleNotify.set_callback (lw.do_lock);
			IdleNotify.set_timeout (idle_timeout);
		}
	}
	
	var sigterm = new GLib.Unix.SignalSource (Posix.Signal.TERM);
	sigterm.set_callback ( () => {
		lw.loop.quit ();
		return false;
	});
	sigterm.attach (null);
	
	lw.loop.run ();
	lw.do_unlock ();
	IdleNotify.fini ();
	
	return 0;
}

