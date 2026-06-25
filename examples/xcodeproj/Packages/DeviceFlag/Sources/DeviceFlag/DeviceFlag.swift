import DeviceCheck
import Foundation

/// Touches the DeviceCheck system framework so this package's object closure
/// references a framework the preview agent never links itself (issue #281, layer 4).
public enum DeviceFlag {
    public static let isDeviceCheckSupported: Bool = DCDevice.current.isSupported

    public static func badgeText() -> String {
        isDeviceCheckSupported ? "Verified device" : "Unverified device"
    }
}
