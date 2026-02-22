//
//  MockGlassesTestView.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/18/26.
//


#if DEBUG

import SwiftUI

#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

// MARK: - Mock Glasses Test View
/// Debug-only view for testing glasses integration without physical hardware.
/// Access via Settings → Developer → Test Mock Glasses
struct MockGlassesTestView: View {
    @EnvironmentObject var settings: SettingsManager
    @StateObject private var viewModel: MockGlassesTestViewModel
    @Environment(\.dismiss) var dismiss
    
    init() {
        self._viewModel = StateObject(wrappedValue: MockGlassesTestViewModel())
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // Status
                Section {
                    HStack {
                        Image(systemName: "eyeglasses")
                            .foregroundStyle(viewModel.isDevicePaired ? .green : .secondary)
                        Text("Mock Device")
                        Spacer()
                        Text(viewModel.isDevicePaired ? "Paired" : "Not Paired")
                            .foregroundStyle(viewModel.isDevicePaired ? .green : .secondary)
                    }
                    
                    if viewModel.isDevicePaired {
                        HStack {
                            Text("Power")
                            Spacer()
                            Text(viewModel.isPoweredOn ? "On" : "Off")
                                .foregroundStyle(viewModel.isPoweredOn ? .green : .red)
                        }
                        
                        HStack {
                            Text("Hinges")
                            Spacer()
                            Text(viewModel.isUnfolded ? "Open" : "Folded")
                                .foregroundStyle(viewModel.isUnfolded ? .green : .orange)
                        }
                    }
                } header: {
                    Text("Device Status")
                }
                
                // Pair / Unpair
                Section {
                    if !viewModel.isDevicePaired {
                        Button("Pair Mock Ray-Ban Meta") {
                            viewModel.pairDevice()
                        }
                    } else {
                        Button("Power On") {
                            viewModel.powerOn()
                        }
                        .disabled(viewModel.isPoweredOn)
                        
                        Button("Power Off") {
                            viewModel.powerOff()
                        }
                        .disabled(!viewModel.isPoweredOn)
                        
                        Button("Unfold Hinges (Wear)") {
                            viewModel.unfold()
                        }
                        .disabled(viewModel.isUnfolded)
                        
                        Button("Fold Hinges (Remove)") {
                            viewModel.fold()
                        }
                        .disabled(!viewModel.isUnfolded)
                        
                        Button("Unpair Device", role: .destructive) {
                            viewModel.unpairDevice()
                        }
                    }
                } header: {
                    Text("Device Controls")
                } footer: {
                    Text("Mock devices simulate real glasses behavior. Pair → Power On → Unfold to make the device available for streaming.")
                }
                
                // Camera Feed
                if viewModel.isDevicePaired {
                    Section {
                        Button("Load Test Video Feed") {
                            viewModel.loadTestVideo()
                        }
                        .disabled(viewModel.hasCameraFeed)
                        
                        Button("Load Test Capture Image") {
                            viewModel.loadTestImage()
                        }
                        .disabled(viewModel.hasCapturedImage)
                        
                        if viewModel.hasCameraFeed {
                            HStack {
                                Image(systemName: "video.fill")
                                    .foregroundStyle(.green)
                                Text("Video feed loaded")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        if viewModel.hasCapturedImage {
                            HStack {
                                Image(systemName: "photo.fill")
                                    .foregroundStyle(.green)
                                Text("Capture image loaded")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Camera Mock Data")
                    } footer: {
                        Text("Load a video file for streaming preview or an image for photo capture testing. Without mock data, the stream will show blank frames.")
                    }
                }
                
                // Test Actions
                if viewModel.isDevicePaired && viewModel.isPoweredOn {
                    Section {
                        Button("Simulate Voice Trigger") {
                            viewModel.simulateVoiceTrigger()
                        }
                        
                        Button("Simulate Photo Capture") {
                            viewModel.simulatePhotoCapture()
                        }

                        Button("Simulate Camera Button Press") {
                            viewModel.simulateCameraButton()
                        }
                    } header: {
                        Text("Simulate Actions")
                    } footer: {
                        Text("Test the glasses pipeline without actual voice or camera input. Voice Trigger simulates saying the trigger phrase. Photo Capture simulates a programmatic capture. Camera Button simulates pressing the hardware camera button. Make sure Glasses Mode is enabled in Settings.")
                    }
                }
                
                // Log
                if !viewModel.logMessages.isEmpty {
                    Section {
                        ForEach(viewModel.logMessages, id: \.self) { msg in
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Button("Clear Log") {
                            viewModel.logMessages.removeAll()
                        }
                    } header: {
                        Text("Debug Log")
                    }
                }
                
                // Instructions
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Setup Steps", systemImage: "list.number")
                            .font(.subheadline.weight(.semibold))
                        
                        Text("1. Tap \"Pair Mock Ray-Ban Meta\"")
                        Text("2. Tap \"Power On\" then \"Unfold Hinges\"")
                        Text("3. Go to Settings → enable Glasses Mode")
                        Text("4. Return here → \"Simulate Photo Capture\"")
                        Text("5. Lookout should process the image and speak results")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("How to Test")
                }
            }
            .navigationTitle("Mock Glasses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Mock Glasses Test ViewModel
@MainActor
class MockGlassesTestViewModel: ObservableObject {
    @Published var isDevicePaired = false
    @Published var isPoweredOn = false
    @Published var isUnfolded = false
    @Published var hasCameraFeed = false
    @Published var hasCapturedImage = false
    @Published var logMessages: [String] = []
    
    #if canImport(MWDATMockDevice)
    private var mockDevice: MockDevice?
    private let mockDeviceKit = MockDeviceKit.shared
    #endif
    
    init() {
        #if canImport(MWDATMockDevice)
        // Check if any mock devices already exist
        if let existing = mockDeviceKit.pairedDevices.first {
            mockDevice = existing
            isDevicePaired = true
            log("Found existing mock device: \(existing.deviceIdentifier)")
        }
        #endif
    }
    
    func pairDevice() {
        #if canImport(MWDATMockDevice)
        let device = mockDeviceKit.pairRaybanMeta()
        mockDevice = device
        isDevicePaired = true
        log("Paired mock Ray-Ban Meta: \(device.deviceIdentifier)")
        #else
        log("⚠️ MWDATMockDevice not available")
        #endif
    }
    
    func unpairDevice() {
        #if canImport(MWDATMockDevice)
        guard let device = mockDevice else { return }
        mockDeviceKit.unpairDevice(device)
        mockDevice = nil
        isDevicePaired = false
        isPoweredOn = false
        isUnfolded = false
        hasCameraFeed = false
        hasCapturedImage = false
        log("Unpaired mock device")
        #endif
    }
    
    func powerOn() {
        #if canImport(MWDATMockDevice)
        mockDevice?.powerOn()
        isPoweredOn = true
        log("Powered on")
        #endif
    }
    
    func powerOff() {
        #if canImport(MWDATMockDevice)
        mockDevice?.powerOff()
        isPoweredOn = false
        log("Powered off")
        #endif
    }
    
    func unfold() {
        #if canImport(MWDATMockDevice)
        if let glasses = mockDevice as? MockDisplaylessGlasses {
            glasses.unfold()
            isUnfolded = true
            log("Hinges unfolded (wearing)")
        }
        #endif
    }
    
    func fold() {
        #if canImport(MWDATMockDevice)
        if let glasses = mockDevice as? MockDisplaylessGlasses {
            glasses.fold()
            isUnfolded = false
            log("Hinges folded (removed)")
        }
        #endif
    }
    
    func loadTestVideo() {
        #if canImport(MWDATMockDevice)
        // Use a bundled test video if available, otherwise log instructions
        if let videoURL = Bundle.main.url(forResource: "test_glasses_feed", withExtension: "mp4") {
            if let cameraKit = (mockDevice as? MockDisplaylessGlasses)?.getCameraKit() {
                Task {
                    await cameraKit.setCameraFeed(fileURL: videoURL)
                    hasCameraFeed = true
                    log("Loaded test video feed")
                }
            }
        } else {
            log("⚠️ No test_glasses_feed.mp4 in bundle. Add a short video to your project to test streaming.")
            log("Tip: Record a 10-second video with your phone and add it to the Xcode project.")
        }
        #endif
    }
    
    func loadTestImage() {
        #if canImport(MWDATMockDevice)
        // Use a bundled test image if available
        if let imageURL = Bundle.main.url(forResource: "test_glasses_capture", withExtension: "jpg") {
            if let cameraKit = (mockDevice as? MockDisplaylessGlasses)?.getCameraKit() {
                Task {
                    await cameraKit.setCapturedImage(fileURL: imageURL)
                    hasCapturedImage = true
                    log("Loaded test capture image")
                }
            }
        } else {
            log("⚠️ No test_glasses_capture.jpg in bundle. Add a test photo to your Xcode project.")
            log("Tip: Any JPEG photo will work — Lookout will analyze it as if the glasses captured it.")
        }
        #endif
    }
    
    func simulateVoiceTrigger() {
        log("🎤 Simulating voice trigger: \"lookout\"")
        // Post a notification that GlassesService can pick up,
        // or just directly trigger the callback chain
        NotificationCenter.default.post(name: .mockGlassesVoiceTrigger, object: nil)
        log("Trigger fired — check if Lookout starts a capture")
    }
    
    func simulatePhotoCapture() {
        log("📸 Simulating photo capture from glasses")
        // Use test image from bundle or generate a placeholder
        let testImage: Data
        if let url = Bundle.main.url(forResource: "test_glasses_capture", withExtension: "jpg"),
           let data = try? Data(contentsOf: url) {
            testImage = data
            log("Using test_glasses_capture.jpg from bundle")
        } else if let placeholder = UIImage(systemName: "eyeglasses")?.withTintColor(.white, renderingMode: .alwaysOriginal),
                  let data = placeholder.pngData() {
            testImage = data
            log("⚠️ Using placeholder image (add test_glasses_capture.jpg for real testing)")
        } else {
            log("❌ Could not create test image")
            return
        }
        
        NotificationCenter.default.post(
            name: .mockGlassesPhotoCapture,
            object: nil,
            userInfo: ["imageData": testImage]
        )
        log("Photo data posted — check if Lookout processes it")
    }

    func simulateCameraButton() {
        log("📷 Simulating hardware camera button press")
        let testImage: Data
        if let url = Bundle.main.url(forResource: "test_glasses_capture", withExtension: "jpg"),
           let data = try? Data(contentsOf: url) {
            testImage = data
            log("Using test_glasses_capture.jpg from bundle")
        } else if let placeholder = UIImage(systemName: "camera.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal),
                  let data = placeholder.pngData() {
            testImage = data
            log("⚠️ Using placeholder image (add test_glasses_capture.jpg for real testing)")
        } else {
            log("❌ Could not create test image")
            return
        }

        NotificationCenter.default.post(
            name: .mockGlassesCameraButton,
            object: nil,
            userInfo: ["imageData": testImage]
        )
        log("Camera button event posted — check if Lookout processes it")
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logMessages.insert("[\(timestamp)] \(message)", at: 0)
        print("🕶️ Mock: \(message)")
    }
}

// MARK: - Notifications for Mock Actions
extension Notification.Name {
    static let mockGlassesVoiceTrigger = Notification.Name("mockGlassesVoiceTrigger")
    static let mockGlassesPhotoCapture = Notification.Name("mockGlassesPhotoCapture")
    static let mockGlassesCameraButton = Notification.Name("mockGlassesCameraButton")
}

#endif