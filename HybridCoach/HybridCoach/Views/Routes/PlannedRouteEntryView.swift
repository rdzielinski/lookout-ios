import SwiftUI

/// Input form for planning a new route from start/end addresses.
struct PlannedRouteEntryView: View {
    @Environment(PlannedRouteStore.self) var store
    @Environment(\.dismiss) var dismiss

    @State private var routeName = ""
    @State private var startAddress = ""
    @State private var endAddress = ""
    @State private var includeTraffic = false
    @State private var departureDate = Date()

    @State private var isPlanning = false
    @State private var errorMessage: String?
    @State private var plannedRoute: PlannedRoute?
    @State private var showAnalysis = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Route Name") {
                    TextField("Optional name (e.g. Work Commute)", text: $routeName)
                }

                Section("Addresses") {
                    TextField("Start address", text: $startAddress)
                        .textContentType(.fullStreetAddress)
                        .autocorrectionDisabled()
                    TextField("End address", text: $endAddress)
                        .textContentType(.fullStreetAddress)
                        .autocorrectionDisabled()
                }

                Section("Traffic") {
                    Toggle("Include traffic estimate", isOn: $includeTraffic)
                    if includeTraffic {
                        DatePicker("Departure", selection: $departureDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await planRoute() }
                    } label: {
                        HStack {
                            Spacer()
                            if isPlanning {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Planning Route…")
                            } else {
                                Image(systemName: "map")
                                Text("Plan Route")
                            }
                            Spacer()
                        }
                        .fontWeight(.semibold)
                    }
                    .disabled(startAddress.isEmpty || endAddress.isEmpty || isPlanning)
                }
            }
            .navigationTitle("Plan a Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showAnalysis) {
                if let route = plannedRoute {
                    PlannedRouteAnalysisView(route: route)
                }
            }
        }
    }

    // MARK: - Plan Route

    private func planRoute() async {
        errorMessage = nil
        isPlanning = true

        do {
            var route = try await RoutePlanningService.planRoute(
                from: startAddress,
                to: endAddress,
                departureDate: includeTraffic ? departureDate : nil
            )

            if !routeName.isEmpty {
                route.name = routeName
            }

            store.addRoute(route)
            plannedRoute = route
            showAnalysis = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isPlanning = false
    }
}
