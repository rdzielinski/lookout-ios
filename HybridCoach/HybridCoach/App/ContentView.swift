import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                }

            CoachingView()
                .tabItem {
                    Label("Coach", systemImage: "brain.head.profile")
                }

            TripHistoryView()
                .tabItem {
                    Label("Trips", systemImage: "road.lanes")
                }

            ConnectionView()
                .tabItem {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
