import Foundation
import PreviewsJITLink
import Testing

struct PreviewsJITLinkTests {
    @Test func linksCObject() throws {
        let object = try FixtureSupport.compile("answer.c")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "answer")
        #expect(result == 42)
    }

    @Test(.timeLimit(.minutes(5))) func survivesRepeatedRemoteSessionBootstrap() throws {
        let agentPath = try JITSession.bundledAgentPath()
        for _ in 0 ..< 40 {
            _ = try JITSession(remoteAgentPath: agentPath)
        }
    }

    @Test(.timeLimit(.minutes(5))) func reusesMemoryAfterAbandonedLinksRemotely() throws {
        let drain = try FixtureSupport.compile("abandon_drain.c")
        let slab = try FixtureSupport.compile("abandon_slab.c")
        let probe = try FixtureSupport.compile("abandon_probe.c")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: drain.path)
        #expect(throws: JITLinkError.self) {
            try session.runMain(symbol: "abandon_drain_entry")
        }
        try session.addObject(path: slab.path)
        #expect(throws: JITLinkError.self) {
            try session.runMain(symbol: "abandon_slab_entry")
        }
        try session.addObject(path: probe.path)
        #expect(try session.runMain(symbol: "abandon_probe_value") == 42)
    }

    @Test func linksCObjectRemotely() throws {
        let object = try FixtureSupport.compile("answer.c")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "answer")
        #expect(result == 42)
    }

    @Test func runsObjectInitializerRemotely() throws {
        let object = try FixtureSupport.compile("ctor.c")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "ctor_answer")
        #expect(result == 42)
    }

    @Test func resolvesThreadLocalStorageRemotely() throws {
        let object = try FixtureSupport.compile("tlv.c")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "tlv_value")
        #expect(result == 43)
    }

    @Test func linksSwiftObjectRemotely() throws {
        let object = try FixtureSupport.compile("swift_answer.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "swift_answer")
        #expect(result == 42)
    }

    @Test func dispatchesThroughWitnessTableRemotely() throws {
        let object = try FixtureSupport.compile("witness.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "witness_value")
        #expect(result == 7)
    }

    @Test func resolvesConformanceThroughRuntimeRegistryRemotely() throws {
        let object = try FixtureSupport.compile("dynamic_cast.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "dynamic_cast_value")
        #expect(result == 9)
    }

    @Test func runsSwiftOnceInitializerRemotely() throws {
        let object = try FixtureSupport.compile("swift_once.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "swift_once_value")
        #expect(result == 5050)
    }

    @Test func dispatchesObjCSelectorRemotely() throws {
        let object = try FixtureSupport.compile("objc_selref.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "objc_selref_value")
        #expect(result == 42)
    }

    @Test func registersObjCClassRemotely() throws {
        let object = try FixtureSupport.compile("objc_class.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "objc_class_value")
        #expect(result == 42)
    }

    @Test func runsAsyncFunctionRemotely() throws {
        let object = try FixtureSupport.compile("async_value.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "async_value")
        #expect(result == 11)
    }

    @Test func runsSwiftUIViewBodyRemotely() throws {
        let object = try FixtureSupport.compile("swiftui_probe.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "swiftui_probe_value")
        #expect(result == 7)
    }

    @Test func agentDispatchesAppKitEvents() throws {
        let object = try FixtureSupport.compile("event_loop_probe.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        #expect(try session.runOnMain(symbol: "event_pump_install") == 1)
        // #391 sub-mechanism probe: correlate fireDelay with the run-loop
        // cycle-rate under whatever load this instance sees. Measure cycles over
        // a fixed ~3s window (light polling) regardless of when the event fires.
        let t0 = Date().timeIntervalSince1970
        let cyc0 = try session.runOnMain(symbol: "event_pump_loop_cycles")
        var observed: Int32 = 0
        for _ in 0 ..< 100 where observed != 1 {
            Thread.sleep(forTimeInterval: 0.1)
            observed = try session.runOnMain(symbol: "event_pump_check")
        }
        // keep sampling cycles to the ~3s mark for a stable rate
        while Date().timeIntervalSince1970 - t0 < 3.0 { Thread.sleep(forTimeInterval: 0.1) }
        let cyc1 = try session.runOnMain(symbol: "event_pump_loop_cycles")
        let fireDelay = try session.runOnMain(symbol: "event_pump_fire_delay_ms")
        let winMs = (Date().timeIntervalSince1970 - t0) * 1000
        let rate = Double(cyc1 - cyc0) / (winMs / 1000)
        FileHandle.standardError.write(Data(
            "MODE-PROBE: fireDelayMs=\(fireDelay) loopCyclesPerSec=\(Int(rate)) cycles=\(cyc1 - cyc0) winMs=\(Int(winMs))\n".utf8))
        #expect(observed == 1)
    }

    // #391 diagnostic: deterministic, clean-host proof of the control-starvation
    // mechanism AND the timer fix. Do not merge.
    @Test func deterministicControlStarvationRepro() throws {
        let object = try FixtureSupport.compile("event_loop_starve_probe.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        func diag(_ m: String) { FileHandle.standardError.write(Data("STARVE-DIAG: \(m)\n".utf8)) }

        #expect(try session.runOnMain(symbol: "starve_install") == 1)
        // Phase A — wedge: main dispatch queue starved, NO timer. Poll ~6s.
        let cyc0 = try session.runOnMain(symbol: "starve_loop_cycles")
        var obsA: Int32 = 0
        var pollsA = 0
        for _ in 0 ..< 60 where obsA != 1 {
            Thread.sleep(forTimeInterval: 0.1)
            obsA = try session.runOnMain(symbol: "starve_check")
            pollsA += 1
        }
        let cyc1 = try session.runOnMain(symbol: "starve_loop_cycles")
        diag("PHASE A no-timer: observed=\(obsA) pollsAnswered=\(pollsA) loopCycles \(cyc0)->\(cyc1)")

        // Phase B — fix: install the repeating timer. Poll ~6s.
        _ = try session.runOnMain(symbol: "starve_install_timer")
        var obsB: Int32 = obsA
        for _ in 0 ..< 60 where obsB != 1 {
            Thread.sleep(forTimeInterval: 0.1)
            obsB = try session.runOnMain(symbol: "starve_check")
        }
        let cyc2 = try session.runOnMain(symbol: "starve_loop_cycles")
        diag("PHASE B +timer: observed=\(obsB) loopCycles ->\(cyc2)")
        let confirmed = obsA == 0 && pollsA >= 10 && obsB == 1 && cyc2 > cyc1
        diag("VERDICT: \(confirmed ? "MECHANISM+FIX CONFIRMED" : "INCONCLUSIVE")")
        _ = try session.runOnMain(symbol: "starve_stop")
        #expect(confirmed)
    }

    @Test func buildsHostingViewOnMainThreadRemotely() throws {
        let object = try FixtureSupport.compile("hosting_probe.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let result = try session.runOnMain(symbol: "hosting_probe_value")
        #expect(result == 1)
    }

    @Test func rendersViewToBitmapOnMainThreadRemotely() throws {
        let object = try FixtureSupport.compile("render_probe.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        let packed = try session.runOnMain(symbol: "render_probe_value")
        #expect(packed >= 0)
        let r = (packed >> 16) & 0xFF
        let g = (packed >> 8) & 0xFF
        let b = packed & 0xFF
        #expect(r > 200 && g < 60 && b < 60)
    }

    @Test func publishesNewAddressIntoSlotRemotely() throws {
        let object = try FixtureSupport.compile("patch_slot.c")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        #expect(try session.runMain(symbol: "patch_slot_call") == 1)

        let slot = try session.address(of: "patch_slot_fn")
        let v2 = try session.address(of: "impl_v2")
        try session.writePointer(at: slot, value: v2)

        #expect(try session.runMain(symbol: "patch_slot_call") == 2)
    }

    @Test func linksSwiftObject() throws {
        let object = try FixtureSupport.compile("swift_answer.swift")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "swift_answer")
        #expect(result == 42)
    }

    @Test func resolvesProcessSymbolThroughExecutor() throws {
        let object = try FixtureSupport.compile("external.c", extraFlags: ["-fno-builtin"])
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "compute")
        #expect(result == 42)
    }

    @Test func throwsOnMissingSymbol() throws {
        let object = try FixtureSupport.compile("answer.c")
        let session = try JITSession()
        try session.addObject(path: object.path)
        #expect(throws: JITLinkError.self) {
            let _: Int32 = try session.call(symbol: "does_not_exist")
        }
    }

    @Test func runsObjectInitializer() throws {
        let object = try FixtureSupport.compile("ctor.c")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "ctor_answer")
        #expect(result == 42)
    }

    @Test func dispatchesThroughWitnessTable() throws {
        let object = try FixtureSupport.compile("witness.swift")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "witness_value")
        #expect(result == 7)
    }

    @Test func resolvesConformanceThroughRuntimeRegistry() throws {
        let object = try FixtureSupport.compile("dynamic_cast.swift")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "dynamic_cast_value")
        #expect(result == 9)
    }

    @Test func resolvesThreadLocalStorage() throws {
        let object = try FixtureSupport.compile("tlv.c")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "tlv_value")
        #expect(result == 43)
    }

    @Test func dispatchesObjCSelector() throws {
        let object = try FixtureSupport.compile("objc_selref.swift")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "objc_selref_value")
        #expect(result == 42)
    }

    @Test func runsSwiftOnceInitializer() throws {
        let object = try FixtureSupport.compile("swift_once.swift")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "swift_once_value")
        #expect(result == 5050)
    }

    @Test func registersObjCClass() throws {
        let object = try FixtureSupport.compile("objc_class.swift")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "objc_class_value")
        #expect(result == 42)
    }

    @Test func runsAsyncFunction() throws {
        let object = try FixtureSupport.compile("async_value.swift")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "async_value")
        #expect(result == 11)
    }
}
