import Foundation
import CoreLocation

// MARK: - Flight Tracking Skill
class FlightSkill: LookoutSkill {
    let category: SkillCategory = .flight
    let displayName: String = "Flight Tracker"
    var requiredAPIKey: String?

    private let fr24APIKey: String
    private let adsbAPIKey: String

    init(fr24APIKey: String = "", adsbAPIKey: String = "") {
        self.fr24APIKey = fr24APIKey
        self.adsbAPIKey = adsbAPIKey
    }

    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        guard let location = location else {
            return createFallbackResult(query: query, reason: "Enable location services for nearby flight data")
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        // Priority: FR24 (richest data) → OpenSky (free) → ADS-B Exchange (paid backup)
        var flights: [NearbyAircraft] = []

        // 1. Try FlightRadar24 first (best data)
        if !fr24APIKey.isEmpty {
            do {
                flights = try await fetchFlightRadar24Flights(lat: lat, lon: lon)
            } catch {
                #if DEBUG
                print("✈️ FlightRadar24 failed: \(error.localizedDescription). Trying OpenSky...")
                #endif
            }
        }

        // 2. Fall back to OpenSky (free, no key required)
        if flights.isEmpty {
            do {
                flights = try await fetchOpenSkyFlights(lat: lat, lon: lon)
            } catch {
                #if DEBUG
                print("✈️ OpenSky failed: \(error.localizedDescription). Trying ADSB Exchange...")
                #endif
            }
        }

        // 3. Last resort: ADS-B Exchange
        if flights.isEmpty && !adsbAPIKey.isEmpty {
            do {
                flights = try await fetchADSBExchangeFlights(lat: lat, lon: lon)
            } catch {
                #if DEBUG
                print("✈️ ADSB Exchange also failed: \(error.localizedDescription)")
                #endif
            }
        }

        guard let bestMatch = flights.first else {
            return createFallbackResult(
                query: query,
                reason: "No aircraft found within 25nm. The plane may be outside tracking range, or the tracking API may be temporarily unavailable."
            )
        }

        return buildResult(from: bestMatch)
    }

    // MARK: - Build Result

    private func buildResult(from aircraft: NearbyAircraft) -> SkillResult {
        var details: [SkillResult.DetailItem] = []

        // Flight number or callsign
        if let flightNumber = aircraft.flightNumber, !flightNumber.isEmpty {
            details.append(.init(label: "Flight", value: flightNumber, iconName: "tag"))
        } else if let callsign = aircraft.callsign, !callsign.isEmpty {
            details.append(.init(label: "Callsign", value: callsign, iconName: "tag"))
        }

        // Airline
        if let airline = aircraft.airline, !airline.isEmpty {
            details.append(.init(label: "Airline", value: airline, iconName: "airplane.circle"))
        }

        // Route
        if let origin = aircraft.origin, let destination = aircraft.destination {
            details.append(.init(label: "Route", value: "\(origin) → \(destination)", iconName: "arrow.right"))
        }

        // Aircraft type + registration
        if let aircraftType = aircraft.aircraftType, !aircraftType.isEmpty {
            let typeStr = aircraft.registration != nil ? "\(aircraftType) (\(aircraft.registration!))" : aircraftType
            details.append(.init(label: "Aircraft", value: typeStr, iconName: "airplane"))
        } else if let registration = aircraft.registration, !registration.isEmpty {
            details.append(.init(label: "Registration", value: registration, iconName: "airplane"))
        }

        // Origin country (mainly from OpenSky)
        if let origin = aircraft.originCountry, !origin.isEmpty, aircraft.airline == nil {
            details.append(.init(label: "Origin Country", value: origin, iconName: "flag"))
        }

        if let altitude = aircraft.altitudeFt {
            details.append(.init(label: "Altitude", value: "\(altitude.formatted()) ft", iconName: "arrow.up"))
        }
        if let speed = aircraft.speedKnots {
            details.append(.init(label: "Speed", value: "\(speed) knots", iconName: "speedometer"))
        }
        if let heading = aircraft.heading {
            let direction = headingToCardinal(heading)
            details.append(.init(label: "Heading", value: "\(direction) (\(Int(heading))°)", iconName: "safari"))
        }
        if let distNM = aircraft.distanceNM {
            details.append(.init(label: "Distance", value: String(format: "%.1f nm", distNM), iconName: "location"))
        }
        if let icao = aircraft.icao24, !icao.isEmpty {
            details.append(.init(label: "ICAO24", value: icao.uppercased(), iconName: "number"))
        }

        // Build title: prefer "UA456" or "Flight UA456", fall back to callsign
        let title: String
        if let fn = aircraft.flightNumber, !fn.isEmpty {
            title = "Flight \(fn)"
        } else if let cs = aircraft.callsign, !cs.isEmpty {
            title = "Flight \(cs)"
        } else {
            title = "Aircraft Detected"
        }

        // Build subtitle
        let subtitle: String
        if let airline = aircraft.airline, let origin = aircraft.origin, let dest = aircraft.destination {
            subtitle = "\(airline) · \(origin) → \(dest)"
        } else if let airline = aircraft.airline, let altFt = aircraft.altitudeFt {
            subtitle = "\(airline) · \(altFt.formatted()) ft"
        } else if let origin = aircraft.originCountry, let altFt = aircraft.altitudeFt {
            subtitle = "\(origin) · \(altFt.formatted()) ft"
        } else {
            subtitle = aircraft.originCountry ?? "Aircraft detected nearby"
        }

        // Deep link to FlightRadar24
        let callsign = aircraft.callsign ?? aircraft.flightNumber
        let frURL: URL?
        if let cs = callsign, !cs.isEmpty {
            frURL = URL(string: "flightradar24://\(cs)")
        } else {
            frURL = URL(string: "flightradar24://")
        }

        return SkillResult(
            category: .flight,
            title: title,
            subtitle: subtitle,
            details: details,
            sourceApp: aircraft.source,
            deepLinkURL: frURL
        )
    }

    // MARK: - FlightRadar24 API (Official, richest data)

    private func fetchFlightRadar24Flights(lat: Double, lon: Double) async throws -> [NearbyAircraft] {
        let delta = 0.4
        let north = lat + delta
        let south = lat - delta
        let west = lon - delta
        let east = lon + delta

        let urlString = "https://fr24api.flightradar24.com/api/live/flight-positions/full?bounds=\(north),\(south),\(west),\(east)"

        guard let url = URL(string: urlString) else {
            throw LookoutError.networkError("Invalid FlightRadar24 URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(fr24APIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LookoutError.apiError("No HTTP response from FlightRadar24")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401:
            throw LookoutError.apiError("FlightRadar24: Invalid API key")
        case 429:
            throw LookoutError.apiError("FlightRadar24: Rate limited")
        default:
            throw LookoutError.apiError("FlightRadar24 returned status \(httpResponse.statusCode)")
        }

        // Parse the FR24 response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flightsData = json["data"] as? [[String: Any]] else {
            #if DEBUG
            print("✈️ FR24: No flight data in response")
            #endif
            return []
        }

        var aircraft: [NearbyAircraft] = []

        for flight in flightsData {
            let callsign = (flight["callsign"] as? String)?.trimmingCharacters(in: .whitespaces)
            let flightNumber = (flight["flight"] as? String)?.trimmingCharacters(in: .whitespaces)
            let acLat = asDouble(flight["lat"])
            let acLon = asDouble(flight["lon"])
            let altitude = asDouble(flight["alt"]) // FR24 may return feet directly
            let speed = asDouble(flight["gspeed"]) ?? asDouble(flight["speed"])
            let heading = asDouble(flight["track"]) ?? asDouble(flight["heading"])
            let icao24 = flight["hex"] as? String ?? flight["icao24"] as? String
            let registration = flight["reg"] as? String ?? flight["registration"] as? String
            let aircraftType = flight["type"] as? String ?? flight["aircraft_type"] as? String

            // Airline info
            let airlineName = flight["airline_name"] as? String
                ?? (flight["airline"] as? [String: Any])?["name"] as? String

            // Route info — try multiple possible response shapes
            let originCode: String? = flight["orig_iata"] as? String
                ?? ((flight["airport"] as? [String: Any])?["origin"] as? [String: Any])?["iata"] as? String
                ?? (flight["origin"] as? [String: Any])?["iata"] as? String
                ?? flight["origin"] as? String

            let destCode: String? = flight["dest_iata"] as? String
                ?? ((flight["airport"] as? [String: Any])?["destination"] as? [String: Any])?["iata"] as? String
                ?? (flight["destination"] as? [String: Any])?["iata"] as? String
                ?? flight["destination"] as? String

            // Calculate distance
            var distanceNM: Double? = nil
            if let acLat = acLat, let acLon = acLon {
                let distMeters = CLLocation(latitude: lat, longitude: lon)
                    .distance(from: CLLocation(latitude: acLat, longitude: acLon))
                distanceNM = distMeters / 1852.0
            }

            // Altitude: FR24 full endpoint returns feet
            let altFt: Int?
            if let alt = altitude {
                altFt = Int(alt)
            } else {
                altFt = nil
            }

            // Speed: FR24 returns knots
            let speedKts: Int?
            if let spd = speed {
                speedKts = Int(spd)
            } else {
                speedKts = nil
            }

            let ac = NearbyAircraft(
                icao24: icao24,
                callsign: (callsign?.isEmpty ?? true) ? nil : callsign,
                originCountry: nil,
                altitudeFt: altFt,
                speedKnots: speedKts,
                heading: heading,
                distanceNM: distanceNM,
                source: "FlightRadar24",
                airline: airlineName,
                aircraftType: aircraftType,
                registration: registration,
                origin: originCode,
                destination: destCode,
                flightNumber: (flightNumber?.isEmpty ?? true) ? nil : flightNumber
            )
            aircraft.append(ac)
        }

        // Sort by distance (closest first)
        aircraft.sort { ($0.distanceNM ?? .greatestFiniteMagnitude) < ($1.distanceNM ?? .greatestFiniteMagnitude) }

        #if DEBUG
        print("✈️ FlightRadar24 found \(aircraft.count) aircraft nearby")
        if let closest = aircraft.first {
            let id = closest.flightNumber ?? closest.callsign ?? closest.icao24 ?? "unknown"
            print("✈️ Closest: \(id) at \(String(format: "%.1f", closest.distanceNM ?? 0)) nm")
            if let airline = closest.airline { print("✈️   Airline: \(airline)") }
            if let route = closest.origin.flatMap({ o in closest.destination.map { d in "\(o)→\(d)" } }) {
                print("✈️   Route: \(route)")
            }
        }
        #endif

        return aircraft
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

    // FR24-enriched fields
    let airline: String?
    let aircraftType: String?
    let registration: String?
    let origin: String?
    let destination: String?
    let flightNumber: String?

    init(
        icao24: String? = nil,
        callsign: String? = nil,
        originCountry: String? = nil,
        altitudeFt: Int? = nil,
        speedKnots: Int? = nil,
        heading: Double? = nil,
        distanceNM: Double? = nil,
        source: String,
        airline: String? = nil,
        aircraftType: String? = nil,
        registration: String? = nil,
        origin: String? = nil,
        destination: String? = nil,
        flightNumber: String? = nil
    ) {
        self.icao24 = icao24
        self.callsign = callsign
        self.originCountry = originCountry
        self.altitudeFt = altitudeFt
        self.speedKnots = speedKnots
        self.heading = heading
        self.distanceNM = distanceNM
        self.source = source
        self.airline = airline
        self.aircraftType = aircraftType
        self.registration = registration
        self.origin = origin
        self.destination = destination
        self.flightNumber = flightNumber
    }
}
