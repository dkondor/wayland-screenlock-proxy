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

	[DBus (name = "org.freedesktop.login1.Session", timeout = 120000)]
	public interface Session : GLib.Object {
		[DBus (name = "SetLockedHint")]
		public abstract void set_locked_hint(bool locked) throws DBusError, IOError;

		[DBus (name = "Lock")]
		public signal void lock();

		[DBus (name = "Unlock")]
		public signal void unlock();

		[DBus (name = "LockedHint")]
		public abstract bool locked_hint {  get; }
	}

	[DBus (name = "org.freedesktop.DBus.Properties", timeout = 120000)]
	public interface Properties : GLib.Object {

		[DBus (name = "Get")]
		public abstract GLib.Variant get(string interface_name, string property_name) throws DBusError, IOError;

		[DBus (name = "GetAll")]
		public abstract GLib.HashTable<string, GLib.Variant> get_all(string interface_name) throws DBusError, IOError;

		[DBus (name = "Set")]
		public abstract void set(string interface_name, string property_name, GLib.Variant value) throws DBusError, IOError;

		[DBus (name = "PropertiesChanged")]
		public signal void properties_changed(string interface_name, GLib.HashTable<string, GLib.Variant> changed_properties, string[] invalidated_properties);
	}

	[DBus (name = "org.gnome.DisplayManager.LocalDisplayFactory", timeout = 120000)]
	public interface LocalDisplayFactory : GLib.Object {

		[DBus (name = "CreateTransientDisplay")]
		public abstract GLib.ObjectPath create_transient_display() throws DBusError, IOError;
	}
}

