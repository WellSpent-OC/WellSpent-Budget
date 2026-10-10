// Foundation on Linux has no security-scoped URLs, which AppModel.prepareImport
// calls. On macOS these return false and do nothing for a URL with no security
// scope, which is what every Linux file URL is. The import reads the same file
// either way.
#if !canImport(Darwin)
import Foundation

extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
#endif
