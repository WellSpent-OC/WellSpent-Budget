import Foundation
import Testing
import WellSpentAppCore

@Suite("Runway Models and Engine")
struct RunwayTests {
    @Test func runwayModelsEncodeAndDecode() throws {
        let property = RunwayProperty(
            id: "test-prop-01",
            name: "187 Ebb Tide Cir",
            address: "187 Ebb Tide Cir",
            city: "Las Vegas",
            state: "NV",
            monthlyMortgagePITI: 3650
        )
        let data = try JSONEncoder().encode(property)
        let decoded = try JSONDecoder().decode(RunwayProperty.self, from: data)
        #expect(decoded.id == property.id)
        #expect(decoded.monthlyMortgagePITI == 3650)
        #expect(decoded.city == "Las Vegas")
    }

    @Test func priceLabsMockDataProvidesLasVegasProperties() async throws {
        let mockService = PriceLabsMockService()
        let listings = try await mockService.fetchListings()
        #expect(listings.count == 2)
        #expect(listings.contains { $0.id == PriceLabsMockData.ebbTideID })
        #expect(listings.contains { $0.id == PriceLabsMockData.radwickID })

        let ebbBookings = try await mockService.fetchBookings(listingID: PriceLabsMockData.ebbTideID)
        #expect(!ebbBookings.isEmpty)
        #expect(ebbBookings.contains { $0.channel == .airbnb })

        let radMetrics = try await mockService.fetchMarketData(listingID: PriceLabsMockData.radwickID)
        #expect(radMetrics.p75ADR > radMetrics.p50ADR)
        #expect(radMetrics.marketOccupancyRate > 0.5)
    }

    @Test func priceLabsClientRequiresNonEmptyApiKey() async {
        let clientWithEmptyKey = PriceLabsClient(apiKey: "   ")
        await #expect(throws: PriceLabsError.invalidApiKey) {
            _ = try await clientWithEmptyKey.fetchListings()
        }

        let clientWithKey = PriceLabsClient(apiKey: "valid-key-xyz")
        do {
            let listings = try await clientWithKey.fetchListings()
            #expect(!listings.isEmpty)
        } catch {
            Issue.record("Unexpected error with valid key: \(error)")
        }
    }

    @Test func proformaEngineCalculatesPaybackAndRunway() {
        let property = RunwayProperty(
            id: "prop-01",
            name: "187 Ebb Tide Cir",
            address: "187 Ebb Tide Cir",
            city: "Las Vegas",
            state: "NV",
            monthlyMortgagePITI: 3650
        )
        let metrics = RunwayMarketMetrics(
            propertyID: "prop-01",
            p50ADR: 340,
            p75ADR: 440,
            p90ADR: 560,
            marketOccupancyRate: 0.70
        )
        let bookings = [
            RunwayBooking(
                id: "b-01",
                propertyID: "prop-01",
                checkIn: Date(),
                checkOut: Date().addingTimeInterval(86400 * 18),
                nights: 18,
                status: .booked,
                channel: .airbnb,
                nightlyRateADR: 350
            )
        ]

        let simulation = RunwayProformaEngine.simulate(
            property: property,
            marketMetrics: metrics,
            currentBookings: bookings,
            capexBudget: 15000,
            targetADRDelta: 45,
            householdDailyBurnRate: 150
        )

        #expect(simulation.monthlyIncrementalRevenue == Decimal(18 * 45))
        #expect(simulation.paybackMonths > 0)
        #expect(simulation.daysRunwayAdded > 0)
        #expect(simulation.annualNetRunwayCashFlow > 0)
    }

    @Test func proformaEngineHandlesZeroCapex() {
        let property = PriceLabsMockData.sampleProperties[0]
        let metrics = PriceLabsMockData.sampleMarketMetrics(for: property.id)
        let bookings = PriceLabsMockData.sampleBookings(for: property.id)

        let simulation = RunwayProformaEngine.simulate(
            property: property,
            marketMetrics: metrics,
            currentBookings: bookings,
            capexBudget: 0,
            targetADRDelta: 40,
            householdDailyBurnRate: 150
        )

        #expect(simulation.paybackMonths == 0)
        #expect(simulation.monthlyIncrementalRevenue > 0)
    }

    @Test @MainActor func runwayScreenManagesOnboardingAndState() async {
        let screen = RunwayScreen(service: PriceLabsMockService(), isConfigured: false)
        #expect(!screen.isConfigured)
        #expect(screen.onboardingStep == .apiKey)

        screen.enteredApiKey = ""
        screen.submitApiKey()
        #expect(screen.errorMessage != nil)
        #expect(screen.onboardingStep == .apiKey)

        screen.enteredApiKey = "pl-key-999"
        screen.submitApiKey()
        #expect(screen.errorMessage == nil)
        #expect(screen.onboardingStep == .properties)
        #expect(!screen.properties.isEmpty)

        screen.advanceToBudgetLink()
        #expect(screen.onboardingStep == .budgetLink)

        screen.completeOnboarding()
        #expect(screen.isConfigured)
        #expect(screen.onboardingStep == .completed)

        #expect(screen.portfolioGrossRevenueMTD > 0)
        #expect(screen.portfolioFixedDebtService > 0)

        let initialSelected = screen.selectedPropertyID
        #expect(initialSelected != nil)

        screen.selectProperty(id: PriceLabsMockData.radwickID)
        #expect(screen.selectedPropertyID == PriceLabsMockData.radwickID)
        #expect(screen.selectedProperty?.name == "548 Radwick Dr")
        #expect(screen.activeSimulation != nil)

        screen.updateProformaInputs(capex: 20000, adrDelta: 60)
        #expect(screen.capexBudget == 20000)
        #expect(screen.targetADRDelta == 60)

        await screen.refresh()
        #expect(!screen.isBusy)
        #expect(screen.errorMessage == nil)
    }

    @Test @MainActor func runwayScreenDemoDataWorksImmediately() {
        let screen = RunwayScreen(service: PriceLabsMockService(), isConfigured: false)
        screen.loadDemoData()
        #expect(screen.isConfigured)
        #expect(screen.onboardingStep == .completed)
        #expect(screen.properties.count == 2)
        #expect(screen.activeSimulation != nil)
        #expect(screen.portfolioRunwayDaysRemaining >= 0)
    }
}
