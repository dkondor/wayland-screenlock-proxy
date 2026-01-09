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
	public bool init_failed { get; protected set; default = false; }
	public bool always_allow_unlock { get; construct; default = false; }
	public lock_wrapper_listener parent { get; construct; }
	public abstract void do_lock ();
	public abstract void do_unlock ();
	
	protected lock_wrapper_backend (lock_wrapper_listener _parent, bool _always_allow_unlock = false) {
		Object (
			parent: _parent,
			always_allow_unlock: _always_allow_unlock
		);
	}
	
	protected void check_child_status (int status)
	{
		bool res = true;
		try { res = Process.check_wait_status (status); }
		catch (Error e) { res = false; } // we don't differentiate between non-zero exit and crash
		
		if (res)
		{
			// successful exit, we are now unlocked
			parent.set_locked_state (false);
		}
		else
		{
			// try to lock again, since the screenlocker crashing will
			// leave the screen in a locked state
			do_lock ();
		}
	}
	
	public virtual void props_changed (GLib.Variant changed_properties, string[] invalidated_properties)
	{
		// no-op by default
	}
}


class lock_wrapper_listener : Object
{
	public bool init_failed { get; protected set; default = false; }
	public bool allow_unlock = false;
	public bool is_locked { get; protected set; default = false; }
	public bool lock_on_inactive = false;
	
	private interfaces.Manager manager = null;
	private interfaces.Session session = null;
	private UnixInputStream inhibitor  = null;
	private bool should_stop_inhibitor = false;
	private string session_id = null;
	public GLib.ObjectPath session_path { get; protected set; default = null; }
	public signal void locked_changed (bool locked);
	
	public lock_wrapper_backend backend = null;
	
	public void do_lock_base () {
		if (backend != null) backend.do_lock ();
	}
	public void do_unlock_base () {
		// ensure that the backend survives until the end of the call
		// as we might end up in ScreenlockProxy.replace_backend which
		// would destroy it
		lock_wrapper_backend tmp = backend;
		if (tmp != null && (allow_unlock || tmp.always_allow_unlock)) tmp.do_unlock ();
	}
	
	public lock_wrapper_listener (string _session_id, bool _allow_unlock)
	{
		session_id = _session_id;
		allow_unlock = _allow_unlock;
		
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
			init_failed = true;
			return;
		}
		
		manager.prepare_for_sleep.connect (sleep_status_changed);
		try { inhibitor = manager.inhibit ("sleep", "lock_wrapper", "Ensure screen is locked before sleep", "delay"); }
		catch (Error e)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot create sleep inhibitor: %s\n", e.message);
		}
		session.lock.connect (do_lock_base);
		session.unlock.connect (do_unlock_base);
		session.g_properties_changed.connect (props_changed);
	}
	
	private void props_changed (GLib.Variant changed_properties, string[] invalidated_properties)
	{
		if (backend != null) backend.props_changed (changed_properties, invalidated_properties);
		
		if (!lock_on_inactive || is_locked) return;
		
		GLib.Variant? val = changed_properties.lookup_value ("Active", GLib.VariantType.BOOLEAN);
		if (val != null && !val.get_boolean ())
		{
			do_lock_base ();
		}
	}
	
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
			do_lock_base ();
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
	
	public void set_locked_state (bool locked)
	{
		try {
			session.set_locked_hint (locked);
			if (locked && should_stop_inhibitor) stop_inhibitor ();
		}
		catch (Error e)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Error with DBus communication: %s\n", e.message);
			// TODO: loop.quit (); // it does not make sense to try to continue, might be better to try respawning
		}
		
		is_locked = locked;
		locked_changed (locked);
	}
	
	~lock_wrapper_listener ()
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
	
	protected pipefd_backend_base (lock_wrapper_listener _parent)
	{
		base (_parent);
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
			if (child_pid > 0) parent.set_locked_state (true);
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
		parent.set_locked_state (false);
	}
}

class swaylock_backend : pipefd_backend_base
{
	public swaylock_backend (lock_wrapper_listener _parent)
	{
		base (_parent);
		exec = "swaylock";
		pipe_arg = "-R";
		sig = Posix.Signal.USR1;
	}
}

class waylock_backend : pipefd_backend_base
{
	public waylock_backend (lock_wrapper_listener _parent)
	{
		base (_parent);
		exec = "waylock";
		pipe_arg = "-ready-fd";
		sig = -1; // not possible to unlock by us
	}
}

class gtklock_backend : lock_wrapper_backend
{
	private Pid child_pid = -1;
	
	public gtklock_backend (lock_wrapper_listener _parent)
	{
		base (_parent);
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
		parent.set_locked_state (false);
	}
	
	public override void props_changed (GLib.Variant changed_properties, string[] invalidated_properties)
	{
		GLib.Variant? val = changed_properties.lookup_value ("LockedHint", GLib.VariantType.BOOLEAN);
		if (val != null && val.get_boolean ())
		{
			parent.set_locked_state (true);
		}
	}
}

#if ENABLE_GDM
class gdm_lock : lock_wrapper_backend
{
	private interfaces.LocalDisplayFactory dsp = null;
	
	public gdm_lock (lock_wrapper_listener _parent)
	{
		base (_parent, true);
		
		if (!SimpleLock.init ()) init_failed = true;
		else
		{
			try { dsp = Bus.get_proxy_sync (BusType.SYSTEM, "org.gnome.DisplayManager", "/org/gnome/DisplayManager/LocalDisplayFactory"); }
			catch (Error e)
			{
				log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot create Gdm DBus proxy: %s\n", e.message);
				init_failed = true;
			}
			SimpleLock.set_callback (lock_cb);
		}
	}
	
	private void lock_cb (bool locked)
	{
		parent.set_locked_state (locked);
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
		SimpleLock.set_callback (null);
		SimpleLock.fini ();
	}
}
#endif


public class ScreenlockProxy : Application
{
	string session_id = null;
	
	string config_file_name = null; // set when reading the config for the first time
	string config_file_group = null;
	FileMonitor config_file_monitor = null;
	FileMonitor config_dir_monitor = null;
	uint file_changed_source = 0;
	
	struct Options
	{
		string backend;
		bool allow_unlock;
		int idle_timeout;
		bool lock_on_inactive;
	}
	
	// options read from the config file
	Options config_file = { null, false, 0, true };
	// options from the command line
	Options config_cmdline = { null, false, -1, true };
	
	string pending_backend = null;
	ulong pending_backend_signal = 0;
	
	string backend { get { return config_cmdline.backend ?? config_file.backend; } }
	bool allow_unlock { get { return config_cmdline.allow_unlock || config_file.allow_unlock; } }
	bool lock_on_inactive { get { return config_cmdline.lock_on_inactive && config_file.lock_on_inactive; } }
	uint idle_timeout { get {
		int ret = (config_cmdline.idle_timeout >= 0) ? config_cmdline.idle_timeout : config_file.idle_timeout;
		return (ret >= 0) ? ret : 0;
	} }
	
	lock_wrapper_listener listener = null;
	bool activated = false;
	
	private ScreenlockProxy ()
	{
		Object (application_id: "org.example.wayland_screenlock_proxy", flags: ApplicationFlags.DEFAULT_FLAGS);
		
		OptionEntry[] options = {
			{"session-id", 'i', OptionFlags.NONE, OptionArg.STRING, ref session_id, "ID of the session to monitor for lock and unlock signals.", "ID"},
			{"backend", 'b', OptionFlags.NONE, OptionArg.STRING, ref config_cmdline.backend, "Screenlocker program to use. Supported backends are: swaylock, gtklock and waylock.", "BACKEND"},
			{"allow-unlock", 'u', OptionFlags.NONE, OptionArg.NONE, ref config_cmdline.allow_unlock, "Allow unlocking the screen in response to an \"org.freedesktop.login1.Session.Unlock\" signal.", null},
			{"idle-timeout", 'I', OptionFlags.NONE, OptionArg.INT, ref config_cmdline.idle_timeout, "Lock the session automatically after being inactive for this time (in seconds; set to 0 to disable).", "TIME"},
			{"no-lock-on-inactive", 'L', OptionFlags.REVERSE, OptionArg.NONE, ref config_cmdline.lock_on_inactive, "Do not lock the session automatically when it becomes inactive e.g. due to a VT switch.", null}
		};
		
		add_main_option_entries (options);
	}
	
	private void read_config (ref Options conf)
	{
		// read config
		try
		{
			KeyFile config = new KeyFile ();
			config.load_from_file (config_file_name, KeyFileFlags.NONE);
			
			if (config.has_group (config_file_group))
			{
				if (config.has_key (config_file_group, "allow_unlock")) conf.allow_unlock = config.get_boolean (config_file_group, "allow_unlock");
				if (config.has_key (config_file_group, "backend")) conf.backend = config.get_string (config_file_group, "backend");
				if (config.has_key (config_file_group, "idle_lock_timeout")) conf.idle_timeout = config.get_integer (config_file_group, "idle_lock_timeout");
				if (config.has_key (config_file_group, "lock_on_inactive")) conf.lock_on_inactive = config.get_boolean (config_file_group, "lock_on_inactive");
			}
		}
		catch (Error e)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_WARNING, "Cannot read config file, will use defaults (%s)\n", e.message);
		}
	}
	
	private void replace_backend (string new_backend)
	{
		var lw1 = start_backend (new_backend);
		if (lw1 != null)
		{
			listener.backend = lw1;
			config_file.backend = new_backend;
		}
		else log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Cannot start requested screenlocker ('%s')\n", new_backend);
	}
	
	private void config_changed (bool dir_change)
	{
		if (activated)
		{
			// already running, need to possibly change settings
			Options new_conf = { null, false, -1 };
			read_config (ref new_conf);
			
			config_file.allow_unlock = new_conf.allow_unlock;
			listener.allow_unlock = allow_unlock; // will read the value possibly overriden from the command line
			
			config_file.idle_timeout = new_conf.idle_timeout;
			IdleNotify.set_timeout (idle_timeout);
			
			config_file.lock_on_inactive = new_conf.lock_on_inactive;
			listener.lock_on_inactive = lock_on_inactive;
			
			if (config_cmdline.backend == null && new_conf.backend != config_file.backend)
			{
				if (check_backend (new_conf.backend))
				{
					if (listener.is_locked)
					{
						pending_backend = new_conf.backend;
						if (pending_backend_signal == 0)
							pending_backend_signal = listener.locked_changed.connect ((listener, is_locked) => {
								if (pending_backend != null)
								{
									if (is_locked) return;
									replace_backend (pending_backend);
									pending_backend = null;
								}
								listener.disconnect (pending_backend_signal);
								pending_backend_signal = 0;
							});
					}
					else
					{
						replace_backend (new_conf.backend);
						pending_backend = null;
					}
				}
				else log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Requested screenlocker ('%s') is not available\n", new_conf.backend);
			}
		}
		else read_config (ref config_file);
		
		if (config_dir_monitor != null && config_file_monitor != null && !dir_change)
			return;
		
		var file = File.new_for_path (config_file_name);
		try
		{
			if (config_dir_monitor == null)
			{
				var dir = file.get_parent ();
				config_dir_monitor = dir.monitor_directory (FileMonitorFlags.WATCH_MOVES);
				config_dir_monitor.changed.connect (config_dir_changed);
			}
			if (config_file_monitor == null || dir_change)
			{
				config_file_monitor = file.monitor_file (FileMonitorFlags.NONE);
				config_file_monitor.changed.connect (config_file_changed);
			}
		} catch (Error e)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_WARNING, "Cannot watch for changes in the config file, will not update settings from it\n");
		}
	}
	
	private void config_file_changed (FileMonitor monitor, File file, File? other_file, FileMonitorEvent event)
	{
		if (event == FileMonitorEvent.CHANGED || event == FileMonitorEvent.CHANGES_DONE_HINT)
		{
			if (file_changed_source == 0)
				file_changed_source = Timeout.add (1000, () => {
					config_changed (false);
					file_changed_source = 0;
					return false;
				});
		}
		else if (event == FileMonitorEvent.DELETED)
		{
			if (file_changed_source != 0)
			{
				Source.remove (file_changed_source);
				file_changed_source = 0;
			}
			config_file_monitor = null;
		}
	}
	
	private void config_dir_changed (FileMonitor monitor, File file, File? other_file, FileMonitorEvent event)
	{
		bool changed = false;
		if (event == FileMonitorEvent.CREATED || event == FileMonitorEvent.MOVED_IN)
			if (file.get_path () == config_file_name) changed = true;
		
		if (event == FileMonitorEvent.RENAMED)
			if (other_file.get_path () == config_file_name) changed = true;
		
		if (changed) config_changed (true);
	}
	
	public override void startup ()
	{
		base.startup ();
		
		string config_dir = Environment.get_variable ("XDG_CONFIG_HOME");
		if (config_dir == null) config_dir = Environment.get_variable ("HOME") + "/.config";
		config_dir += "/wayland-screenlock-proxy";
		
		// check if the compositor integration feature is installed and use
		// the compositor-specific configuration if yes
		bool have_wayfire = false;
		for (int i = 0; i < 2; i++)
		{
			string dir = (i == 0) ? config_dir : Config.DATADIR; // this is ugly, but cannot do foreach (... [x, y])
			try
			{
				string fn = dir + "/screenlock_integration.ini";
				KeyFile int_config = new KeyFile ();
				int_config.load_from_file (fn, KeyFileFlags.NONE);
				bool have_key = int_config.has_key ("compositor_integration", "wayfire");
				if (have_key)
				{
					have_wayfire = int_config.get_boolean ("compositor_integration", "wayfire");
					break;
				}
			}
			catch (Error e)
			{
				// having an error here is normal if the above configuration file does not exist
				log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_DEBUG, "Cannot load compositor integration config (%s)\n", e.message);
			}
		}
			
		if (have_wayfire)
		{
			string wayfire_config = Environment.get_variable ("WAYFIRE_CONFIG_FILE");
			if (wayfire_config != null) // can be null if not actually running under Wayfire
			{
				config_file_name = wayfire_config;
				config_file_group = "screenlock_integration";
			}
		}
		
		if (config_file_name == null)
		{
			config_file_name = config_dir + "/config.ini";
			config_file_group = "General";
		}
		
		config_changed (true);
		
		if (session_id == null)
			session_id = Environment.get_variable ("XDG_SESSION_ID");
	}
	
	private lock_wrapper_backend? start_backend (string new_backend)
	{
		lock_wrapper_backend lw1 = null;
#if ENABLE_GDM
		if (new_backend == "gdm") lw1 = new gdm_lock (listener);
		else
#endif
		if (new_backend == "swaylock") lw1 = new swaylock_backend (listener);
		else if (new_backend == "waylock") lw1 = new waylock_backend (listener);
		else lw1 = new gtklock_backend (listener);
		if (lw1.init_failed) return null;
		return lw1;
	}
	
	public override void activate ()
	{
		if (activated) return;
		activated = true;
		
		if (session_id == null)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "No session ID provided!\n");
			return;
		}
		
		// startup
		if (backend != null && backend != "auto")
		{
			if (! check_backend (backend))
			{
				log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Requested screenlocker ('%s') is not available or not known\n", backend);
				return;
			}
		} else
		{
			if      (check_known_backend ("gtklock"))  config_file.backend = "gtklock";
			else if (check_known_backend ("swaylock")) config_file.backend = "swaylock";
			else if (check_known_backend ("waylock"))  config_file.backend = "waylock";
			else
			{
				//  note: Gdm backend is not used by default
				log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "No supported screenlocker found");
				return;
			}
		}
		
		listener = new lock_wrapper_listener (session_id, allow_unlock);
		if (listener.init_failed) return; // error message already shown
		listener.backend = start_backend (backend);
		if (listener.backend == null) return;
		listener.lock_on_inactive = lock_on_inactive;
		
		if (!IdleNotify.init())
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "Compositor does not support the ext-idle-notify-v1 protocol, cannot automatically lock the screen on inactivity");
		}
		else
		{
			IdleNotify.set_callback (listener.do_lock_base);
			IdleNotify.set_timeout (idle_timeout);
		}
		
		var sigterm = new GLib.Unix.SignalSource (Posix.Signal.TERM);
		sigterm.set_callback ( () => {
			this.quit ();
			return false;
		});
		sigterm.attach (null);
		hold ();
	}
	
	public override void shutdown ()
	{
		base.shutdown ();
		if (listener != null) listener.do_unlock_base ();
		IdleNotify.fini ();
	}
	
	private static bool check_backend (string backend)
	{
		if (backend != "swaylock" && backend != "gtklock" && backend != "waylock")
		{
	#if ENABLE_GDM
			if (backend == "gdm") return true;
	#endif
			return false;
		}
		
		return check_known_backend (backend);
	}
	
	private static bool check_known_backend (string backend)
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
		if (Environment.get_variable ("WAYLAND_DISPLAY") == null)
		{
			log ("wayland-screenlock-proxy", LogLevelFlags.LEVEL_CRITICAL, "WAYLAND_DISPLAY unset, not running in a Wayland session?\n");
			return 1;
		}
		var app = new ScreenlockProxy ();
		return app.run (args);
	}
}

			
