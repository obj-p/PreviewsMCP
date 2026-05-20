// W3 — Interposer dylib for capturing `__xojit_executor_*` calls in
// XCPreviewAgent during a SwiftUI hot-reload.
//
// Build (on the guest VM, where Xcode's toolchain is present):
//   clang -dynamiclib -arch arm64 -arch arm64e -undefined dynamic_lookup \
//         -install_name /tmp/w3-interposer.dylib \
//         -o /tmp/w3-interposer.dylib /tmp/interposer.c
//   codesign --force --sign - /tmp/w3-interposer.dylib
//
// Two load-bearing flags learned the hard way:
//
//   -arch arm64 -arch arm64e (fat): the agent runs as arm64e on Apple
//     Silicon. An arm64-only dylib triggers
//     "(have 'arm64', need 'arm64e')" from dyld and the load fails
//     silently — dyld then falls back to the unmodified arm64 slice of
//     the agent if both arch slices' LC_LOAD_DYLIB target the same
//     non-arm64e path. Fat dylib + patching both arm64* slices of the
//     agent is the robust combination. See `mach-o-add-dylib.c`.
//
//   -undefined dynamic_lookup: the four `__xojit_executor_*` symbols
//     are dyld_shared_cache-only at runtime, and the SDK does not
//     expose XOJITExecutor headers. Defer resolution to dyld at load
//     time.
//
// Inject via LC_LOAD_DYLIB binary modification of `XCPreviewAgent`
// (see `mach-o-add-dylib.c`). The DYLD_INSERT_LIBRARIES + launchctl
// setenv path is NOT viable: empirically blocked at 3 barriers
// (launchctl-setenv from SSH doesn't reach admin's GUI launchd
// session, `open -a` strips DYLD_*, and previewsd reconstructs the
// agent's DYLD_INSERT_LIBRARIES from a hardcoded 5-entry list). Full
// diagnosis: `interposer-results.md` sessions 1-3.
//
// DYLD_FORCE_FLAT_NAMESPACE was thought to be needed alongside but
// turns out unnecessary with LC_LOAD_DYLIB injection — the
// `__DATA,__interpose` table fires for cross-image calls into
// XOJITExecutor regardless of namespace mode.
//
// Output goes to `/tmp/w3-writes.log`. One line per intercepted call.
//
// Constructor logs to `/tmp/w3-interposer.log` so we can confirm the
// dylib was loaded even if the interpose entries themselves never fire
// (which would indicate the wrong arch slice loaded — usually means
// we built arm64-only and the agent's arm64e LC_LOAD_DYLIB rejected
// us).
//
// What the capture showed (session 4): body-literal hot-reload fires
// exactly 3 calls per agent lifetime — run_program_wrapper +
// run_program_on_main_thread + run_program_wrapper, with the last two
// 8 bytes apart (Swift async entry/ret). Never `write_mem`. Agent PID
// changes across the edit; Apple respawns the agent rather than
// patching in-place. See `../analysis/w3-empirical-capture.md`.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <string.h>
#include <fcntl.h>
#include <sys/time.h>
#include <dlfcn.h>
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

static FILE *g_log = NULL;
static pthread_mutex_t g_log_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void open_log(void) {
    g_log = fopen("/tmp/w3-writes.log", "a");
    if (g_log) {
        setvbuf(g_log, NULL, _IOLBF, 0);
        pid_t pid = getpid();
        fprintf(g_log, "# open_log pid=%d\n", (int)pid);
    }
}

static uint64_t now_ns(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000000ull + (uint64_t)tv.tv_usec * 1000ull;
}

// Real-symbol declarations. The leading-underscore C ABI name observed
// in `dyld_info` as `___xojit_executor_*` (3 underscores) corresponds to
// C-source `__xojit_executor_*` (2 underscores) after the linker's
// implicit `_` prefix. Use the 2-underscore form here.
extern int __xojit_executor_write_mem(void *addr, const void *bytes, uint64_t len);
extern int __xojit_executor_run_program_on_main_thread(void *fn, void *args);
extern int __xojit_executor_run_program_wrapper(void *fn, void *args);
extern int __xojit_run_wrapper(void *fn, void *args);

// PreviewsInjection.framework entry points — the actual Swift-callable
// surface previewsd hits per edit. The asm-name trick (clang/GCC
// extension) lets a C function reference a Swift-mangled symbol
// directly. Signatures from `xcrun swift-demangle`:
//
//   __previewsInjectionJITLinkEntrypoint(
//       argc: Int32, argv: char**,
//       previewsDylibPath: char*, previewsDylibEntryPointName: char*
//   ) -> Void
//
//   __previewsInjectionPerformFirstJITLink(
//       argc: Int32, argv: char**
//   ) -> Int32
//
// Both top-level (no Swift implicit self), 4-or-fewer-register args, no
// indirect-result-pointer dance — standard AAPCS64 ABI from C.
extern void pi_jit_link_entrypoint(
    int32_t argc, char **argv,
    char *dylib_path, char *entry_name)
    __asm__("_$s17PreviewsInjection010__previewsB17JITLinkEntrypoint4argc4argv0C9DylibPath0cH14EntryPointNameys5Int32V_SpySpys4Int8VGSgGSgA2LtF");

extern int32_t pi_perform_first_jit_link(int32_t argc, char **argv)
    __asm__("_$s17PreviewsInjection010__previewsB19PerformFirstJITLink4argc4argvs5Int32VAF_SpySpys4Int8VGSgGSgtF");

// XPC entry points used by previewsd↔agent traffic. Capture both the
// fire-and-forget send and the synchronous reply-bearing send.
// `xpc_copy_description` returns a heap-allocated UTF-8 string the
// caller must free; we use it for logging then free.
typedef struct xpc_connection_s *xpc_connection_t_compat;
typedef struct xpc_object_s     *xpc_object_t_compat;
extern void xpc_connection_send_message(xpc_connection_t_compat conn, xpc_object_t_compat msg);
extern xpc_object_t_compat xpc_connection_send_message_with_reply_sync(xpc_connection_t_compat conn, xpc_object_t_compat msg);
extern char *xpc_copy_description(xpc_object_t_compat obj);

// xpc_connection_set_event_handler — the canonical incoming-message
// callback registration. The agent's XPC traffic, including the JIT-
// link payload from previewsd, is delivered through whatever handler
// is registered here. Wrapping the registration in a block-based
// interpose lets us see EVERY incoming message regardless of which
// API layer the agent uses to send replies — because every
// xpc_connection has at most one event handler.
extern void xpc_connection_set_event_handler(
    xpc_connection_t_compat conn,
    void (^handler)(xpc_object_t_compat event));

// xpc_dictionary_get_value — every XPC dictionary read funnels
// through this C entry point, including from Swift wrappers that
// bridge OS_xpc_object via ObjC. If the agent's Swift code reads any
// XPC message at all, it eventually calls this. Catches the
// inbound-content keys even when set_event_handler does not.
extern xpc_object_t_compat xpc_dictionary_get_value(xpc_object_t_compat dict, const char *key);

// xpc_get_type — returns the type of an xpc_object_t (used to
// classify the value xpc_dictionary_get_value returns). Not
// interposed; called from our own wrapper for logging.
extern void *xpc_get_type(xpc_object_t_compat obj);
extern const char *xpc_type_get_name(void *type);

// _dyld_register_func_for_add_image — registers a callback fired on
// every new image load. Used by Apple's own debugger/profiler APIs
// + by anyone who wants a per-load notification. If previewsd ships
// the JIT'd pseudodylib via dlopen (vs purely via mach_vm_write into
// already-mapped pages), we'd see an add-image event for it.
extern void _dyld_register_func_for_add_image(
    void (*func)(const struct mach_header *mh, intptr_t vmaddr_slide));

static int my_write_mem(void *addr, const void *bytes, uint64_t len) {
    pthread_once(&g_once, open_log);
    pthread_mutex_lock(&g_log_mu);
    if (g_log) {
        fprintf(g_log, "%llu\twrite_mem\taddr=%p\tlen=%llu\ttid=%p\n",
                (unsigned long long)now_ns(),
                addr, (unsigned long long)len,
                (void *)pthread_self());
    }
    pthread_mutex_unlock(&g_log_mu);
    return __xojit_executor_write_mem(addr, bytes, len);
}

static int my_run_program_main(void *fn, void *args) {
    pthread_once(&g_once, open_log);
    pthread_mutex_lock(&g_log_mu);
    if (g_log) {
        fprintf(g_log, "%llu\trun_program_on_main_thread\tfn=%p\ttid=%p\n",
                (unsigned long long)now_ns(),
                fn, (void *)pthread_self());
    }
    pthread_mutex_unlock(&g_log_mu);
    return __xojit_executor_run_program_on_main_thread(fn, args);
}

static int my_run_program_wrapper(void *fn, void *args) {
    pthread_once(&g_once, open_log);
    pthread_mutex_lock(&g_log_mu);
    if (g_log) {
        fprintf(g_log, "%llu\trun_program_wrapper\tfn=%p\ttid=%p\n",
                (unsigned long long)now_ns(),
                fn, (void *)pthread_self());
    }
    pthread_mutex_unlock(&g_log_mu);
    return __xojit_executor_run_program_wrapper(fn, args);
}

static int my_run_wrapper(void *fn, void *args) {
    pthread_once(&g_once, open_log);
    pthread_mutex_lock(&g_log_mu);
    if (g_log) {
        fprintf(g_log, "%llu\trun_wrapper\tfn=%p\ttid=%p\n",
                (unsigned long long)now_ns(),
                fn, (void *)pthread_self());
    }
    pthread_mutex_unlock(&g_log_mu);
    return __xojit_run_wrapper(fn, args);
}

// Truncate an XPC description for log readability. The descriptions
// can be hundreds of bytes with embedded newlines; flatten + cap.
static void log_xpc_desc(const char *prefix, char *desc) {
    if (!g_log) return;
    if (!desc) {
        fprintf(g_log, "%llu\t%s\tdesc=(null)\ttid=%p\n",
                (unsigned long long)now_ns(), prefix,
                (void *)pthread_self());
        return;
    }
    // Flatten newlines so each call stays one log line.
    for (char *p = desc; *p; ++p) {
        if (*p == '\n' || *p == '\r' || *p == '\t') *p = ' ';
    }
    fprintf(g_log, "%llu\t%s\tdesc=%.700s\ttid=%p\n",
            (unsigned long long)now_ns(), prefix,
            desc, (void *)pthread_self());
}

static void my_xpc_send(xpc_connection_t_compat conn, xpc_object_t_compat msg) {
    pthread_once(&g_once, open_log);
    char *desc = xpc_copy_description(msg);
    pthread_mutex_lock(&g_log_mu);
    log_xpc_desc("xpc_send", desc);
    pthread_mutex_unlock(&g_log_mu);
    if (desc) free(desc);
    xpc_connection_send_message(conn, msg);
}

static xpc_object_t_compat my_xpc_send_reply_sync(
    xpc_connection_t_compat conn, xpc_object_t_compat msg)
{
    pthread_once(&g_once, open_log);
    char *desc = xpc_copy_description(msg);
    pthread_mutex_lock(&g_log_mu);
    log_xpc_desc("xpc_send_reply_sync_req", desc);
    pthread_mutex_unlock(&g_log_mu);
    if (desc) free(desc);

    xpc_object_t_compat reply = xpc_connection_send_message_with_reply_sync(conn, msg);

    char *rdesc = xpc_copy_description(reply);
    pthread_mutex_lock(&g_log_mu);
    log_xpc_desc("xpc_send_reply_sync_rep", rdesc);
    pthread_mutex_unlock(&g_log_mu);
    if (rdesc) free(rdesc);
    return reply;
}

// dyld add-image callback. Logs every dylib loaded into the process
// from the moment our constructor registers it. The agent's first
// few hundred image-loads are the dyld_shared_cache prebound set;
// anything AFTER that is interesting (e.g., a runtime-loaded
// pseudodylib for the preview).
static void w3_dyld_add_image_cb(const struct mach_header *mh, intptr_t slide) {
    pthread_once(&g_once, open_log);
    Dl_info info;
    const char *name = "?";
    if (dladdr((const void *)mh, &info) && info.dli_fname) {
        name = info.dli_fname;
    }
    pthread_mutex_lock(&g_log_mu);
    if (g_log) {
        fprintf(g_log, "%llu\tdyld_add_image\tmh=%p\tslide=0x%llx\tname=%s\n",
                (unsigned long long)now_ns(),
                (const void *)mh,
                (unsigned long long)slide,
                name);
    }
    pthread_mutex_unlock(&g_log_mu);
}

// xpc_dictionary_get_value fires on EVERY XPC key read — potentially
// thousands/sec. Logging every call floods the log + introduces
// mutex contention that can slow the agent enough to miss
// previewsd's heartbeat. Compromise: only log when the value type
// is "structured" (data / dictionary / array), which is where
// the JIT-link payload would live. Trivial types (xpc_string,
// xpc_int64, xpc_uint64, xpc_bool, xpc_null) skip the log path
// entirely.
static xpc_object_t_compat my_xpc_dict_get_value(
    xpc_object_t_compat dict, const char *key)
{
    xpc_object_t_compat val = xpc_dictionary_get_value(dict, key);
    if (!val) return val;
    void *type = xpc_get_type(val);
    if (!type) return val;
    const char *tname = xpc_type_get_name(type);
    if (!tname) return val;
    // Only log structured / payload-bearing types.
    if (strstr(tname, "data") == NULL &&
        strstr(tname, "dictionary") == NULL &&
        strstr(tname, "array") == NULL &&
        strstr(tname, "fd") == NULL &&
        strstr(tname, "shmem") == NULL) {
        return val;
    }
    pthread_once(&g_once, open_log);
    pthread_mutex_lock(&g_log_mu);
    if (g_log) {
        fprintf(g_log, "%llu\txpc_get_value\tkey=%s\tval_type=%s\n",
                (unsigned long long)now_ns(),
                key ? key : "(null)", tname);
    }
    pthread_mutex_unlock(&g_log_mu);
    return val;
}

static void my_xpc_set_event_handler(
    xpc_connection_t_compat conn,
    void (^handler)(xpc_object_t_compat event))
{
    pthread_once(&g_once, open_log);
    // Wrap the user's handler in a block that logs each incoming
    // message before delegating. Blocks capture `handler` by
    // reference (ARC retain semantics under Block runtime), so the
    // captured ref stays valid for the lifetime of our wrapper.
    void (^wrapped)(xpc_object_t_compat) = ^(xpc_object_t_compat event) {
        char *desc = xpc_copy_description(event);
        pthread_mutex_lock(&g_log_mu);
        log_xpc_desc("xpc_recv", desc);
        pthread_mutex_unlock(&g_log_mu);
        if (desc) free(desc);
        handler(event);
    };
    pthread_mutex_lock(&g_log_mu);
    if (g_log) {
        fprintf(g_log,
                "%llu\txpc_set_event_handler\tconn=%p\thandler=%p\ttid=%p\n",
                (unsigned long long)now_ns(),
                (void *)conn, (void *)handler,
                (void *)pthread_self());
    }
    pthread_mutex_unlock(&g_log_mu);
    xpc_connection_set_event_handler(conn, wrapped);
}

static void my_pi_jit_link_entrypoint(
    int32_t argc, char **argv, char *dylib_path, char *entry_name)
{
    pthread_once(&g_once, open_log);
    pthread_mutex_lock(&g_log_mu);
    if (g_log) {
        fprintf(g_log,
                "%llu\tpi_jit_link_entrypoint\targc=%d\tdylib_path=%s\tentry=%s\ttid=%p\n",
                (unsigned long long)now_ns(),
                (int)argc,
                dylib_path ? dylib_path : "(null)",
                entry_name ? entry_name : "(null)",
                (void *)pthread_self());
    }
    pthread_mutex_unlock(&g_log_mu);
    pi_jit_link_entrypoint(argc, argv, dylib_path, entry_name);
}

static int32_t my_pi_perform_first_jit_link(int32_t argc, char **argv) {
    pthread_once(&g_once, open_log);
    pthread_mutex_lock(&g_log_mu);
    if (g_log) {
        fprintf(g_log,
                "%llu\tpi_perform_first_jit_link\targc=%d\ttid=%p\n",
                (unsigned long long)now_ns(),
                (int)argc, (void *)pthread_self());
    }
    pthread_mutex_unlock(&g_log_mu);
    return pi_perform_first_jit_link(argc, argv);
}

__attribute__((used))
static const struct {
    const void *replacement;
    const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)&my_write_mem,
      (const void *)&__xojit_executor_write_mem },
    { (const void *)&my_run_program_main,
      (const void *)&__xojit_executor_run_program_on_main_thread },
    { (const void *)&my_run_program_wrapper,
      (const void *)&__xojit_executor_run_program_wrapper },
    { (const void *)&my_run_wrapper,
      (const void *)&__xojit_run_wrapper },
    { (const void *)&my_xpc_send,
      (const void *)&xpc_connection_send_message },
    { (const void *)&my_xpc_send_reply_sync,
      (const void *)&xpc_connection_send_message_with_reply_sync },
    { (const void *)&my_xpc_set_event_handler,
      (const void *)&xpc_connection_set_event_handler },
    { (const void *)&my_xpc_dict_get_value,
      (const void *)&xpc_dictionary_get_value },
    { (const void *)&my_pi_jit_link_entrypoint,
      (const void *)&pi_jit_link_entrypoint },
    { (const void *)&my_pi_perform_first_jit_link,
      (const void *)&pi_perform_first_jit_link },
};

// Constructor — proves the dylib was loaded into the agent's address
// space even if no interposer fires (so we can distinguish "wasn't
// loaded" from "loaded but bypassed by namespace binding").
__attribute__((constructor))
static void w3_interposer_init(void) {
    FILE *boot = fopen("/tmp/w3-interposer.log", "a");
    if (!boot) return;
    setvbuf(boot, NULL, _IOLBF, 0);

    char exe[1024]; uint32_t exelen = sizeof(exe);
    if (_NSGetExecutablePath(exe, &exelen) != 0) {
        strncpy(exe, "?", sizeof(exe));
    }

    fprintf(boot, "%llu\tloaded\tpid=%d\texe=%s\n",
            (unsigned long long)now_ns(),
            (int)getpid(), exe);

    // Capture the agent's argv. previewsd's posix_spawn call sets
    // these per its own (host-side) lifecycle decision tree (Dylib /
    // JIT / framework-agent paths from w3-lifecycle-timeline.md).
    // The first arg is the binary path; subsequent args carry the
    // injection mode + bootstrap parameters.
    int *argcp = _NSGetArgc();
    char ***argvp = _NSGetArgv();
    if (argcp && argvp && *argvp) {
        int argc = *argcp;
        char **argv = *argvp;
        for (int i = 0; i < argc; i++) {
            fprintf(boot, "%llu\targv\t%d\t%s\n",
                    (unsigned long long)now_ns(),
                    i, argv[i] ? argv[i] : "(null)");
        }
    }

    // Dump env vars previewsd might use to communicate spawn-time
    // configuration to the agent — broader filter than session-4's
    // DYLD_* only.
    extern char **environ;
    if (environ) {
        for (char **e = environ; *e; ++e) {
            if (strncmp(*e, "DYLD_", 5) == 0 ||
                strncmp(*e, "XPC_", 4) == 0 ||
                strncmp(*e, "__XPC_", 6) == 0 ||
                strncmp(*e, "OS_ACTIVITY_", 12) == 0 ||
                strncmp(*e, "XCODE", 5) == 0 ||
                strncmp(*e, "PREVIEWS_", 9) == 0 ||
                strncmp(*e, "IDE", 3) == 0) {
                fprintf(boot, "%llu\tenv\t%s\n",
                        (unsigned long long)now_ns(), *e);
            }
        }
    }
    fclose(boot);

    // Register for dyld image-add notifications. dyld calls our
    // callback once per already-loaded image at registration time
    // (we'll see the entire pre-existing image set), then once per
    // SUBSEQUENT load. Most interesting: anything loaded AFTER our
    // constructor finishes (post-startup) — that's where a
    // runtime-loaded pseudodylib would appear.
    _dyld_register_func_for_add_image(w3_dyld_add_image_cb);
}
