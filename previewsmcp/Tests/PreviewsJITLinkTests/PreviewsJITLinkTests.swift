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
        var observed: Int32 = 0
        for _ in 0 ..< 20 where observed != 1 {
            Thread.sleep(forTimeInterval: 0.1)
            observed = try session.runOnMain(symbol: "event_pump_check")
        }
        #expect(observed == 1)
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
