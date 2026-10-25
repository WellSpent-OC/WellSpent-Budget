import Vapor
import WarTableCore

// Keep the portable DTO package independent of the HTTP framework.
extension WTInstallation: @retroactive Content {}
extension WTPerson: @retroactive Content {}
extension WTAgent: @retroactive Content {}
extension WTConversation: @retroactive Content {}
extension WTMessage: @retroactive Content {}
extension WTMessagePage: @retroactive Content {}
extension WTEvent: @retroactive Content {}
extension WTEventPage: @retroactive Content {}
extension WTContextSource: @retroactive Content {}
extension WTGrant: @retroactive Content {}
extension WTContextReceipt: @retroactive Content {}
extension WTTask: @retroactive Content {}
extension WTRun: @retroactive Content {}
extension WTEvidence: @retroactive Content {}
extension WTReview: @retroactive Content {}
extension WTSnapshot: @retroactive Content {}
extension WTConfigureRequest: @retroactive Content {}
extension WTSetRoleRequest: @retroactive Content {}
extension WTCreateConversation: @retroactive Content {}
extension WTPostMessage: @retroactive Content {}
extension WTReadReceipt: @retroactive Content {}
extension WTRedactRequest: @retroactive Content {}
extension WTEnrollAgentRequest: @retroactive Content {}
extension WTEnrollment: @retroactive Content {}
extension WTConnectRequest: @retroactive Content {}
extension WTCredential: @retroactive Content {}
extension WTAgentControl: @retroactive Content {}
extension WTPresenceRequest: @retroactive Content {}
extension WTCreateSource: @retroactive Content {}
extension WTCreateGrant: @retroactive Content {}
extension WTCreateTask: @retroactive Content {}
extension WTAuthorizeTask: @retroactive Content {}
extension WTClaimRun: @retroactive Content {}
extension WTRunCheckpoint: @retroactive Content {}
extension WTRunFinish: @retroactive Content {}
extension WTRecordEvidence: @retroactive Content {}
extension WTRecordReview: @retroactive Content {}
extension WTProviderCheck: @retroactive Content {}
extension WTTransferOwner: @retroactive Content {}
