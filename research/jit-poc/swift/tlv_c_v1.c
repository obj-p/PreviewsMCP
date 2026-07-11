// Phase-2 step-2 — C-level TLV probe.
//
// Important spike finding: Swift does NOT lower module-level `let` to
// a Mach-O TLV. It uses `swift_once` + a global-storage addressor
// pattern (the `vau` symbol family). To exercise the canonical
// JITLink Mach-O TLV path — `__thread_vars` / `__thread_data`,
// `_tlv_bootstrap`, `___orc_rt_macho_tlv_get_addr_impl` — we need a
// C `_Thread_local` variable.
//
// This C file is built with the SAME brewed clang the host uses, so
// it produces an arm64 Mach-O `.o`. Loaded by host_tlv.cpp into a
// dedicated TLVJD with an explicit MachOPlatform attached.

#include <stdio.h>
#include <unistd.h>

_Thread_local int tlvCounter = 42;

int incTLV(void) {
    tlvCounter++;
    return tlvCounter;
}

int peekTLV(void) {
    return tlvCounter;
}

void printTLV(void) {
    printf("tlv v1: counter=%d (pid=%d)\n", tlvCounter, getpid());
    fflush(stdout);
}
