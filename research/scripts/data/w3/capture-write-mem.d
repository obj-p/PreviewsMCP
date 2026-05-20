#!/usr/sbin/dtrace -s
/*
 * capture-write-mem.d — agent-side patch-application tracer.
 *
 * Pre-implementation runtime confirmation for the W3 patch-point set
 * (see research/scripts/analysis/w3-patch-point-set.md §6).
 *
 * Captures every call into XOJITExecutor's remote-memory-write primitive on
 * the agent (XCPreviewAgent) during a real preview hot-reload. The non-empty
 * call set IS the patch-point address list.
 *
 * Usage (in research/vm/ guest, SIP off + AMFI off):
 *
 *   # 1. Get the agent PID after Xcode has rendered the preview canvas:
 *   AGENT_PID=$(pgrep -n XCPreviewAgent)
 *
 *   # 2. Start tracing (writes go to stdout; redirect for analysis):
 *   sudo dtrace -s capture-write-mem.d -p $AGENT_PID > writes.dtrace 2>&1
 *
 *   # 3. In Xcode, edit one literal in the preview body (e.g.
 *   #    `Text("Hello")` -> `Text("World")`) and save.
 *
 *   # 4. Wait for the preview to re-render. Ctrl-C the dtrace session.
 *
 *   # 5. Parse writes.dtrace. Each `write_mem` call is logged with target
 *   #    address, byte-count, and a 5-frame ustack.
 *
 * Expected output volume on a one-literal edit: a handful of entries,
 * each pointing inside the in-memory pseudodylib's __DATA__const or
 * __DATA_CONST,__got regions.
 *
 * Calling convention reference (the four XOJITExecutor C entrypoints):
 *
 *   void __xojit_executor_write_mem(uint64_t addr, const void *data, size_t len);
 *   int  __xojit_executor_run_program_wrapper(...);
 *   int  __xojit_executor_run_program_on_main_thread(...);
 *   int  __xojit_run_wrapper(...);
 */

#pragma D option quiet
#pragma D option dynvarsize=8m
#pragma D option strsize=512

dtrace:::BEGIN
{
    printf("[capture-write-mem] tracing pid=%d (XCPreviewAgent) — Ctrl-C to stop\n", $target);
    printf("ts(ns)\twrite_mem(addr, len)\n");
}

/*
 * Apple ships these as global symbols on XOJITExecutor.framework, prefixed
 * with double-underscore by `_` Mach-O symbol mangling. Match against the
 * function name without the leading underscore.
 */
pid$target::*xojit_executor_write_mem*:entry
{
    self->target = arg0;
    self->len    = arg2;
    printf("%llu\twrite_mem(0x%llx, %lld)\n", timestamp, (uint64_t)arg0, (int64_t)arg2);
    ustack(5);
    printf("\n");
}

pid$target::*xojit_executor_run_program_on_main_thread*:entry
{
    printf("%llu\trun_program_on_main_thread(fn=0x%llx)\n", timestamp, (uint64_t)arg0);
    ustack(3);
    printf("\n");
}

/*
 * Adjunct mprotect tracing — XOJITExecutor wraps each write_mem in
 * mprotect(W) / memcpy / mprotect(X). Capturing both confirms the W^X
 * dance and bounds the page touched.
 */
pid$target::mprotect:entry
{
    printf("%llu\tmprotect(addr=0x%llx, len=0x%llx, prot=0x%x)\n",
           timestamp, (uint64_t)arg0, (uint64_t)arg1, (uint32_t)arg2);
}

dtrace:::END
{
    printf("[capture-write-mem] done\n");
}
