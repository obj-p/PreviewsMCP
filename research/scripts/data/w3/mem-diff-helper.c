// W3 — Mach VM snapshot/diff helper for XCPreviewAgent.
//
// Second-source capture for the per-edit address list, in parallel to
// the LC_LOAD_DYLIB interposer (`mach-o-add-dylib.c` +
// `interposer.c`). Uses `task_for_pid` + `mach_vm_region_recurse_64`
// to enumerate writable data regions of the agent,
// `mach_vm_read_overwrite` to snapshot each region (non-invasive —
// doesn't stop the target), then a diff mode that reports byte-level
// changes between two snapshots.
//
// Build:
//   clang -O2 -Wall -o mem-diff-helper mem-diff-helper.c
//
// Usage:
//   mem-diff-helper snapshot <pid> <out-file>
//   mem-diff-helper diff <before-file> <after-file> <report-file>
//
// Why this isn't blocked by the gates that stopped lldb/dtrace:
//   - `task_for_pid` on a `get-task-allow` target works for any
//     calling-uid-matches-target-uid case + `taskgated`. On an
//     AMFI-off + SIP-off VM running as admin (same uid as the agent),
//     this is unrestricted.
//   - `mach_vm_read_overwrite` is a memory copy, not a debugger
//     attach. The target keeps running; no heartbeat timeout fires.
//   - No symbols needed. Output is raw byte addresses, which is
//     exactly what the W3 deliverable wants.
//
// Snapshot file format (little-endian, version 1):
//   magic  : "W3MD"  (4 bytes)
//   ver    : uint32  = 1
//   nrgn   : uint32  = number of regions captured
//   nrgn x { addr: uint64, size: uint64, prot: uint32, _pad: uint32 }
//   then for each region: `size` bytes of raw memory.
//
// What the capture showed (session 4): the diff is *dominated by
// agent respawn artifacts*, not in-place patches. The two snapshots
// were of DIFFERENT processes (PID 1290 pre-edit, PID 1403 post-edit)
// because previewsd kills + posix_spawns the agent on every body
// edit. So the diff shows ~127 regions with mostly REGION_ONLY_IN_BEFORE
// (the dead agent's freed mappings) + a small set of byte-level DIFFs
// (shared regions / dyld_shared_cache addresses that survived). The
// diff IS NOT a per-call patch-point list — for that, see the
// interposer log at `w3-writes.interposer.txt`.
//
// Useful regardless: the diff corroborates the respawn-not-patch
// finding. If Apple were patching in-place, we'd see only DIFF
// entries (same-PID, byte-level mutations); we see mostly
// REGION_ONLY_IN_BEFORE (process replacement). This is the
// second-source evidence that closes the §2 mechanism-hypothesis
// refutation in `../analysis/w3-empirical-capture.md`.

#include <fcntl.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_region.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAGIC "W3MD"
#define VERSION 1

// Cap to keep snapshot files manageable. The agent's writable data
// regions across a hot-reload are typically a few hundred MB total;
// any single region larger than this is almost certainly the heap or
// a system mapping we don't care about for this experiment.
#define MAX_REGION_BYTES (16ull * 1024 * 1024)

struct __attribute__((packed)) region_hdr {
    uint64_t addr;
    uint64_t size;
    uint32_t prot;
    uint32_t _pad;
};

static int do_snapshot(pid_t pid, const char *out_path) {
    mach_port_t task;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid(%d) failed: %s (%d)\n",
                pid, mach_error_string(kr), kr);
        return 1;
    }

    FILE *f = fopen(out_path, "wb");
    if (!f) { perror("fopen output"); return 1; }
    fwrite(MAGIC, 1, 4, f);
    uint32_t ver = VERSION;
    fwrite(&ver, sizeof(ver), 1, f);

    long nrgn_pos = ftell(f);
    uint32_t nrgn = 0;
    fwrite(&nrgn, sizeof(nrgn), 1, f);

    // Reserve space for the region-header table; we'll come back and
    // rewrite it once we know `nrgn`. Worst-case bound is ~10000
    // regions — pre-allocate enough.
    long header_table_pos = ftell(f);
    long header_table_max = 16384;
    {
        char zeros[1] = {0};
        for (long i = 0; i < header_table_max * (long)sizeof(struct region_hdr); i++) {
            fwrite(zeros, 1, 1, f);
        }
    }

    // Region payload section follows.
    long payload_start_pos = ftell(f);
    long payload_pos = payload_start_pos;

    struct region_hdr *hdr_table = calloc(header_table_max, sizeof(*hdr_table));
    if (!hdr_table) { fclose(f); return 1; }

    mach_vm_address_t addr = 0;
    while (1) {
        mach_vm_size_t size = 0;
        natural_t depth = 1;
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;

        kr = mach_vm_region_recurse(task, &addr, &size, &depth,
                                    (vm_region_recurse_info_t)&info, &count);
        if (kr == KERN_INVALID_ADDRESS) break;
        if (kr != KERN_SUCCESS) {
            fprintf(stderr,
                    "mach_vm_region_recurse at 0x%llx failed: %s (%d)\n",
                    (unsigned long long)addr, mach_error_string(kr), kr);
            break;
        }

        // Filter: writable (we'll never see writes to read-only regions
        // unless mprotect intervenes — and `__xojit_executor_write_mem`
        // DOES mprotect first, so we must include read-only-now regions
        // too if they're EVER writable. info.max_protection captures
        // the high-watermark protection a region can be flipped to.
        int interesting = (info.max_protection & VM_PROT_WRITE) != 0
                       && info.share_mode != SM_EMPTY;
        if (!interesting) {
            addr += size;
            continue;
        }
        // Skip absurdly large regions (typically the heap arena).
        if (size > MAX_REGION_BYTES) {
            addr += size;
            continue;
        }
        // Skip submap recursion; we want the leaf mappings.
        if (depth > 0 && info.is_submap) {
            // Descend.
            continue;
        }

        if ((long)nrgn >= header_table_max) {
            fprintf(stderr,
                    "header table full at %u regions; truncating\n",
                    nrgn);
            break;
        }

        // mach_vm_read_overwrite copies into a buffer we own; no need
        // for vm_deallocate.
        void *buf = malloc((size_t)size);
        if (!buf) {
            fprintf(stderr,
                    "malloc %llu failed for region 0x%llx\n",
                    (unsigned long long)size,
                    (unsigned long long)addr);
            addr += size;
            continue;
        }
        mach_vm_size_t got = 0;
        kr = mach_vm_read_overwrite(task, addr, size,
                                    (mach_vm_address_t)buf, &got);
        if (kr != KERN_SUCCESS || got != size) {
            // Region may have been protected to PROT_NONE, or
            // disappeared between region_recurse and read. Skip.
            if (kr != KERN_SUCCESS) {
                fprintf(stderr,
                        "mach_vm_read 0x%llx [%llu]: %s (%d) — skip\n",
                        (unsigned long long)addr,
                        (unsigned long long)size,
                        mach_error_string(kr), kr);
            }
            free(buf);
            addr += size;
            continue;
        }

        hdr_table[nrgn].addr = (uint64_t)addr;
        hdr_table[nrgn].size = (uint64_t)size;
        hdr_table[nrgn].prot = (uint32_t)info.protection
                             | ((uint32_t)info.max_protection << 8);
        fseek(f, payload_pos, SEEK_SET);
        fwrite(buf, 1, (size_t)size, f);
        payload_pos += size;
        nrgn++;
        free(buf);

        addr += size;
    }

    // Rewrite the header table.
    fseek(f, nrgn_pos, SEEK_SET);
    fwrite(&nrgn, sizeof(nrgn), 1, f);
    fseek(f, header_table_pos, SEEK_SET);
    fwrite(hdr_table, sizeof(*hdr_table), nrgn, f);

    fclose(f);
    free(hdr_table);
    fprintf(stderr, "snapshot: %u regions, payload bytes ~ %ld\n",
            nrgn, payload_pos - payload_start_pos);
    return 0;
}

struct snap {
    uint32_t nrgn;
    struct region_hdr *hdrs;
    uint8_t *payload;
    long payload_size;
};

static int load_snap(const char *path, struct snap *s) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 1; }
    char magic[5] = {0};
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, MAGIC, 4) != 0) {
        fprintf(stderr, "%s: bad magic\n", path); fclose(f); return 1;
    }
    uint32_t ver;
    if (fread(&ver, sizeof(ver), 1, f) != 1 || ver != VERSION) {
        fprintf(stderr, "%s: bad version %u\n", path, ver); fclose(f); return 1;
    }
    if (fread(&s->nrgn, sizeof(s->nrgn), 1, f) != 1) { fclose(f); return 1; }

    s->hdrs = calloc(16384, sizeof(*s->hdrs));
    if (!s->hdrs) { fclose(f); return 1; }
    if (fread(s->hdrs, sizeof(*s->hdrs), 16384, f) != 16384) {
        fprintf(stderr, "%s: short header table\n", path);
        fclose(f); return 1;
    }

    struct stat st;
    fstat(fileno(f), &st);
    s->payload_size = st.st_size - ftell(f);
    s->payload = malloc((size_t)s->payload_size);
    if (!s->payload) { fclose(f); return 1; }
    if (fread(s->payload, 1, (size_t)s->payload_size, f) != (size_t)s->payload_size) {
        fprintf(stderr, "%s: short payload\n", path);
        fclose(f); return 1;
    }
    fclose(f);
    return 0;
}

static int do_diff(const char *a_path, const char *b_path,
                   const char *report_path) {
    struct snap a = {0}, b = {0};
    if (load_snap(a_path, &a)) return 1;
    if (load_snap(b_path, &b)) return 1;

    FILE *r = fopen(report_path, "w");
    if (!r) { perror(report_path); return 1; }

    fprintf(r, "# mem-diff: %s -> %s\n", a_path, b_path);
    fprintf(r, "# %u regions in before, %u in after\n", a.nrgn, b.nrgn);

    // For each region in `a`, find its match in `b` by address. If
    // present, byte-diff. Report mismatched regions.
    long a_off = 0;
    long *b_offsets = calloc(b.nrgn, sizeof(long));
    {
        long off = 0;
        for (uint32_t i = 0; i < b.nrgn; i++) {
            b_offsets[i] = off;
            off += (long)b.hdrs[i].size;
        }
    }

    uint64_t total_diff_runs = 0;
    uint64_t total_diff_bytes = 0;

    for (uint32_t i = 0; i < a.nrgn; i++) {
        struct region_hdr *ah = &a.hdrs[i];
        // Linear scan to find matching region in b — should be O(n)
        // but n is small.
        int bidx = -1;
        for (uint32_t j = 0; j < b.nrgn; j++) {
            if (b.hdrs[j].addr == ah->addr && b.hdrs[j].size == ah->size) {
                bidx = (int)j;
                break;
            }
        }
        if (bidx < 0) {
            fprintf(r, "REGION_ONLY_IN_BEFORE addr=0x%" PRIx64 " size=%" PRIu64 "\n",
                    ah->addr, ah->size);
            a_off += ah->size;
            continue;
        }

        uint8_t *ap = a.payload + a_off;
        uint8_t *bp = b.payload + b_offsets[bidx];
        // Find runs of differing bytes.
        uint64_t pos = 0;
        while (pos < ah->size) {
            if (ap[pos] != bp[pos]) {
                uint64_t run_start = pos;
                while (pos < ah->size && ap[pos] != bp[pos]) pos++;
                uint64_t run_len = pos - run_start;
                total_diff_runs++;
                total_diff_bytes += run_len;
                fprintf(r,
                        "DIFF addr=0x%" PRIx64 " len=%" PRIu64
                        " region=0x%" PRIx64 "+%" PRIu64
                        " prot=0x%x before=",
                        ah->addr + run_start, run_len,
                        ah->addr, run_start, ah->prot);
                for (uint64_t k = 0; k < run_len && k < 32; k++) {
                    fprintf(r, "%02x", ap[run_start + k]);
                }
                fprintf(r, " after=");
                for (uint64_t k = 0; k < run_len && k < 32; k++) {
                    fprintf(r, "%02x", bp[run_start + k]);
                }
                fprintf(r, "\n");
            } else {
                pos++;
            }
        }
        a_off += ah->size;
    }

    fprintf(r, "# total: %" PRIu64 " diff runs, %" PRIu64 " diff bytes\n",
            total_diff_runs, total_diff_bytes);
    fclose(r);
    free(b_offsets);
    fprintf(stderr,
            "diff: %" PRIu64 " runs, %" PRIu64 " bytes -> %s\n",
            total_diff_runs, total_diff_bytes, report_path);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
usage:
        fprintf(stderr,
                "usage:\n"
                "  %s snapshot <pid> <out-file>\n"
                "  %s diff <before-file> <after-file> <report-file>\n",
                argv[0], argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "snapshot") == 0) {
        if (argc != 4) goto usage;
        return do_snapshot((pid_t)atoi(argv[2]), argv[3]);
    } else if (strcmp(argv[1], "diff") == 0) {
        if (argc != 5) goto usage;
        return do_diff(argv[2], argv[3], argv[4]);
    }
    goto usage;
}
