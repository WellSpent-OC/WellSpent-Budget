import Foundation
import SwiftCrossUI
import WellSpentAppCore

/// Native presentation of Runway on Linux with SwiftCrossUI and GTK 4.
/// The shared RunwayScreen owns data models, PriceLabs querying, and proforma math.
struct RunwayView: View {
    let screen: RunwayScreen
    var openAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let error = screen.errorMessage {
                Note(error, warning: true)
                    .padding(12)
            }

            if screen.isConfigured {
                dashboard
            } else {
                onboarding
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Runway")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Palette.ink)
                Text("Short term rentals: PriceLabs revenue, break-even runway, and proforma lever.")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.muted)
            }
            Spacer()

            if screen.isConfigured {
                HStack(spacing: 8) {
                    metricBadge(label: "MTD Rev", value: "$\(screen.portfolioGrossRevenueMTD)")
                    metricBadge(label: "Debt", value: "$\(screen.portfolioFixedDebtService)")
                    metricBadge(label: "Net", value: "$\(screen.portfolioNetOperatingIncomeMTD)")
                    metricBadge(label: "Runway", value: "+\(screen.portfolioRunwayDaysRemaining)d")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Palette.sidebar)
    }

    private func metricBadge(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Palette.muted)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Palette.ink)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface))
    }

    // MARK: - Onboarding Wizard

    private var onboarding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch screen.onboardingStep {
                case .apiKey:
                    onboardingApiKeyStep
                case .properties:
                    onboardingPropertiesStep
                case .budgetLink:
                    onboardingBudgetLinkStep
                case .completed:
                    EmptyView()
                }
            }
            .padding(24)
            .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var onboardingApiKeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 1: Connect to PriceLabs")
                .font(.system(size: 16, weight: .semibold))
            Text("Runway reads your dynamic ADR pricing and booking reservations directly from PriceLabs.")
                .font(.system(size: 13))
                .foregroundColor(Palette.muted)

            HStack(spacing: 8) {
                TextField(
                    "PriceLabs Customer API Key",
                    text: Binding(get: { screen.enteredApiKey }, set: { screen.enteredApiKey = $0 })
                )
                Button("Connect") {
                    screen.submitApiKey()
                }
            }
            .padding(.top, 4)

            Divider().padding(.vertical, 8)

            Text("Or start immediately with offline sample data:")
                .font(.system(size: 12))
                .foregroundColor(Palette.muted)

            Button("Use Las Vegas Sample Properties (Offline)") {
                screen.loadDemoData()
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.sidebar))
    }

    private var onboardingPropertiesStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 2: Confirm Properties")
                .font(.system(size: 16, weight: .semibold))
            Text("The following listings were discovered in your PriceLabs account:")
                .font(.system(size: 13))
                .foregroundColor(Palette.muted)

            ForEach(screen.properties) { property in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(property.name)
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(property.address), \(property.city) \(property.state)")
                            .font(.system(size: 12))
                            .foregroundColor(Palette.muted)
                    }
                    Spacer()
                    Text("PITI: $\(property.monthlyMortgagePITI)/mo")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface))
            }

            Button("Continue to Budget Link") {
                screen.advanceToBudgetLink()
            }
            .padding(.top, 8)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.sidebar))
    }

    private var onboardingBudgetLinkStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 3: Link to Household Budget")
                .font(.system(size: 16, weight: .semibold))
            Text("Connect rental net cash flow to your daily household burn rate ($150/day) to compute runway days.")
                .font(.system(size: 13))
                .foregroundColor(Palette.muted)

            Button("Finish Setup & Launch Runway") {
                screen.completeOnboarding()
            }
            .padding(.top, 8)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.sidebar))
    }

    // MARK: - Dashboard Layout (Three Columns)

    private var dashboard: some View {
        HStack(spacing: 0) {
            propertiesColumn
                .frame(width: 250)
            Divider()
            calendarColumn
                .frame(maxWidth: .infinity)
            Divider()
            proformaColumn
                .frame(width: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Column 1: Properties List

    private var propertiesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROPERTIES")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Palette.muted)
                Spacer()
                Button("↻") {
                    Task { await screen.refresh() }
                }
                .help("Refresh from PriceLabs")
            }
            .padding(12)
            .background(Palette.sidebar)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(screen.properties) { property in
                        let isSelected = property.id == screen.selectedProperty?.id
                        Button(action: { screen.selectProperty(id: property.id) }) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(property.name)
                                        .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                        .foregroundColor(isSelected ? Palette.accent : Palette.ink)
                                    Spacer()
                                }
                                Text("\(property.city), \(property.state)")
                                    .font(.system(size: 11))
                                    .foregroundColor(Palette.muted)
                                HStack {
                                    Text("Debt: $\(property.monthlyMortgagePITI)/mo")
                                        .font(.system(size: 11))
                                        .foregroundColor(Palette.muted)
                                    Spacer()
                                    Text("Clean: $\(property.cleaningFeePassThrough)")
                                        .font(.system(size: 11))
                                        .foregroundColor(Palette.muted)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color(PaletteValues.accent).opacity(0.12) : Palette.sidebar))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
        .background(Palette.surface)
    }

    // MARK: - Column 2: Booking Horizon & Calendar

    private var calendarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let property = screen.selectedProperty {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(property.name)
                            .font(.system(size: 15, weight: .semibold))
                        Text("30-Day Booking Track & PriceLabs Dynamic Rates")
                            .font(.system(size: 11))
                            .foregroundColor(Palette.muted)
                    }
                    Spacer()
                    if let metrics = screen.currentMarketMetrics {
                        HStack(spacing: 8) {
                            Text("Market p50: $\(metrics.p50ADR)")
                                .font(.system(size: 11))
                                .foregroundColor(Palette.muted)
                            Text("75th %: $\(metrics.p75ADR)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Palette.accent)
                        }
                    }
                }
                .padding(12)
                .background(Palette.sidebar)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(screen.currentBookings) { booking in
                            bookingRow(booking)
                        }
                    }
                    .padding(12)
                }
            } else {
                Text("Select a property to view bookings.")
                    .font(.system(size: 13))
                    .foregroundColor(Palette.muted)
                    .padding(20)
            }
        }
        .background(Palette.surface)
    }

    private func bookingRow(_ booking: RunwayBooking) -> some View {
        HStack(spacing: 12) {
            statusBadge(for: booking.status)
                .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(booking.nights) nights • \(booking.guestName.isEmpty ? booking.channel.rawValue : booking.guestName)")
                    .font(.system(size: 13, weight: .medium))
                Text(booking.channel.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("$\(booking.nightlyRateADR)/nt")
                    .font(.system(size: 13, weight: .semibold))
                if booking.grossPayout > 0 {
                    Text("Total: $\(booking.grossPayout)")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.muted)
                }
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.sidebar))
    }

    private func statusBadge(for status: RunwayBookingStatus) -> some View {
        switch status {
        case .booked:
            return Text("Booked")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Palette.accent)
        case .unbooked:
            return Text("Open Gap")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Palette.warning)
        case .blocked:
            return Text("Blocked")
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
        }
    }

    // MARK: - Column 3: Proforma Simulator ("The Lever")

    private var proformaColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PROFORMA SIMULATOR")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Palette.muted)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.sidebar)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("The Lever: CapEx to ADR")
                        .font(.system(size: 14, weight: .semibold))

                    Text("Simulate how a property investment lifts ADR, speeds up payback, and extends household runway.")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.muted)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("CapEx Investment: $\(screen.capexBudget)")
                            .font(.system(size: 12, weight: .medium))
                        HStack(spacing: 6) {
                            Button("$5k") { screen.updateProformaInputs(capex: 5000, adrDelta: screen.targetADRDelta) }
                            Button("$15k") { screen.updateProformaInputs(capex: 15000, adrDelta: screen.targetADRDelta) }
                            Button("$30k") { screen.updateProformaInputs(capex: 30000, adrDelta: screen.targetADRDelta) }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Target ADR Boost: +$\(screen.targetADRDelta)/nt")
                            .font(.system(size: 12, weight: .medium))
                        HStack(spacing: 6) {
                            Button("+$25") { screen.updateProformaInputs(capex: screen.capexBudget, adrDelta: 25) }
                            Button("+$45") { screen.updateProformaInputs(capex: screen.capexBudget, adrDelta: 45) }
                            Button("+$75") { screen.updateProformaInputs(capex: screen.capexBudget, adrDelta: 75) }
                        }
                    }

                    Divider()

                    if let sim = screen.activeSimulation {
                        simulationCard(sim)
                    }
                }
                .padding(14)
            }
        }
        .background(Palette.surface)
    }

    private func simulationCard(_ sim: RunwayProformaSimulation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROJECTED RETURNS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Palette.muted)

            resultRow(label: "Monthly Lift", value: "+$\(sim.monthlyIncrementalRevenue)/mo")
            resultRow(label: "Payback Period", value: "\(sim.paybackMonths) months")
            resultRow(label: "Annual Net", value: "+$\(sim.annualNetRunwayCashFlow)")

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RUNWAY EXTENSION")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Palette.muted)
                    Text("+\(sim.daysRunwayAdded) days/yr")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Palette.accent)
                }
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(PaletteValues.accent).opacity(0.12)))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.sidebar))
    }

    private func resultRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Palette.muted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.ink)
        }
    }
}
