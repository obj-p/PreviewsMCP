// W3 — `DYLD_INSERT_LIBRARIES` interposer dylib for capturing
// `__xojit_executor_write_mem` and `__xojit_executor_run_program_on_main_thread`
// from XCPreviewAgent during a SwiftUI hot-reload.
//
// Build (on the guest VM, where Xcode's toolchain is present):
//   clang -dynamiclib -arch arm64 -undefined dynamic_lookup \
//         -o /tmp/w3-interposer.dylib /tmp/interposer.c
//   codesign --force --sign - /tmp/w3-interposer.dylib
//
// `-undefined dynamic_lookup` is load-bearing: the four
// `__xojit_executor_*` symbols are only available at runtime via
// dyld_shared_cache, and the SDK does not expose XOJITExecutor headers.
// dyld resolves the external references when the dylib is loaded into
// XCPreviewAgent.
//
// Inject via `launchctl setenv DYLD_INSERT_LIBRARIES /tmp/w3-interposer.dylib`
// plus `launchctl setenv DYLD_FORCE_FLAT_NAMESPACE 1` (the latter ensures
// intra-XOJITExecutor calls hit our interpose entry rather than being
// short-circuited by two-level namespace).
//
// Output goes to `/tmp/w3-writes.log`. One line per intercepted call.
//
// Constructor logs to `/tmp/w3-interposer.log` so we can confirm the
// dylib was loaded even if the interpose entries themselves never fire
// (which would indicate two-level-namespace bypass or wrong arch).

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
