
[CCode (cheader_filename = "idle_notify.h")]
namespace IdleNotify {
	[CCode (cname = "idle_notify_init")]
	bool init();
	[CCode (cname = "IdleNotifyCallback")]
	delegate void IdleNotifyCallback();
	[CCode (cname = "idle_notify_set_callback")]
	void set_callback(IdleNotifyCallback cb);
	[CCode (cname = "idle_notify_set_timeout")]
	void set_timeout(uint timeout);
	[CCode (cname = "idle_notify_fini")]
	void fini();
}
