import Foundation

/// Every derivation and every sealed message names its purpose here.
///
/// The strings carry a version. Changing what a key is used for means adding a
/// new string, never editing one of these, because an edit would silently change
/// keys that already protect stored data.
public enum Context {
    public static let recordKey     = "wellspent/v1/record-key"
    public static let blobKey       = "wellspent/v1/blob-key"
    public static let groupWrap     = "wellspent/v1/group-wrap"
    public static let budgetWrap    = "wellspent/v1/budget-wrap"
    public static let recovery      = "wellspent/v1/recovery"
    public static let invitePSK     = "wellspent/v1/invite-psk"
    public static let inviteID      = "wellspent/v1/invite-id"
    public static let pairing       = "wellspent/v1/pairing"
    public static let fingerprint   = "wellspent/v1/fingerprint"
    public static let safetyNumber  = "wellspent/v1/safety-number"

    static func data(_ s: String) -> Data { Data(s.utf8) }
}
