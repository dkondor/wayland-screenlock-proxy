
[CCode (cheader_filename = "simple_lock.h")]
namespace SimpleLock {
	[CCode (cname = "simple_lock_init")]
	bool init();
	[CCode (cname = "simple_lock_lock")]
	void lock();
	[CCode (cname = "simple_lock_unlock")]
	void unlock();
	[CCode (cname = "simple_lock_fini")]
	void fini();
}
