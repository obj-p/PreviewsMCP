// W3 — Minimal Mach-O LC_LOAD_DYLIB injector for XCPreviewAgent.
//
// Appends an LC_LOAD_DYLIB load command to the arm64e slice of a fat
// Mach-O binary in-place. The DYLD_INSERT_LIBRARIES injection path
// (handoff.md / interposer-results.md) is blocked at three barriers —
// this tool bypasses all of them by modifying the agent binary
// directly.
//
// Build:
//   clang -O2 -Wall -o mach-o-add-dylib mach-o-add-dylib.c
//
// Usage:
//   mach-o-add-dylib <macho-path> <dylib-path>
//
// The target Mach-O is patched in place; caller is responsible for
// backup + post-patch re-codesigning (the existing Apple signature
// becomes invalid on any byte modification). Typical caller flow:
//
//   sudo cp .../XCPreviewAgent .../XCPreviewAgent.bak
//   sudo mach-o-add-dylib .../XCPreviewAgent /tmp/w3-interposer.dylib
//   sudo codesign -d --entitlements - .../XCPreviewAgent.bak > /tmp/ent.plist
//   sudo codesign --force --sign - --entitlements /tmp/ent.plist \
//                 .../XCPreviewAgent
//
// Scope:
//   - Only patches the arm64e slice (the slice macOS-on-Apple-Silicon
//     selects). x86_64 and arm64 slices left intact.
//   - Requires the new load command to fit in the existing pad bytes
//     between the load-commands area and the first section's data.
//     For the macOS-26.2 XCPreviewAgent the headroom is 88 bytes; the
//     new command for `/tmp/w3-interposer.dylib` needs 56. Slack
//     reported on `--verbose` so callers can sanity-check.
//   - No relocation of __LINKEDIT or other segments. If the headroom
//     is insufficient, the patch fails — caller decides whether to
//     fall back to libLogRedirect wrap (handoff.md option 2).
//   - Pure C, no external deps beyond <mach-o/*.h>. ~150 LOC.
//
// References:
//   - Apple, <mach-o/loader.h>: load_command, dylib_command, segment_command_64
//   - Cody Cutrer / Tyilo, `insert_dylib`: prior art for the
//     same operation, MIT-licensed. This tool is a simpler subset.

#include <fcntl.h>
#include <inttypes.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_verbose = 1;

static uint32_t bswap32(uint32_t v) {
    return ((v & 0x000000FFu) << 24) | ((v & 0x0000FF00u) << 8) |
           ((v & 0x00FF0000u) >> 8) | ((v & 0xFF000000u) >> 24);
}

static int find_first_section_offset(const uint8_t *slice,
                                     uint32_t ncmds, uint32_t sizeofcmds,
                                     uint64_t *out_off) {
    // The available "headroom" between the end of the load commands
    // and the start of any segment's on-disk data. The first section
    // of __TEXT is what bounds us — its `offset` is where the
    // executable text begins on disk. __PAGEZERO has fileoff=0 +
    // filesize=0; skip it.
    uint64_t min_off = UINT64_MAX;
    const uint8_t *cmd = slice + sizeof(struct mach_header_64);
    const uint8_t *end = cmd + sizeofcmds;

    for (uint32_t i = 0; i < ncmds && cmd + sizeof(struct load_command) <= end; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            // Walk the sections within this segment — section file
            // offsets are stricter than segment fileoff when there's
            // a header in the segment (the load-commands sit at the
            // start of __TEXT's segment, but __text starts at
            // section offset > 0 within the file).
            const struct section_64 *sects =
                (const struct section_64 *)(cmd + sizeof(struct segment_command_64));
            for (uint32_t j = 0; j < seg->nsects; j++) {
                if (sects[j].offset > 0 && sects[j].offset < min_off) {
                    min_off = sects[j].offset;
                }
            }
            if (seg->filesize > 0 && seg->fileoff > 0 && seg->fileoff < min_off) {
                min_off = seg->fileoff;
            }
        }
        cmd += lc->cmdsize;
    }
    if (min_off == UINT64_MAX) {
        fprintf(stderr, "no segments with positive fileoff found\n");
        return 1;
    }
    *out_off = min_off;
    return 0;
}

static int patch_slice(uint8_t *slice, size_t slice_size, const char *dylib_path) {
    if (slice_size < sizeof(struct mach_header_64)) {
        fprintf(stderr, "slice too small\n");
        return 1;
    }
    struct mach_header_64 *mh = (struct mach_header_64 *)slice;
    if (mh->magic != MH_MAGIC_64) {
        fprintf(stderr, "slice magic 0x%08x is not MH_MAGIC_64\n", mh->magic);
        return 1;
    }

    uint32_t ncmds = mh->ncmds;
    uint32_t sizeofcmds = mh->sizeofcmds;
    if (g_verbose) {
        fprintf(stderr, "slice: ncmds=%u, sizeofcmds=%u (header_size=%zu)\n",
                ncmds, sizeofcmds, sizeof(struct mach_header_64));
    }

    // Compute new LC_LOAD_DYLIB size: struct + path bytes (with null),
    // 8-byte aligned.
    size_t path_with_null = strlen(dylib_path) + 1;
    size_t cmd_size = sizeof(struct dylib_command) + path_with_null;
    cmd_size = (cmd_size + 7) & ~((size_t)7);
    if (g_verbose) {
        fprintf(stderr, "new LC_LOAD_DYLIB cmdsize=%zu (dylib_command=%zu + path '%s' [%zu] padded)\n",
                cmd_size, sizeof(struct dylib_command),
                dylib_path, path_with_null);
    }

    uint64_t first_off = 0;
    if (find_first_section_offset(slice, ncmds, sizeofcmds, &first_off) != 0) {
        return 1;
    }
    size_t header_size = sizeof(struct mach_header_64);
    size_t after_new = header_size + sizeofcmds + cmd_size;
    if (g_verbose) {
        fprintf(stderr, "headroom: first-on-disk-data=0x%" PRIx64
                ", load-cmds-end=0x%zx, slack=%" PRId64 "\n",
                first_off, (size_t)(header_size + sizeofcmds),
                (int64_t)first_off - (int64_t)(header_size + sizeofcmds));
    }
    if (after_new > first_off) {
        fprintf(stderr,
                "insufficient headroom: need %zu bytes, have %" PRIu64 " (need %" PRIu64 " more)\n",
                cmd_size,
                (uint64_t)(first_off - (header_size + sizeofcmds)),
                (uint64_t)(after_new - first_off));
        return 1;
    }

    // The pad bytes between load-commands-end and first-section
    // should be zero. Warn if not — but still proceed (some binaries
    // have nonzero padding that's unused).
    uint8_t *new_cmd = slice + header_size + sizeofcmds;
    int nonzero_pad = 0;
    for (size_t i = 0; i < cmd_size; i++) {
        if (new_cmd[i] != 0) { nonzero_pad++; }
    }
    if (nonzero_pad && g_verbose) {
        fprintf(stderr,
                "WARN: %d non-zero bytes in pad area we're writing — original padding overwritten\n",
                nonzero_pad);
    }

    // Build the LC_LOAD_DYLIB.
    struct dylib_command *dc = (struct dylib_command *)new_cmd;
    memset(dc, 0, cmd_size);
    dc->cmd = LC_LOAD_DYLIB;
    dc->cmdsize = (uint32_t)cmd_size;
    dc->dylib.name.offset = sizeof(struct dylib_command);
    dc->dylib.timestamp = 2;
    dc->dylib.current_version = 0x010000;          // 1.0.0
    dc->dylib.compatibility_version = 0x010000;    // 1.0.0
    memcpy((uint8_t *)dc + sizeof(struct dylib_command), dylib_path,
           strlen(dylib_path));
    // Path bytes after the strlen are zero from the memset above —
    // serves as the trailing null + alignment pad.

    mh->ncmds = ncmds + 1;
    mh->sizeofcmds = (uint32_t)(sizeofcmds + cmd_size);
    if (g_verbose) {
        fprintf(stderr,
                "patched: ncmds %u -> %u, sizeofcmds %u -> %u\n",
                ncmds, mh->ncmds, sizeofcmds, mh->sizeofcmds);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <macho-path> <dylib-path>\n", argv[0]);
        return 2;
    }
    const char *bin_path = argv[1];
    const char *dylib_path = argv[2];

    int fd = open(bin_path, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    struct stat st;
    if (fstat(fd, &st) < 0) { perror("fstat"); close(fd); return 1; }

    size_t fsize = (size_t)st.st_size;
    void *map = mmap(NULL, fsize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); close(fd); return 1; }
    uint8_t *p = (uint8_t *)map;

    uint32_t magic = *(uint32_t *)p;

    int rc = 0;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        // Fat header is always big-endian on disk; on
        // little-endian hosts we see FAT_CIGAM and must byteswap.
        int swap = (magic == FAT_CIGAM);
        struct fat_header *fh = (struct fat_header *)p;
        uint32_t nfat = swap ? bswap32(fh->nfat_arch) : fh->nfat_arch;
        if (g_verbose) fprintf(stderr, "fat binary: %u archs\n", nfat);

        struct fat_arch *farch = (struct fat_arch *)(p + sizeof(struct fat_header));
        int patched = 0;
        for (uint32_t i = 0; i < nfat; i++) {
            uint32_t cputype = swap ? bswap32(farch[i].cputype) : farch[i].cputype;
            uint32_t cpusubtype = swap ? bswap32(farch[i].cpusubtype) : farch[i].cpusubtype;
            uint32_t offset = swap ? bswap32(farch[i].offset) : farch[i].offset;
            uint32_t size = swap ? bswap32(farch[i].size) : farch[i].size;
            uint32_t subtype_base = cpusubtype & ~0xFF000000u;

            // CPU_TYPE_ARM64 = 0x01000000 | 12 = 0x0100000c.
            // Patch every arm64* slice in the binary (subtype 0 = arm64,
            // subtype 2 = arm64e). macOS on Apple Silicon picks arm64e
            // first, but if dyld rejects the arm64e slice (e.g., from
            // our ad-hoc re-codesign), it falls back to arm64. Patching
            // both keeps the LC_LOAD_DYLIB intact across the
            // arm64e→arm64 fallback.
            if (cputype == 0x0100000c) {
                const char *subname = (subtype_base == 2) ? "arm64e" : "arm64";
                if (g_verbose) {
                    fprintf(stderr,
                            "%s slice at fat-offset 0x%08x, size 0x%x\n",
                            subname, offset, size);
                }
                rc = patch_slice(p + offset, size, dylib_path);
                if (rc != 0) goto done;
                (void)subname;
                patched = 1;
            }
        }
        if (!patched) {
            fprintf(stderr, "no arm64* slice in fat binary\n");
            rc = 1;
            goto done;
        }
    } else if (magic == MH_MAGIC_64) {
        rc = patch_slice(p, fsize, dylib_path);
        if (rc != 0) goto done;
    } else {
        fprintf(stderr, "unrecognized Mach-O magic 0x%08x\n", magic);
        rc = 1;
        goto done;
    }

    if (msync(map, fsize, MS_SYNC) != 0) { perror("msync"); rc = 1; }

done:
    munmap(map, fsize);
    close(fd);
    return rc;
}
