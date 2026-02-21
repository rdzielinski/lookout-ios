//
//  PlaceSignalType.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/18/26.
//


import Foundation

// MARK: - Place Signal Type
enum PlaceSignalType: String, Codable {
    case retailArea = "retail"
    case musicVenue = "music_venue"
    case outdoors = "outdoors"
    case residential = "residential"
    case office = "office"
    case unknown = "unknown"
}

// MARK: - Scan Environment Signals
// Gathered before each scan to provide context about WHERE the user is scanning
struct ScanEnvironmentSignals {
    let ambientDecibels: Double?   // Ambient noise level (loud = maybe concert)
    let placeType: PlaceSignalType // What kind of place the user is at
    let placeEvidence: String?     // Why we think they're at this type of place
}