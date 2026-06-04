//===-- host_split.cpp - W7 integrated auto-split POC host -----*- C++ -*-===//
//
// Integrated auto-split POC: the agent-side half of G1 path (b).
//
//   1. LLJIT + ObjectLinkingLayer with the ObjCSelrefPlugin and an
//      explicit MachOPlatform (ExecutorNativePlatform + orc_rt), the
//      same setup host_objc.cpp validated — SwiftUI/AppKit code paths
//      are selref-heavy and abort in __forwarding__ without it.
//   2. dlopens the STABLE module (libStable.dylib, built
//      -enable-testing) with RTLD_GLOBAL so its symbols — including
//      `internal` ones the preview reaches via @testable — resolve
//      through the process symbol generator. Its load commands pull
//      SwiftUI/AppKit/swiftCore into the process.
//   3. Adds split_preview_v1.o (the editable unit, compiled
//      single-file against the prebuilt Stable.swiftmodule) into a
//      fresh JD, looks up `preview_render_pixel`, calls it on the
//      main thread. The JIT'd code builds a SwiftUI view that
//      instantiates the stable module's internal StableView, renders
//      via ImageRenderer, and returns the (0,0) pixel packed RGB.
//   4. Same for split_preview_v2.o in another fresh JD (the
//      post-edit generation — mirrors W3/W4 respawn semantics, no
//      in-place patch).
//   5. Verifies v1 pixel != v2 pixel and prints per-stage wall-clock
//      (link = addObjectFile+lookup, render = the call).
//
//===----------------------------------------------------------------------===//

#include "ObjCSelrefPlugin.hpp"

#include "llvm/ExecutionEngine/Orc/Core.h"
#include "llvm/ExecutionEngine/Orc/ExecutionUtils.h"
#include "llvm/ExecutionEngine/Orc/LLJIT.h"
#include "llvm/ExecutionEngine/Orc/MachOPlatform.h"
#include "llvm/ExecutionEngine/Orc/ObjectLinkingLayer.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <mach/mach.h>
#include <memory>
#include <string>
#include <vector>

using namespace llvm;
using namespace llvm::orc;

[[noreturn]] static void diefmt(const char *msg, Error E) {
    std::string es;
    raw_string_ostream os(es);
    os << E;
    fprintf(stderr, "FATAL: %s: %s\n", msg, es.c_str());
    fflush(stderr);
    std::exit(1);
}

template <typename T>
static T &must(const char *msg, Expected<T &> E) {
    if (!E)
        diefmt(msg, E.takeError());
    return *E;
}

template <typename T>
static T must(const char *msg, Expected<T> E) {
    if (!E)
        diefmt(msg, E.takeError());
    return std::move(*E);
}

static void must(const char *msg, Error E) {
    if (E)
        diefmt(msg, std::move(E));
}

static std::unique_ptr<MemoryBuffer> loadObject(const char *Path) {
    auto BufOrErr = MemoryBuffer::getFile(Path);
    if (!BufOrErr) {
        fprintf(stderr, "FATAL: failed to read object file %s: %s\n",
                Path, BufOrErr.getError().message().c_str());
        std::exit(1);
    }
    return std::move(*BufOrErr);
}

static double msSince(std::chrono::steady_clock::time_point t0) {
    return std::chrono::duration<double, std::milli>(
               std::chrono::steady_clock::now() - t0)
        .count();
}

static double rssMB() {
    mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS)
        return -1.0;
    return (double)info.resident_size / (1024.0 * 1024.0);
}

static double median(std::vector<double> v) {
    if (v.empty())
        return 0.0;
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

int main(int argc, char **argv) {
    InitLLVM X(argc, argv);

    if (argc != 4 && argc != 5 && argc != 6) {
        fprintf(stderr,
                "usage: %s <orc_rt_osx.a> <libStable.dylib>"
                " <split_preview_v1.o> [<split_preview_v2.o> [soakN]]\n",
                argv[0]);
        return 2;
    }
    const char *OrcRTPath = argv[1];
    const char *StablePath = argv[2];
    const char *V1Path = argv[3];
    const char *V2Path = (argc >= 5) ? argv[4] : nullptr;
    int SoakN = (argc == 6) ? atoi(argv[5]) : 0;

    InitializeNativeTarget();
    InitializeNativeTargetAsmPrinter();
    InitializeNativeTargetAsmParser();

    auto Plugin = std::make_shared<previewsvm::ObjCSelrefPlugin>(
        /*Verbose=*/false);

    auto JIT = must("LLJITBuilder::create",
        LLJITBuilder()
            .setObjectLinkingLayerCreator(
                [Plugin](ExecutionSession &ES)
                    -> Expected<std::unique_ptr<ObjectLayer>> {
                    auto OLL =
                        std::make_unique<ObjectLinkingLayer>(ES);
                    OLL->setAutoClaimResponsibilityForObjectSymbols(
                        true);
                    OLL->addPlugin(Plugin);
                    return OLL;
                })
            .setPlatformSetUp(orc::ExecutorNativePlatform(OrcRTPath))
            .create());

    fprintf(stdout, "[host] LLJIT target triple: %s\n",
            JIT->getTargetTriple().str().c_str());

    auto &MainJD = JIT->getMainJITDylib();

    {
        auto Gen = must(
            "DynamicLibrarySearchGenerator::GetForCurrentProcess",
            DynamicLibrarySearchGenerator::GetForCurrentProcess(
                JIT->getDataLayout().getGlobalPrefix()));
        MainJD.addGenerator(std::move(Gen));
    }

    auto tryDLOpen = [](std::initializer_list<const char *> Paths,
                        const char *Label) {
        for (const char *P : Paths) {
            if (dlopen(P, RTLD_NOW | RTLD_GLOBAL)) {
                fprintf(stdout, "[host] dlopened %s via %s\n", Label, P);
                return;
            }
        }
        fprintf(stderr, "[host] WARNING: could not dlopen %s: %s\n",
                Label, dlerror());
    };
    tryDLOpen({"/usr/lib/swift/libswiftCore.dylib"}, "libswiftCore");

    // The stable module. RTLD_GLOBAL exposes its exported symbols
    // (Swift `internal` decls are still exported from a dylib) to the
    // process search generator; its load commands pull in SwiftUI,
    // AppKit, Foundation, and the rest of the Swift runtime.
    {
        auto t0 = std::chrono::steady_clock::now();
        if (!dlopen(StablePath, RTLD_NOW | RTLD_GLOBAL)) {
            fprintf(stderr, "FATAL: dlopen(%s) failed: %s\n",
                    StablePath, dlerror());
            return 1;
        }
        fprintf(stdout, "[host] dlopened stable module %s (%.1f ms)\n",
                StablePath, msSince(t0));
    }

    auto renderIn = [&](JITDylib &JD, const char *Label,
                        const char *ObjPath) -> uint32_t {
        auto t0 = std::chrono::steady_clock::now();
        auto Buf = loadObject(ObjPath);
        must("addObjectFile(preview)",
             JIT->addObjectFile(JD, std::move(Buf)));

        auto &ES = JIT->getExecutionSession();
        auto MangledName = ES.intern(
            JIT->getDataLayout().getGlobalPrefix() == '\0'
                ? "preview_render_pixel"
                : "_preview_render_pixel");
        auto Sym = must("ES.lookup(_preview_render_pixel)",
                        ES.lookup({{&JD, JITDylibLookupFlags::MatchAllSymbols}},
                                  MangledName));
        // Run the platform's jit_dlopen for this JD: registers the
        // object's __swift5_* metadata sections with the Swift runtime
        // (SwiftUI does runtime conformance lookups) and __objc_*
        // with libobjc, then runs initializers.
        must("initialize(JD)", JIT->initialize(JD));
        double linkMs = msSince(t0);

        auto FP = Sym.getAddress().toPtr<uint32_t (*)()>();
        fprintf(stdout,
                "[host] %s preview_render_pixel resolved to %p "
                "(link %.1f ms); rendering...\n",
                Label, (void *)FP, linkMs);
        fflush(stdout);
        auto t1 = std::chrono::steady_clock::now();
        uint32_t px = FP();
        double renderMs = msSince(t1);
        fprintf(stdout, "[host] %s pixel(0,0) = 0x%06X (render %.1f ms)\n",
                Label, px, renderMs);
        fflush(stdout);
        return px;
    };

    auto &V1JD = must("createJITDylib(v1)", JIT->createJITDylib("v1"));
    V1JD.setLinkOrder({{&V1JD, JITDylibLookupFlags::MatchAllSymbols},
                       {&MainJD, JITDylibLookupFlags::MatchAllSymbols}},
                      /*LinkAgainstThisJITDylibFirst=*/false);
    uint32_t Px1 = renderIn(V1JD, "v1", V1Path);

    if (V2Path) {
        auto &V2JD = must("createJITDylib(v2)", JIT->createJITDylib("v2"));
        V2JD.setLinkOrder({{&V2JD, JITDylibLookupFlags::MatchAllSymbols},
                           {&MainJD, JITDylibLookupFlags::MatchAllSymbols}},
                          /*LinkAgainstThisJITDylibFirst=*/false);
        uint32_t Px2 = renderIn(V2JD, "v2", V2Path);

        if (Px1 == Px2 || Px1 >= 0xBEEF0000 || Px2 >= 0xBEEF0000) {
            fprintf(stdout,
                    "[host] VERDICT: FAIL (v1=0x%06X v2=0x%06X)\n",
                    Px1, Px2);
            return 1;
        }
        fprintf(stdout,
                "[host] VERDICT: PASS — pixels differ across the edit "
                "(v1=0x%06X v2=0x%06X)\n", Px1, Px2);
    }

    // -------- generation soak (persistent-agent viability) ----------
    //
    // Persistent-agent risk: Swift has no deregistration for
    // __swift5_proto/__swift5_types, so every generation's
    // initialize(JD) permanently grows the runtime's registries, and
    // conformance scans walk them. Soak N generations in THIS process
    // (fresh JD each, alternating v1/v2) and watch per-generation
    // link/render latency + RSS. Any mprotect/MAP_JIT denial surfaces
    // as a loud must() failure.
    if (SoakN > 0 && V2Path) {
        fprintf(stdout, "\n[host] === soak: %d generations ===\n", SoakN);
        fprintf(stdout,
                "[soak] gen_window  link_med_ms  render_med_ms  rss_mb\n");
        auto &ES = JIT->getExecutionSession();
        auto MangledName = ES.intern(
            JIT->getDataLayout().getGlobalPrefix() == '\0'
                ? "preview_render_pixel"
                : "_preview_render_pixel");
        std::vector<double> linkW, renderW;
        double rss0 = rssMB();
        fprintf(stdout, "[soak] baseline rss %.1f MB\n", rss0);
        for (int i = 0; i < SoakN; ++i) {
            const char *Obj = (i & 1) ? V2Path : V1Path;
            uint32_t Want = (i & 1) ? 0x0000FFu : 0xFF0000u;
            char Name[32];
            snprintf(Name, sizeof Name, "gen%d", i);
            auto &JD = must("createJITDylib(gen)",
                            JIT->createJITDylib(Name));
            JD.setLinkOrder(
                {{&JD, JITDylibLookupFlags::MatchAllSymbols},
                 {&MainJD, JITDylibLookupFlags::MatchAllSymbols}},
                /*LinkAgainstThisJITDylibFirst=*/false);
            auto t0 = std::chrono::steady_clock::now();
            must("addObjectFile(soak gen)",
                 JIT->addObjectFile(JD, loadObject(Obj)));
            auto Sym = must("ES.lookup(soak gen)",
                            ES.lookup({{&JD,
                                        JITDylibLookupFlags::MatchAllSymbols}},
                                      MangledName));
            must("initialize(soak gen)", JIT->initialize(JD));
            double linkMs = msSince(t0);
            auto FP = Sym.getAddress().toPtr<uint32_t (*)()>();
            auto t1 = std::chrono::steady_clock::now();
            uint32_t px = FP();
            double renderMs = msSince(t1);
            if (px != Want) {
                fprintf(stdout,
                        "[soak] gen %d WRONG PIXEL 0x%06X (want 0x%06X)\n",
                        i, px, Want);
                return 1;
            }
            linkW.push_back(linkMs);
            renderW.push_back(renderMs);
            if ((i + 1) % 50 == 0) {
                fprintf(stdout, "[soak] %4d-%-4d  %8.2f  %10.2f  %7.1f\n",
                        i - 48, i + 1, median(linkW), median(renderW),
                        rssMB());
                fflush(stdout);
                linkW.clear();
                renderW.clear();
            }
        }
        double rss1 = rssMB();
        fprintf(stdout,
                "[soak] done: %d generations, rss %.1f -> %.1f MB "
                "(%.2f MB per 100 generations)\n",
                SoakN, rss0, rss1, (rss1 - rss0) * 100.0 / SoakN);
    }

    fprintf(stdout, "[host] done.\n");
    return 0;
}
