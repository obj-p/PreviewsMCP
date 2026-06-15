import Darwin
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        root.view.backgroundColor = .white
        window.rootViewController = root
        self.window = window
        window.makeKeyAndVisible()

        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--jit-port"), i + 1 < args.count,
            let port = UInt16(args[i + 1])
        {
            Thread.detachNewThread {
                let fd = Self.connectLoopback(port: port)
                guard fd >= 0 else {
                    NSLog("jit-host: failed to connect on port \(port)")
                    return
                }
                _ = previewsmcp_ios_executor_start(fd, fd)
            }
        }
        return true
    }

    private static func connectLoopback(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = (0x7f00_0001 as in_addr_t).bigEndian
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 {
            close(fd)
            return -1
        }
        return fd
    }
}
