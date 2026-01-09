using GLib;

namespace interfaces {
	[DBus (name = "org.freedesktop.login1.Manager", timeout = 120000)]
	public interface Manager : GLib.Object {
		[DBus (name = "GetSession")]
		public abstract GLib.ObjectPath get_session(string session_id) throws DBusError, IOError;

		[DBus (name = "Inhibit")]
		public abstract UnixInputStream inhibit(string what, string who, string why, string mode) throws DBusError, IOError;

		[DBus (name = "PrepareForSleep")]
		public signal void prepare_for_sleep(bool start);
	}

	// note: need to derive from DBusProxy to get the g-properties-changed signal
	[DBus (name = "org.freedesktop.login1.Session", timeout = 120000)]
	public interface Session : GLib.DBusProxy {
		[DBus (name = "SetLockedHint")]
		public abstract void set_locked_hint(bool locked) throws DBusError, IOError;

		[DBus (name = "Lock")]
		public signal void lock();

		[DBus (name = "Unlock")]
		public signal void unlock();

		[DBus (name = "LockedHint")]
		public abstract bool locked_hint {  get; }
		
		[DBus (name = "Active")]
		public abstract bool active { get; }
	}

	[DBus (name = "org.gnome.DisplayManager.LocalDisplayFactory", timeout = 120000)]
	public interface LocalDisplayFactory : GLib.Object {

		[DBus (name = "CreateTransientDisplay")]
		public abstract GLib.ObjectPath create_transient_display() throws DBusError, IOError;
	}
}

