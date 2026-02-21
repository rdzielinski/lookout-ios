import Foundation
import CoreLocation

// MARK: - Flight Tracking Skill
class FlightSkill: LookoutSkill {
    let category: SkillCategory = .flight
    let displayName: String = "Flight Tracker"
    var requiredAPIKey: String?
    
    private let adsbAPIKey: String
    
    init(adsbAPIKey: String = "") {
        self.adsbAPIKey = adsbAPIKey
    }
    
    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        guard let location = location else {
            return createFallbackResult(query: query, reason: "Enable location services for nearby flight data")
        }
        
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        
        // Try OpenSky first (free), fall back to ADS-B Exchange if it fails
        var flights: [NearbyAircraft] = []
        
        do {
            flights = try await fetchOpenSkyFlights(lat: lat, lon: lon)
        } catch {
            #if DEBUG
            print("✈️ OpenSky failed: \(error.localizedDescription). Trying ADSB Exchange...")
            #endif
            
            // Try ADS-B Exchange if we have a key
            if !adsbAPIKey.isEmpty {
                do {
                    flights = try await fetchADSBExchangeFlights(lat: lat, lon: lon)
                } catch {
                    #if DEBUG
                    print("✈️ ADSB Exchange also failed: \(error.localizedDescription)")
                    #endif
                }
            }
        }
        
        guard let bestMatch = flights.first else {
            return createFallbackResult(
                query: query,
                reason: "No aircraft found within 25nm. The plane may be outside tracking range, or the tracking API may be temporarily unavailable."
            )
        }
        
        var details: [SkillResult.DetailItem] = []
        
        if let callsign = bestMatch.callsign, !callsign.isEmpty {
            details.append(.init(label: "Callsign", value: callsign, iconName: "tag"))
        }
        if let origin = bestMatch.originCountry, !origin.isEmpty {
            details.append(.init(label: "Origin Country", value: origin, iconName: "flag"))
        }
        if let altitude = bestMatch.altitudeFt {
            details.append(.init(label: "Altitude", value: "\(altitude.formatted()) ft", iconName: "arrow.up"))
        }
        if let speed = bestMatch.speedKnots {
            details.append(.init(label: "Speed", value: "\(speed) knots", iconName: "speedometer"))
        }
        if let heading = bestMatch.heading {
            let direction = headingToCardinal(heading)
            details.append(.init(label: "Heading", value: "\(direction) (\(Int(heading))°)", iconName: "safari"))
        }
        if let distNM = bestMatch.distanceNM {
            details.append(.init(label: "Distance", value: String(format: "%.1f nm", distNM), iconName: "location"))
        }
        if let icao = bestMatch.icao24, !icao.isEmpty {
            details.append(.init(label: "ICAO24", value: icao.uppercased(), iconName: "number"))
        }
        
        let callsign = bestMatch.callsign ?? "Unknown"
        let subtitle: String
        if let origin = bestMatch.originCountry, let altFt = bestMatch.altitudeFt {
            subtitle = "\(origin) · \(altFt.formatted()) ft"
        } else {
            subtitle = bestMatch.originCountry ?? "Aircraft detected nearby"
        }
        
        // Deep link: try FlightRadar24 first, then FlightAware
        let frURL: URL?
        if callsign != "Unknown" {
            frURL = URL(string: "flightradar24://\(callsign)")
        } else {
            frURL = URL(string: "flightradar24://")
        }
        
        return SkillResult(
            category: .flight,
            title: "Flight \(callsign)",
            subtitle: subtitle,
            details: details,
            sourceApp: bestMatch.source,
            deepLinkURL: frURL
        )
    }
    
    // MARK: - OpenSky Network API (Free, no key required for anonymous)
    
    private func fetchOpenSkyFlights(lat: Double, lon: Double) async throws -> [NearbyAircraft] {
        // Bounding box: ~25nm ≈ ~0.4 degrees
        let delta = 0.4
        let lamin = lat - delta
        let lamax = lat + delta
        let lomin = lon - delta
        let lomax = lon + delta
        
        let urlString = "https://opensky-network.org/api/states/all?lamin=\(lamin)&lomin=\(lomin)&lamax=\(lamax)&lomax=\(lomax)"
        
        guard let url = URL(string: urlString) else {
            throw LookoutError.networkError("Invalid OpenSky URL")
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Lookout-iOS/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LookoutError.apiError("No HTTP response from OpenSky")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw LookoutError.apiError("OpenSky returned status \(httpResponse.statusCode)")
        }
        
        // Parse the response manually since state vectors are mixed-type arrays
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stateArrays = json["states"] as? [[Any]] else {
            #if DEBUG
            print("✈️ OpenSky: No states in response (may be empty area or rate limited)")
            #endif
            return []
        }
        
        var aircraft: [NearbyAircraft] = []
        
        for state in stateArrays {
            guard state.count >= 17 else { continue }
            
            // OpenSky state vector indices:
            // 0: icao24, 1: callsign, 2: origin_country
            // 5: longitude, 6: latitude, 7: baro_altitude
            // 8: on_ground, 9: velocity, 10: true_track
            // 13: geo_altitude
            
            let onGround = state[8] as? Bool ?? false
            guard !onGround else { continue }
            
            let icao24 = (state[0] as? String)?.trimmingCharacters(in: .whitespaces)
            let callsign = (state[1] as? String)?.trimmingCharacters(in: .whitespaces)
            let originCountry = state[2] as? String
            let acLon = asDouble(state[5])
            let acLat = asDouble(state[6])
            let geoAlt = asDouble(state[13]) ?? asDouble(state[7]) // geo_altitude, fallback to baro
            let velocity = asDouble(state[9])
            let trueTrack = asDouble(state[10])
            
            // Calculate distance from user
            var distanceNM: Double? = nil
            if let acLat = acLat, let acLon = acLon {
                let distMeters = CLLocation(latitude: lat, longitude: lon)
                    .distance(from: CLLocation(latitude: acLat, longitude: acLon))
                distanceNM = distMeters / 1852.0 // meters to nautical miles
            }
            
            let ac = NearbyAircraft(
                icao24: icao24,
                callsign: (callsign?.isEmpty ?? true) ? nil : callsign,
                originCountry: originCountry,
                altitudeFt: geoAlt != nil ? Int(geoAlt! * 3.28084) : nil,
                speedKnots: velocity != nil ? Int(velocity! * 1.94384) : nil,
                heading: trueTrack,
                distanceNM: distanceNM,
                source: "OpenSky Network"
            )
            aircraft.append(ac)
        }
        
        // Sort by distance (closest first)
        aircraft.sort { ($0.distanceNM ?? .greatestFiniteMagnitude) < ($1.distanceNM ?? .greatestFiniteMagnitude) }
        
        #if DEBUG
        print("✈️ OpenSky found \(aircraft.count) aircraft nearby")
        if let closest = aircraft.first {
            print("✈️ Closest: \(closest.callsign ?? closest.icao24 ?? "unknown") at \(String(format: "%.1f", closest.distanceNM ?? 0)) nm")
        }
        #endif
        
        return aircraft
    }
    
    // MARK: - ADS-B Exchange API (requires key)
    
    private func fetchADSBExchangeFlights(lat: Double, lon: Double) async throws -> [NearbyAircraft] {
        // RapidAPI ADS-B Exchange v2
        let urlString = "https://adsbexchange-com1.p.rapidapi.com/v2/lat/\(lat)/lon/\(lon)/dist/25/"
        
        guard let url = URL(string: urlString) else {
            throw LookoutError.networkError("Invalid ADSB URL")
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(adsbAPIKey, forHTTPHeaderField: "X-RapidAPI-Key")
        request.setValue("adsbexchange-com1.p.rapidapi.com", forHTTPHeaderField: "X-RapidAPI-Host")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LookoutError.apiError("ADSB Exchange API error")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acArray = json["ac"] as? [[String: Any]] else {
            return []
        }
        
        var aircraft: [NearbyAircraft] = []
        
        for ac in acArray {
            let flight = (ac["flight"] as? String)?.trimmingCharacters(in: .whitespaces)
            let altBaro = ac["alt_baro"] as? Int ?? (ac["alt_baro"] as? String).flatMap { Int($0) }
            let gs = ac["gs"] as? Double
            let track = ac["track"] as? Double
            let hex = ac["hex"] as? String
            let distNM = ac["dst"] as? Double
            
            let nearby = NearbyAircraft(
                icao24: hex,
                callsign: (flight?.isEmpty ?? true) ? nil : flight,
                originCountry: nil,
                altitudeFt: altBaro,
                speedKnots: gs != nil ? Int(gs!) : nil,
                heading: track,
                distanceNM: distNM,
                source: "ADS-B Exchange"
            )
            aircraft.append(nearby)
        }
        
        aircraft.sort { ($0.distanceNM ?? .greatestFiniteMagnitude) < ($1.distanceNM ?? .greatestFiniteMagnitude) }
        
        #if DEBUG
        print("✈️ ADSB Exchange found \(aircraft.count) aircraft nearby")
        #endif
        
        return aircraft
    }
    
    // MARK: - Helpers
    
    /// Safely extract a Double from a JSON value that could be Int, Double, or NSNull
    private func asDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
    
    private func headingToCardinal(_ heading: Double) -> String {
        let directions = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                          "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((heading + 11.25) / 22.5) % 16
        return directions[index]
    }
    
    private func createFallbackResult(query: String, reason: String) -> SkillResult {
        SkillResult(
            category: .flight,
            title: "Aircraft Detected",
            subtitle: query,
            details: [
                .init(label: "Note", value: reason, iconName: "info.circle"),
                .init(label: "Tip", value: "Open FlightRadar24 for live tracking", iconName: "arrow.up.right.square")
            ],
            sourceApp: "Lookout",
            deepLinkURL: URL(string: "flightradar24://")
        )
    }
}

// MARK: - Unified Aircraft Model

struct NearbyAircraft {
    let icao24: String?
    let callsign: String?
    let originCountry: String?
    let altitudeFt: Int?
    let speedKnots: Int?
    let heading: Double?
    let distanceNM: Double?
    let source: String
}
