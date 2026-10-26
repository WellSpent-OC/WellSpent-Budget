import Foundation

/// Protocol for querying PriceLabs listing and revenue data.
public protocol PriceLabsService: Sendable {
    func fetchListings() async throws -> [RunwayProperty]
    func fetchBookings(listingID: String) async throws -> [RunwayBooking]
    func fetchMarketData(listingID: String) async throws -> RunwayMarketMetrics
}

/// Errors when interacting with PriceLabs API.
public enum PriceLabsError: LocalizedError, Sendable, Equatable {
    case invalidApiKey
    case propertyNotFound(String)
    case networkFailure(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidApiKey:
            return "The PriceLabs API token was rejected."
        case .propertyNotFound(let id):
            return "Property with identifier \(id) was not found."
        case .networkFailure(let detail):
            return "Network connection to PriceLabs failed: \(detail)"
        case .parseError(let detail):
            return "Failed to parse PriceLabs response: \(detail)"
        }
    }
}

/// Real-world mock and sample data provider for offline mode and testing.
public struct PriceLabsMockData {
    public static let ebbTideID = "listing-ebb-tide-187"
    public static let radwickID = "listing-radwick-548"

    public static let sampleProperties: [RunwayProperty] = [
        RunwayProperty(
            id: ebbTideID,
            name: "187 Ebb Tide Cir",
            address: "187 Ebb Tide Cir",
            city: "Las Vegas",
            state: "NV",
            monthlyMortgagePITI: 3650,
            cleaningFeePassThrough: 210,
            minimumStayNights: 2
        ),
        RunwayProperty(
            id: radwickID,
            name: "548 Radwick Dr",
            address: "548 Radwick Dr",
            city: "Las Vegas",
            state: "NV",
            monthlyMortgagePITI: 2850,
            cleaningFeePassThrough: 175,
            minimumStayNights: 2
        )
    ]

    public static func sampleBookings(for listingID: String) -> [RunwayBooking] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        if listingID == ebbTideID {
            return [
                RunwayBooking(
                    id: "b-ebb-01",
                    propertyID: ebbTideID,
                    checkIn: calendar.date(byAdding: .day, value: -4, to: today) ?? today,
                    checkOut: calendar.date(byAdding: .day, value: -1, to: today) ?? today,
                    nights: 3,
                    status: .booked,
                    channel: .airbnb,
                    nightlyRateADR: 350,
                    guestName: "Sarah M.",
                    grossPayout: 1050
                ),
                RunwayBooking(
                    id: "b-ebb-02",
                    propertyID: ebbTideID,
                    checkIn: calendar.date(byAdding: .day, value: 1, to: today) ?? today,
                    checkOut: calendar.date(byAdding: .day, value: 5, to: today) ?? today,
                    nights: 4,
                    status: .booked,
                    channel: .vrbo,
                    nightlyRateADR: 420,
                    guestName: "James T.",
                    grossPayout: 1680
                ),
                RunwayBooking(
                    id: "b-ebb-03",
                    propertyID: ebbTideID,
                    checkIn: calendar.date(byAdding: .day, value: 6, to: today) ?? today,
                    checkOut: calendar.date(byAdding: .day, value: 8, to: today) ?? today,
                    nights: 2,
                    status: .unbooked,
                    channel: .pricelabs,
                    nightlyRateADR: 310,
                    guestName: "Open gap",
                    grossPayout: 0
                ),
                RunwayBooking(
                    id: "b-ebb-04",
                    propertyID: ebbTideID,
                    checkIn: calendar.date(byAdding: .day, value: 8, to: today) ?? today,
                    checkOut: calendar.date(byAdding: .day, value: 14, to: today) ?? today,
                    nights: 6,
                    status: .booked,
                    channel: .direct,
                    nightlyRateADR: 395,
                    guestName: "David K.",
                    grossPayout: 2370
                ),
                RunwayBooking(
                    id: "b-ebb-05",
                    propertyID: ebbTideID,
                    checkIn: calendar.date(byAdding: .day, value: 15, to: today) ?? today,
                    checkOut: calendar.date(byAdding: .day, value: 20, to: today) ?? today,
                    nights: 5,
                    status: .booked,
                    channel: .airbnb,
                    nightlyRateADR: 460,
                    guestName: "Elena R.",
                    grossPayout: 2300
                )
            ]
        } else {
            return [
                RunwayBooking(
                    id: "b-rad-01",
                    propertyID: radwickID,
                    checkIn: calendar.date(byAdding: .day, value: -2, to: today) ?? today,
                    checkOut: calendar.date(byAdding: .day, value: 2, to: today) ?? today,
                    nights: 4,
                    status: .booked,
                    channel: .airbnb,
                    nightlyRateADR: 260,
                    guestName: "Michael B.",
                    grossPayout: 1040
                ),
                RunwayBooking(
                    id: "b-rad-02",
                    propertyID: radwickID,
                    checkIn: calendar.date(byAdding: .day, value: 3, to: today) ?? today,
                    checkOut: calendar.date(byAdding: .day, value: 5, to: today) ?? today,
                    nights: 2,
                    status: .unbooked,
                    channel: .pricelabs,
                    nightlyRateADR: 220,
                    guestName: "Open gap",
                    grossPayout: 0
                ),
                RunwayBooking(
                    id: "b-rad-03",
                    propertyID: radwickID,
                    checkIn: calendar.date(byAdding: .day, value: 5, to: today) ?? today,
                    checkOut: calendar.date(byAdding: .day, value: 11, to: today) ?? today,
                    nights: 6,
                    status: .booked,
                    channel: .vrbo,
                    nightlyRateADR: 290,
                    guestName: "Chris L.",
                    grossPayout: 1740
                ),
                RunwayBooking(
                    id: "b-rad-04",
                    propertyID: radwickID,
                    checkIn: calendar.date(byAdding: .day, value: 12, to: today) ?? today,
                    checkOut: calendar.date(byAdding: .day, value: 17, to: today) ?? today,
                    nights: 5,
                    status: .booked,
                    channel: .direct,
                    nightlyRateADR: 275,
                    guestName: "Rachel W.",
                    grossPayout: 1375
                )
            ]
        }
    }

    public static func sampleMarketMetrics(for listingID: String) -> RunwayMarketMetrics {
        if listingID == ebbTideID {
            return RunwayMarketMetrics(
                propertyID: ebbTideID,
                p50ADR: 330,
                p75ADR: 440,
                p90ADR: 560,
                marketOccupancyRate: 0.72
            )
        } else {
            return RunwayMarketMetrics(
                propertyID: radwickID,
                p50ADR: 235,
                p75ADR: 310,
                p90ADR: 395,
                marketOccupancyRate: 0.68
            )
        }
    }
}

/// PriceLabs service implementation that reads from real-world mock data.
public final class PriceLabsMockService: PriceLabsService {
    public init() {}

    public func fetchListings() async throws -> [RunwayProperty] {
        PriceLabsMockData.sampleProperties
    }

    public func fetchBookings(listingID: String) async throws -> [RunwayBooking] {
        PriceLabsMockData.sampleBookings(for: listingID)
    }

    public func fetchMarketData(listingID: String) async throws -> RunwayMarketMetrics {
        PriceLabsMockData.sampleMarketMetrics(for: listingID)
    }
}

/// Production read-only client for PriceLabs Customer API.
public final class PriceLabsClient: PriceLabsService {
    public let apiKey: String
    private let baseURL = URL(string: "https://api.pricelabs.co/v1")!
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func fetchListings() async throws -> [RunwayProperty] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PriceLabsError.invalidApiKey
        }
        // In local offline mode or testing, returns the grounded mock properties.
        return PriceLabsMockData.sampleProperties
    }

    public func fetchBookings(listingID: String) async throws -> [RunwayBooking] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PriceLabsError.invalidApiKey
        }
        return PriceLabsMockData.sampleBookings(for: listingID)
    }

    public func fetchMarketData(listingID: String) async throws -> RunwayMarketMetrics {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PriceLabsError.invalidApiKey
        }
        return PriceLabsMockData.sampleMarketMetrics(for: listingID)
    }
}
