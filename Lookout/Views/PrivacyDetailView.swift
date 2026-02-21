//
//  PrivacyDetailView.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/14/26.
//


import SwiftUI

struct PrivacyDetailView: View {
    var body: some View {
        List {
            // Overview
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Your data, your device", systemImage: "lock.shield.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)
                    
                    Text("Lookout is designed with a local-first approach. There are no Lookout servers, no user accounts, no analytics, and no ads. All personal data is stored in your device's app sandbox and never leaves without your explicit action.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            // On-device storage
            Section {
                dataRow(icon: "person.crop.circle.fill", color: .blue,
                        title: "Face Recognition Data",
                        detail: "Perceptual hashes and embeddings from Apple's Vision framework. Raw photos are not stored — only mathematical representations used for matching.")
                
                dataRow(icon: "pawprint.fill", color: .orange,
                        title: "Pet Memory",
                        detail: "Name, species, and a text description of visual features. No photos of your pets are saved.")
                
                dataRow(icon: "mappin.circle.fill", color: .red,
                        title: "Saved Places",
                        detail: "GPS coordinates and names you assign. Used only to provide context when you scan near a known location.")
                
                dataRow(icon: "cart.fill", color: .teal,
                        title: "Product History",
                        detail: "Names, brands, and sizes of products you've scanned. Used to recognize your preferences over time.")
                
                dataRow(icon: "person.text.rectangle.fill", color: .purple,
                        title: "About You Context",
                        detail: "The personal context you write in Settings. Included in AI prompts to personalize responses. Only you can see or edit it.")
                
                dataRow(icon: "key.fill", color: .yellow,
                        title: "API Keys",
                        detail: "Stored in iOS App Storage (UserDefaults) on your device. Sent only to their respective services (Anthropic, OpenAI, ElevenLabs) when making API calls.")
                
                dataRow(icon: "chart.bar.fill", color: .green,
                        title: "Scan Statistics",
                        detail: "Category counts, recent scan titles, and usage patterns. Never leaves your device.")
            } header: {
                Label("Stored On Your Device", systemImage: "iphone")
            } footer: {
                Text("All of the above is stored in your app's local documents directory. Deleting the app removes everything. You can also reset all data in Settings → Data Management.")
            }
            
            // Sent externally
            Section {
                dataRow(icon: "camera.fill", color: .orange,
                        title: "Photos You Scan",
                        detail: "Sent as a JPEG to your chosen AI provider (Claude by Anthropic, or GPT-4o by OpenAI) for visual analysis. Sent only when you tap the Scan button. Not stored by Lookout after the session ends.")
                
                dataRow(icon: "mic.fill", color: .orange,
                        title: "Follow-Up Questions",
                        detail: "Voice is converted to text on-device using Apple Speech Recognition. The text is then sent to your AI provider as part of the conversation. Audio is never sent to external servers.")
                
                dataRow(icon: "barcode", color: .orange,
                        title: "Barcode Lookups",
                        detail: "UPC codes are sent to UPCitemdb.com (free, public) and product names may be searched on Google Shopping for price comparison. No personal data is included in these requests.")
                
                dataRow(icon: "music.note", color: .orange,
                        title: "Music Identification",
                        detail: "Audio clips are processed by Apple's ShazamKit framework, which sends audio fingerprints to Apple's servers for matching. Standard Apple privacy policies apply.")
                
                dataRow(icon: "speaker.wave.2.fill", color: .orange,
                        title: "ElevenLabs Voice (if enabled)",
                        detail: "The AI's response text is sent to ElevenLabs for voice synthesis. No personal data beyond the response text is included. Optional — Apple on-device voices are the default.")
                
                dataRow(icon: "airplane", color: .orange,
                        title: "Flight Tracking",
                        detail: "Your approximate GPS coordinates are sent to OpenSky Network to find nearby aircraft. Used only when analyzing a photo that contains a plane.")
                
                dataRow(icon: "leaf", color: .orange,
                        title: "Plant & Animal ID",
                        detail: "Species names identified by AI are looked up on iNaturalist's public API. No photos or personal data are sent.")
                
                dataRow(icon: "building.2", color: .orange,
                        title: "Landmark Lookups",
                        detail: "Landmark names are searched on Wikipedia and optionally Google Places (if you provide a key). No photos are sent to these services.")
            } header: {
                Label("Sent When You Scan", systemImage: "arrow.up.circle")
            } footer: {
                Text("External requests happen only when you initiate a scan or follow-up. Nothing is sent automatically or in the background. Each service's own privacy policy applies to data you send them.")
            }
            
            // What we never do
            Section {
                neverRow("Sell or share data with third parties")
                neverRow("Collect analytics or usage data")
                neverRow("Run background network requests")
                neverRow("Create user accounts or profiles")
                neverRow("Display advertisements")
                neverRow("Track your location in the background")
                neverRow("Access your photo library, contacts, or other apps")
                neverRow("Store photos after your session ends")
            } header: {
                Label("We Never", systemImage: "xmark.shield.fill")
            }
            
            // AI provider notice
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When you scan a photo, it's sent to the AI provider you've chosen in Settings (Claude by Anthropic or GPT-4o by OpenAI). These companies have their own data handling policies.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("Anthropic's API does not use your inputs to train models by default. OpenAI's API also does not use API inputs for training. However, Lookout has no control over these providers' policies — please review their terms if this matters to you.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    Link(destination: URL(string: "https://www.anthropic.com/privacy")!) {
                        Label("Anthropic Privacy Policy", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                    
                    Link(destination: URL(string: "https://openai.com/policies/api-data-usage-policies")!) {
                        Label("OpenAI API Data Policy", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("About Your AI Provider")
            }
            
            // Your control
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You're in full control. You can:")
                        .font(.subheadline)
                    
                    controlRow("Delete individual faces, pets, or places by swiping left")
                    controlRow("Reset all memory in Settings → Data Management")
                    controlRow("Turn off Face Recognition or Place Memory at any time")
                    controlRow("Switch AI providers or remove API keys")
                    controlRow("Delete the app to remove all data permanently")
                }
                .padding(.vertical, 4)
            } header: {
                Text("Your Control")
            }
        }
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Helpers
    
    private func dataRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 24)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func neverRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
                .frame(width: 20)
            
            Text(text)
                .font(.subheadline)
        }
    }
    
    private func controlRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
                .frame(width: 16)
                .padding(.top, 2)
            
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}