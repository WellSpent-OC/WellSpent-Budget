import Testing
import Foundation
@testable import WellSpentCrypto

struct OwnerStampTests {
    private let owner = UserID(UUID(uuidString: "6F0C0B52-0F8D-4C55-9D1A-2B1C3E4F5A6B")!)

    private func object(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try #require(parsed as? [String: Any])
    }

    @Test func setsTheOwnerAndKeepsFieldsItDoesNotKnow() throws {
        let body = Data(#"{"id":"A","amount":{"minorUnits":-1250},"date":"2026-11-04T00:00:00Z","cleared":true,"newField":{"kept":["x/y",1]}}"#.utf8)
        let stamped = try object(RecordCodec.stampingOwner(body, owner: owner))
        #expect(stamped["createdBy"] as? String == owner.uuid.uuidString)
        #expect((stamped["amount"] as? [String: Any])?["minorUnits"] as? Int == -1250)
        #expect(stamped["date"] as? String == "2026-11-04T00:00:00Z")
        #expect(stamped["cleared"] as? Bool == true)
        let kept = try #require((stamped["newField"] as? [String: Any])?["kept"] as? [Any])
        #expect(kept.first as? String == "x/y", "a field this build does not know survives")
    }

    @Test func aBodyThatIsNotAnObjectIsRefused() {
        #expect(RecordCodec.stampingOwner(Data("[1,2]".utf8), owner: owner) == nil)
        #expect(RecordCodec.stampingOwner(Data("not json".utf8), owner: owner) == nil)
    }
}
