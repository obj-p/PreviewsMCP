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
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <string.h>
#include <fcntl.h>
#include <sys/time.h>
#include <mach-o/dyld.h>

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

    // Dump a couple of DYLD_* env vars so we can see what the agent
    // actually had when our interposer was loaded.
    extern char **environ;
    if (environ) {
        for (char **e = environ; *e; ++e) {
            if (strncmp(*e, "DYLD_", 5) == 0) {
                fprintf(boot, "%llu\tenv\t%s\n",
                        (unsigned long long)now_ns(), *e);
            }
        }
    }
    fclose(boot);
}
