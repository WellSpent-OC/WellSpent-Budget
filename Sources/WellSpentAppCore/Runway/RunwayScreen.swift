import Foundation
import Observation

/// The screen controller managing Runway property tracking, booking calendar,
/// and proforma simulations across Linux, macOS, and iOS.
@MainActor @Observable
public final class RunwayScreen {
    public private(set) var properties: [RunwayProperty] = []
    public private(set) var selectedPropertyID: String?
    public private(set) var bookingsByProperty: [String: [RunwayBooking]] = [:]
    public private(set) var marketMetricsByProperty: [String: RunwayMarketMetrics] = [:]

    public private(set) var isConfigured = false
    public var onboardingStep: RunwayOnboardingStep = .apiKey
    public var enteredApiKey = ""
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    public var capexBudget: Decimal = 15000 {
        didSet { recomputeSimulation() }
    }
    public var targetADRDelta: Decimal = 45 {
        didSet { recomputeSimulation() }
    }
    public private(set) var activeSimulation: RunwayProformaSimulation?

    public var householdDailyBurnRate: Decimal = 150 {
        didSet { recomputeSimulation() }
    }

    @ObservationIgnored private let service: PriceLabsService

    public init(service: PriceLabsService = PriceLabsMockService(), isConfigured: Bool = false) {
        self.service = service
        self.isConfigured = isConfigured
        if isConfigured {
            loadInitialData()
        }
    }

    public var selectedProperty: RunwayProperty? {
        if let id = selectedPropertyID {
            return properties.first { $0.id == id }
        }
        return properties.first
    }

    public var currentBookings: [RunwayBooking] {
        guard let id = selectedProperty?.id else { return [] }
        return bookingsByProperty[id] ?? []
    }

    public var currentMarketMetrics: RunwayMarketMetrics? {
        guard let id = selectedProperty?.id else { return nil }
        return marketMetricsByProperty[id]
    }

    public var portfolioGrossRevenueMTD: Decimal {
        bookingsByProperty.values.flatMap { $0 }
            .filter { $0.status == .booked }
            .reduce(0) { $0 + $1.grossPayout }
    }

    public var portfolioFixedDebtService: Decimal {
        properties.reduce(0) { $0 + $1.monthlyMortgagePITI }
    }

    public var portfolioNetOperatingIncomeMTD: Decimal {
        portfolioGrossRevenueMTD - portfolioFixedDebtService
    }

    public var portfolioRunwayDaysRemaining: Int {
        guard householdDailyBurnRate > 0 else { return 0 }
        let net = portfolioNetOperatingIncomeMTD
        if net <= 0 { return 0 }
        let netDouble = NSDecimalNumber(decimal: net).doubleValue
        let burnDouble = NSDecimalNumber(decimal: householdDailyBurnRate).doubleValue
        return Int((netDouble / burnDouble).rounded())
    }

    public func selectProperty(id: String) {
        selectedPropertyID = id
        recomputeSimulation()
    }

    public func updateProformaInputs(capex: Decimal, adrDelta: Decimal) {
        self.capexBudget = capex
        self.targetADRDelta = adrDelta
        recomputeSimulation()
    }

    public func loadDemoData() {
        self.isConfigured = true
        self.onboardingStep = .completed
        loadInitialData()
    }

    public func submitApiKey() {
        guard !enteredApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please enter a valid PriceLabs API token."
            return
        }
        errorMessage = nil
        onboardingStep = .properties
        loadInitialData()
    }

    public func advanceToBudgetLink() {
        onboardingStep = .budgetLink
    }

    public func completeOnboarding() {
        isConfigured = true
        onboardingStep = .completed
    }

    public func refresh() async {
        isBusy = true
        errorMessage = nil
        do {
            let fetched = try await service.fetchListings()
            self.properties = fetched
            if selectedPropertyID == nil || !properties.contains(where: { $0.id == selectedPropertyID }) {
                selectedPropertyID = properties.first?.id
            }

            for property in properties {
                let bookings = try await service.fetchBookings(listingID: property.id)
                self.bookingsByProperty[property.id] = bookings
                let metrics = try await service.fetchMarketData(listingID: property.id)
                self.marketMetricsByProperty[property.id] = metrics
            }
            recomputeSimulation()
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func loadInitialData() {
        self.properties = PriceLabsMockData.sampleProperties
        self.selectedPropertyID = PriceLabsMockData.ebbTideID
        for prop in properties {
            self.bookingsByProperty[prop.id] = PriceLabsMockData.sampleBookings(for: prop.id)
            self.marketMetricsByProperty[prop.id] = PriceLabsMockData.sampleMarketMetrics(for: prop.id)
        }
        recomputeSimulation()
    }

    private func recomputeSimulation() {
        guard let property = selectedProperty,
              let metrics = marketMetricsByProperty[property.id] else {
            activeSimulation = nil
            return
        }
        let bookings = bookingsByProperty[property.id] ?? []
        activeSimulation = RunwayProformaEngine.simulate(
            property: property,
            marketMetrics: metrics,
            currentBookings: bookings,
            capexBudget: capexBudget,
            targetADRDelta: targetADRDelta,
            householdDailyBurnRate: householdDailyBurnRate
        )
    }
}
