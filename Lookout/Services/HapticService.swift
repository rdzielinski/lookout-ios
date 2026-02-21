//
//  HapticService.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/13/26.
//


import UIKit

// MARK: - Haptic Service
class HapticService {
    
    static let shared = HapticService()
    
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()
    
    private init() {
        impactLight.prepare()
        impactMedium.prepare()
        notification.prepare()
    }
    
    func capturePressed() {
        impactMedium.impactOccurred()
        impactMedium.prepare()
    }
    
    func categorized() {
        impactLight.impactOccurred(intensity: 0.6)
        impactLight.prepare()
    }
    
    func resultReady() {
        notification.notificationOccurred(.success)
        notification.prepare()
    }
    
    func error() {
        notification.notificationOccurred(.error)
        notification.prepare()
    }
    
    func cameraFlipped() {
        impactLight.impactOccurred(intensity: 0.5)
        impactLight.prepare()
    }
    
    func recordingStarted() {
        impactMedium.impactOccurred(intensity: 0.7)
        impactMedium.prepare()
    }
    
    func recordingSent() {
        impactLight.impactOccurred(intensity: 0.5)
        impactLight.prepare()
    }
    
    func followUpReady() {
        impactLight.impactOccurred(intensity: 0.4)
        impactLight.prepare()
    }
    
    func toggle() {
        selection.selectionChanged()
        selection.prepare()
    }
    
    func interrupted() {
        impactHeavy.impactOccurred(intensity: 0.5)
        impactHeavy.prepare()
    }
    
    func barcodeDetected() {
        notification.notificationOccurred(.success)
        notification.prepare()
    }
}