#include <Foundation/Foundation.h>
#include <bsm/libbsm.h>
#include <libproc.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>

#include <libjailbreak/libjailbreak.h>
#include <libjailbreak/roothider.h>
#include <libjailbreak/roothide_stage.h>

/* Do not truncate an untrusted XPC integer into pid_t: a wrapped PID could
 * otherwise pass the parent check for an unrelated process. */
static bool jailbreakd_get_child_pid(xpc_object_t message, pid_t *childPid)
{
	xpc_object_t value = xpc_dictionary_get_value(message, "pid");
	if (!value || !childPid) return false;
	uint64_t candidate = 0;
	if (xpc_get_type(value) == XPC_TYPE_INT64) {
		int64_t signedPid = xpc_dictionary_get_int64(message, "pid");
		if (signedPid <= 1 || signedPid > INT_MAX) return false;
		candidate = (uint64_t)signedPid;
	} else if (xpc_get_type(value) == XPC_TYPE_UINT64) {
		candidate = xpc_dictionary_get_uint64(message, "pid");
	} else {
		return false;
	}
	if (candidate <= 1 || candidate > INT_MAX) return false;
	*childPid = (pid_t)candidate;
	return true;
}

void jailbreakd_reply_message(JBD_MESSAGE_ID msgId, xpc_object_t reply)
{
	char* desc = NULL;
	JBLogDebug("reply message %d with %s", msgId, (desc=xpc_copy_description(reply)));
	if(desc) free(desc);
	int err = xpc_pipe_routine_reply(reply);
	roothide_stage_log("jailbreakd.reply id=%llu error=%d", (unsigned long long)msgId, err);
	if (err != 0) {
		JBLogError("Error %d sending response", err);
	}
}

/* Keep potentially slow kernel patch work off the Mach receive source's
 * main queue. A serial queue preserves the old one-patch-at-a-time behavior
 * without preventing jailbreakd from receiving unrelated RPCs. */
static dispatch_queue_t jailbreakd_spawn_patch_queue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.roothide.jailbreakd.spawn-patch", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static int64_t jailbreakd_patch_spawn_child(pid_t clientPid, pid_t pid, bool resume, bool forceDyldPatch)
{
    pid_t ppid = proc_get_ppid(pid);
    JBLogDebug("spawn patch: client pid=%d, child pid=%d, child's parent pid=%d, child proc=%s",
               clientPid, pid, ppid, proc_get_path(pid, NULL));
    roothide_stage_log("jailbreakd.patch.request client=%d child=%d parent=%d resume=%d force_dyld=%d",
                       clientPid, pid, ppid, resume, forceDyldPatch);
    if (ppid != clientPid) {
        JBLogError("spawn patch denied: %d", pid);
        return -1;
    }
    if (ppid == 1 && !resume) {
        /* Preserve launchd's existing no-resume workaround. */
        return proc_patch_csflags(pid);
    }

    roothide_stage_log("jailbreakd.patch.begin child=%d", pid);
    int patchResult = roothide_patch_proc_ex(pid, forceDyldPatch);
    roothide_stage_log("jailbreakd.patch.end child=%d result=%d", pid, patchResult);
    if (patchResult != 0) {
        JBLogError("spawn patch failed: %d", pid);
        return -1;
    }
    if (resume && kill(pid, SIGCONT) != 0) {
        int resumeErrno = errno;
        JBLogError("spawn patch resume failed for pid=%d errno=%d", pid, resumeErrno);
        roothide_stage_log("jailbreakd.patch.resume_failed child=%d errno=%d", pid, resumeErrno);
        return -1;
    }
    return 0;
}

void jailbreakd_received_message(mach_port_t port)
{
	@autoreleasepool {
		xpc_object_t message = nil;
		int err = xpc_pipe_receive(port, &message);
		roothide_stage_log("jailbreakd.receive result=%d", err);
		if (err != 0) {
			JBLogError("xpc_pipe_receive error %d", err);
			return;
		}
		if (!message || xpc_get_type(message) != XPC_TYPE_DICTIONARY) {
			JBLogError("dropping malformed jailbreakd XPC request");
			return;
		}

		xpc_object_t reply = xpc_dictionary_create_reply(message);
		if (!reply) {
			JBLogError("jailbreakd XPC request has no reply context");
			return;
		}

		JBD_MESSAGE_ID msgId = xpc_dictionary_get_uint64(message, "id");
		roothide_stage_log("jailbreakd.message id=%llu", (unsigned long long)msgId);
		
		if (xpc_get_type(message) == XPC_TYPE_DICTIONARY) {
			audit_token_t auditToken = {0};
			xpc_dictionary_get_audit_token(message, &auditToken);
			uid_t clientUid = audit_token_to_euid(auditToken);
			pid_t clientPid = audit_token_to_pid(auditToken);

			char* desc = NULL;
			JBLogDebug("received message %d from %d(%s) with dictionary: %s", msgId, clientPid, proc_get_path(clientPid,NULL), (desc=xpc_copy_description(message)));
			if(desc) free(desc);

			switch (msgId) {
				case JBD_MSG_SPINLOCK_FIX_ONLY: {
					int64_t result = 0;
					pid_t pid = xpc_dictionary_get_int64(message, "pid");
					bool resume = xpc_dictionary_get_bool(message, "resume");
					pid_t ppid = proc_get_ppid(pid);
					JBLogDebug("spinlock fix: client pid=%d, child pid=%d, child's parent pid=%d, child proc=%s", clientPid, pid, ppid, proc_get_path(pid,NULL));
					if(ppid == clientPid) {
						if(ppid==1 && resume==false) {
							//`frida -f` sucks with proc_fix_spinlock on ios15
							result = proc_patch_csflags(pid);
						}
						else if(proc_fix_spinlock(pid) == 0) {
							if(resume) kill(pid, SIGCONT);
						} else {
							JBLogError("spinlock fix failed: %d", pid);
							result = -1;
						}
					} else {
						JBLogError("spinlock fix denied: %d", pid);
						result = -1;
					}
					xpc_dictionary_set_int64(reply, "result", result);
					break;
				}

				case JBD_MSG_SPAWN_PATCH_CHILD: {
					pid_t pid = 0;
					if (!jailbreakd_get_child_pid(message, &pid)) {
						roothide_stage_log("jailbreakd.patch.invalid_child_pid client=%d", clientPid);
						xpc_dictionary_set_int64(reply, "result", -1);
						break;
					}
					bool resume = xpc_dictionary_get_bool(message, "resume");
					bool forceDyldPatch = xpc_dictionary_get_bool(message, "force-dyld-patch");
					dispatch_queue_t patchQueue = jailbreakd_spawn_patch_queue();
					if (!patchQueue) {
						xpc_dictionary_set_int64(reply, "result", -1);
						break;
					}
					/* This block owns the reply after the receiver exits. Do not issue
					 * an immediate success response before the patch actually finishes. */
					xpc_object_t asyncReply = reply;
					reply = nil;
					dispatch_async(patchQueue, ^{
						int64_t result = jailbreakd_patch_spawn_child(clientPid, pid, resume, forceDyldPatch);
						xpc_dictionary_set_int64(asyncReply, "result", result);
						jailbreakd_reply_message(msgId, asyncReply);
					});
					break;
				}

				case JBD_MSG_SPAWN_EXEC_START: {
					bool resume = xpc_dictionary_get_bool(message, "resume");
					const char* execfile = xpc_dictionary_get_string(message, "execfile");
					JBLogDebug("spawn exec start: %d %s", clientPid, execfile);
					int64_t result = spawnExecPatchAdd(clientPid, resume);
					xpc_dictionary_set_int64(reply, "result", result);
					break;
				}

				case JBD_MSG_SPAWN_EXEC_CANCEL: {
					const char* execfile = xpc_dictionary_get_string(message, "execfile");
					JBLogDebug("spawn exec cancel: %d %s", clientPid, execfile);
					int64_t result = spawnExecPatchDel(clientPid);
					xpc_dictionary_set_int64(reply, "result", result);
					break;
				}

				case JBD_MSG_EXEC_TRACE_START: {
					//dead lock: jbd->ptrace->kernel->amfi port->launchd->spawn amfid->jdb
					xpc_object_t asyncMessage = message;
					xpc_object_t asyncReply = reply;
					reply = nil; //reply later; keep owned objects alive in the worker
					dispatch_async(dispatch_get_global_queue(0, 0), ^{
						int64_t result = -1;
						uint64_t traced = xpc_dictionary_get_uint64(asyncMessage, "traced");
						const char* execfile = xpc_dictionary_get_string(asyncMessage, "execfile");
						JBLogDebug("exec trace start: %d %s", clientPid, execfile);
						result = execTraceProcess(clientPid, traced);
						xpc_dictionary_set_int64(asyncReply, "result", result);
						jailbreakd_reply_message(msgId, asyncReply);
					});
					break;
				}

				case JBD_MSG_EXEC_TRACE_CANCEL: {
					int64_t result = -1;
					uint64_t detached = xpc_dictionary_get_uint64(message, "detached");
					const char* execfile = xpc_dictionary_get_string(message, "execfile");
					JBLogDebug("exec trace cancel: %d %s", clientPid, execfile);
					result = execTraceCancel(clientPid, detached);
					xpc_dictionary_set_int64(reply, "result", result);
					break;
				}

				case JBD_MSG_SYSTEMWIDE_LOG: {
#ifdef ENABLE_LOGS
					static char logFilePath[PATH_MAX] = {0};
					static dispatch_once_t onceToken;
					dispatch_once(&onceToken, ^{
						JBLogGetLogFilePath("systemwide", NULL, logFilePath);
					});

					const char* progname = NULL;
					const char* procpath = proc_get_path(clientPid,NULL);
					if(procpath) {
						progname = strrchr(procpath, '/');
						if(progname) progname++; else progname = procpath;
					}
					uint64_t tid = xpc_dictionary_get_uint64(message, "tid");
					const char* log = xpc_dictionary_get_string(message, "log");
					JBLogFunction(logFilePath, clientPid, tid, progname ? progname : "(null)", "%s", log);
					xpc_dictionary_set_int64(reply, "result", 0);
#else
					abort();
#endif
					break;
				}

				case JBD_MSG_TEST_CALL: {
					int value = xpc_dictionary_get_int64(message, "value");
					JBLogDebug("jailbreakd test call(%llu) from %d,%s", value, clientPid, proc_get_path(clientPid,NULL));	
					xpc_dictionary_set_int64(reply, "result", value * 2);
					
					if(clientUid == 0) {
						abort(); // crashreporter test
					}

					break;
				}
			}
		}
		if (reply) {
			jailbreakd_reply_message(msgId, reply);
		}
	}
}
