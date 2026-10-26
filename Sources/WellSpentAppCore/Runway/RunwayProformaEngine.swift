import Foundation

/// Pure mathematical calculation engine for the Runway Proforma Simulator.
public enum RunwayProformaEngine {
    /// Simulates the impact of a capital expenditure upgrade on property cash flow.
    public static func simulate(
        property: RunwayProperty,
        marketMetrics: RunwayMarketMetrics,
        currentBookings: [RunwayBooking],
        capexBudget: Decimal,
        targetADRDelta: Decimal,
        householdDailyBurnRate: Decimal = 150
    ) -> RunwayProformaSimulation {
        let totalBookedNights = currentBookings
            .filter { $0.status == .booked }
            .reduce(0) { $0 + $1.nights }

        // Standard 30 day monthly baseline. If bookings sample is small, fallback to market occupancy.
        let estimatedMonthlyBookedNights: Double
        if totalBookedNights > 0 {
            estimatedMonthlyBookedNights = min(30.0, max(12.0, Double(totalBookedNights)))
        } else {
            estimatedMonthlyBookedNights = 30.0 * marketMetrics.marketOccupancyRate
        }

        // Expected occupancy lift: modest 2% lift if ADR increases moderately.
        let expectedOccupancyDelta = targetADRDelta > 0 ? 0.03 : 0.0

        let monthlyIncrementalRevenue = Decimal(estimatedMonthlyBookedNights) * targetADRDelta
        let annualNetIncremental = monthlyIncrementalRevenue * 12

        let paybackMonths: Double
        if monthlyIncrementalRevenue > 0 && capexBudget > 0 {
            let capexDouble = NSDecimalNumber(decimal: capexBudget).doubleValue
            let monthlyRevDouble = NSDecimalNumber(decimal: monthlyIncrementalRevenue).doubleValue
            paybackMonths = (capexDouble / monthlyRevDouble).rounded(toPlaces: 1)
        } else {
            paybackMonths = 0.0
        }

        let burnRate = householdDailyBurnRate > 0 ? householdDailyBurnRate : 150
        let burnRateDouble = NSDecimalNumber(decimal: burnRate).doubleValue
        let annualNetDouble = NSDecimalNumber(decimal: annualNetIncremental).doubleValue
        let daysRunway = burnRateDouble > 0 ? Int((annualNetDouble / burnRateDouble).rounded()) : 0

        return RunwayProformaSimulation(
            capexBudget: capexBudget,
            targetADRDelta: targetADRDelta,
            expectedOccupancyDelta: expectedOccupancyDelta,
            monthlyIncrementalRevenue: monthlyIncrementalRevenue,
            paybackMonths: paybackMonths,
            annualNetRunwayCashFlow: annualNetIncremental,
            daysRunwayAdded: max(0, daysRunway)
        )
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
