import Foundation
import VZKitObjC
import Virtualization

/// In-process VNC server wrapping the private `_VZVNCServer` SPI via a
/// tiny Obj-C bridge (`VZVNCBridge`). We go through Obj-C rather than
/// Swift's runtime ceremony so the 3-arg designated initializer's
/// retain semantics are unambiguous.
///
/// Stability note: this SPI has been stable in `Virtualization.framework`
/// from macOS 13 through 26. Apple could change it in 27+. The RFB
/// client (`RFBClient.swift`) doesn't know about VZ at all, so a
/// future transport swap (different SPI or — if Apple ever ships
/// one — a public API) is a one-file change.
public final class VNCSPI: @unchecked Sendable {
    public let port: UInt16
    private let serverHandle: NSObject

    private init(serverHandle: NSObject, port: UInt16) {
        self.serverHandle = serverHandle
        self.port = port
    }

    /// Create + start the in-process VNC server pointing at
    /// `virtualMachine`. Pass `port: 0` to let the kernel pick.
    /// Returns once the server has bound and is accepting connections;
    /// `port` exposes the actual bound port.
    @MainActor
    public static func start(
        virtualMachine: VZVirtualMachine,
        port: UInt16 = 0
    ) throws -> VNCSPI {
        var outPort: UInt = 0
        let handle: NSObject
        do {
            handle = try withUnsafeMutablePointer(to: &outPort) { outPortPtr in
                try VZVNCBridge.startServer(
                    with: virtualMachine,
                    port: UInt(port),
                    outPort: outPortPtr)
            }
        } catch {
            throw VMError("VNC server failed to start", underlying: error)
        }
        let actualPort = UInt16(clamping: outPort)
        Log.info("VNC server bound at localhost:\(actualPort)")
        return VNCSPI(serverHandle: handle, port: actualPort)
    }

    public func stop() {
        VZVNCBridge.stop(serverHandle)
    }
}
