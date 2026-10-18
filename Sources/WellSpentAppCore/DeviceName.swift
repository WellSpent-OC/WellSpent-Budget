import Foundation
#if os(macOS)
import SystemConfiguration
#endif
#if canImport(Glibc)
import Glibc
#endif

/// The name this device shows in the account's list of signed-in devices.
///
/// Read without asking the network. `ProcessInfo.hostName` looks the
/// machine's name up, and where nothing answers that lookup it waits about
/// 30 seconds. It ran on the main thread at every sign-in, so the app froze
/// for that long on such networks (seen on GitHub's Mac runners, 2026-10-17).
public enum DeviceName {
    /// Read once per launch.
    public static let current: String = read()

    static func read() -> String {
        #if os(macOS)
        // The Computer Name from System Settings, such as "Robin's MacBook".
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        #elseif os(iOS)
        // Naming the device itself needs a permission on recent iOS.
        return "iPhone"
        #endif
        return kernelHostName() ?? "A computer"
    }

    /// The kernel's own host name, which needs no lookup, without ".local".
    static func kernelHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        var name = String(cString: buffer)
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        return name.isEmpty ? nil : name
    }
}
