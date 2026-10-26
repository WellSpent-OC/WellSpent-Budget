import Foundation

/// A short term rental property tracked in Runway.
public struct RunwayProperty: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let address: String
    public let city: String
    public let state: String
    public let monthlyMortgagePITI: Decimal
    public let cleaningFeePassThrough: Decimal
    public let minimumStayNights: Int
    public let currency: String

    public init(
        id: String,
        name: String,
        address: String,
        city: String,
        state: String,
        monthlyMortgagePITI: Decimal,
        cleaningFeePassThrough: Decimal = 180,
        minimumStayNights: Int = 2,
        currency: String = "USD"
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.city = city
        self.state = state
        self.monthlyMortgagePITI = monthlyMortgagePITI
        self.cleaningFeePassThrough = cleaningFeePassThrough
        self.minimumStayNights = minimumStayNights
        self.currency = currency
    }
}

/// The status of a night on the property calendar.
public enum RunwayBookingStatus: String, Sendable, Equatable, Codable {
    case booked
    case unbooked
    case blocked
}

/// The booking channel that provided the reservation.
public enum RunwayChannel: String, Sendable, Equatable, Codable {
    case airbnb = "Airbnb"
    case vrbo = "VRBO"
    case direct = "Direct"
    case pricelabs = "PriceLabs"
}

/// A calendar reservation or open window for a property.
public struct RunwayBooking: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let propertyID: String
    public let checkIn: Date
    public let checkOut: Date
    public let nights: Int
    public let status: RunwayBookingStatus
    public let channel: RunwayChannel
    public let nightlyRateADR: Decimal
    public let guestName: String
    public let grossPayout: Decimal

    public init(
        id: String,
        propertyID: String,
        checkIn: Date,
        checkOut: Date,
        nights: Int,
        status: RunwayBookingStatus,
        channel: RunwayChannel,
        nightlyRateADR: Decimal,
        guestName: String = "",
        grossPayout: Decimal = 0
    ) {
        self.id = id
        self.propertyID = propertyID
        self.checkIn = checkIn
        self.checkOut = checkOut
        self.nights = nights
        self.status = status
        self.channel = channel
        self.nightlyRateADR = nightlyRateADR
        self.guestName = guestName
        self.grossPayout = grossPayout
    }
}

/// Market ADR percentiles and occupancy rates from PriceLabs.
public struct RunwayMarketMetrics: Sendable, Equatable, Codable {
    public let propertyID: String
    public let p50ADR: Decimal
    public let p75ADR: Decimal
    public let p90ADR: Decimal
    public let marketOccupancyRate: Double

    public init(
        propertyID: String,
        p50ADR: Decimal,
        p75ADR: Decimal,
        p90ADR: Decimal,
        marketOccupancyRate: Double
    ) {
        self.propertyID = propertyID
        self.p50ADR = p50ADR
        self.p75ADR = p75ADR
        self.p90ADR = p90ADR
        self.marketOccupancyRate = marketOccupancyRate
    }
}

/// Outcome of a simulated CapEx upgrade on rental cash flow and runway.
public struct RunwayProformaSimulation: Sendable, Equatable {
    public let capexBudget: Decimal
    public let targetADRDelta: Decimal
    public let expectedOccupancyDelta: Double
    public let monthlyIncrementalRevenue: Decimal
    public let paybackMonths: Double
    public let annualNetRunwayCashFlow: Decimal
    public let daysRunwayAdded: Int

    public init(
        capexBudget: Decimal,
        targetADRDelta: Decimal,
        expectedOccupancyDelta: Double,
        monthlyIncrementalRevenue: Decimal,
        paybackMonths: Double,
        annualNetRunwayCashFlow: Decimal,
        daysRunwayAdded: Int
    ) {
        self.capexBudget = capexBudget
        self.targetADRDelta = targetADRDelta
        self.expectedOccupancyDelta = expectedOccupancyDelta
        self.monthlyIncrementalRevenue = monthlyIncrementalRevenue
        self.paybackMonths = paybackMonths
        self.annualNetRunwayCashFlow = annualNetRunwayCashFlow
        self.daysRunwayAdded = daysRunwayAdded
    }
}

/// Steps of the first time onboarding wizard.
public enum RunwayOnboardingStep: Int, Sendable, Equatable {
    case apiKey = 1
    case properties = 2
    case budgetLink = 3
    case completed = 4
}
