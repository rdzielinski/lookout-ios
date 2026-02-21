import Foundation

// MARK: - Price Lookup Service
/// Finds real pricing, retailer availability, and reviews for products.
/// Data sources:
///   1. UPCitemdb.com (free, 100 req/day) — barcode → product info
///   2. Google Shopping search — real prices from major retailers
///   3. Heuristic fallback — ballpark estimates for common items
class PriceLookupService {

    // In-memory cache to avoid redundant API calls for the same barcode
    private var barcodeCache: [String: (pricing: ProductPricing, date: Date)] = [:]
    private let cacheTTL: TimeInterval = 300 // 5 minutes
    
    // MARK: - Public Models
    
    struct ProductPricing {
        let productName: String
        let retailerPrices: [RetailerPrice]
        let averageRating: Double?
        let reviewCount: Int?
        let summary: String // Formatted for display
        
        /// Best (lowest) price found
        var bestPrice: RetailerPrice? {
            retailerPrices.min(by: { $0.price < $1.price })
        }
    }
    
    struct RetailerPrice {
        let retailer: String
        let price: Double
        let formattedPrice: String
        let inStock: Bool?
        let url: String?
        let rating: Double?
    }
    
    struct UPCProduct {
        let title: String
        let brand: String
        let description: String
        let category: String
        let upc: String
        let imageURL: String?
    }
    
    // MARK: - Main Lookup Methods
    
    /// Full product lookup by barcode — gets product info + pricing + reviews
    func lookupByBarcode(barcode: String) async -> ProductPricing? {
        // Return cached result if still fresh
        if let cached = barcodeCache[barcode], Date().timeIntervalSince(cached.date) < cacheTTL {
            return cached.pricing
        }

        // Step 1: Identify product via UPCitemdb
        let product = await lookupUPC(barcode: barcode)
        let searchQuery = product?.title ?? barcode
        let brand = product?.brand ?? ""

        // Step 2: Search for prices across retailers
        let retailerPrices = await searchRetailerPrices(query: "\(brand) \(searchQuery)".trimmingCharacters(in: .whitespaces))

        // Step 3: Build pricing result
        if !retailerPrices.isEmpty {
            let avgRating = averageRating(from: retailerPrices)
            let summary = buildPriceSummary(retailerPrices: retailerPrices, avgRating: avgRating)

            let pricing = ProductPricing(
                productName: product?.title ?? searchQuery,
                retailerPrices: retailerPrices,
                averageRating: avgRating,
                reviewCount: nil,
                summary: summary
            )
            barcodeCache[barcode] = (pricing: pricing, date: Date())
            return pricing
        }

        return nil
    }
    
    /// Price lookup by product name (from AI identification, no barcode)
    func lookupByName(productName: String, brand: String = "", category: String = "") async -> ProductPricing? {
        let query = "\(brand) \(productName)".trimmingCharacters(in: .whitespaces)
        let retailerPrices = await searchRetailerPrices(query: query)
        
        if !retailerPrices.isEmpty {
            let avgRating = averageRating(from: retailerPrices)
            let summary = buildPriceSummary(retailerPrices: retailerPrices, avgRating: avgRating)
            
            return ProductPricing(
                productName: productName,
                retailerPrices: retailerPrices,
                averageRating: avgRating,
                reviewCount: nil,
                summary: summary
            )
        }
        
        return nil
    }
    
    /// Simple price estimate (backward compatible with old interface)
    func estimatePrice(productName: String, brand: String = "", category: String = "") async -> String? {
        // Try real lookup first
        if let pricing = await lookupByName(productName: productName, brand: brand, category: category) {
            return pricing.summary
        }
        
        // Fall back to heuristics
        return heuristicPriceEstimate(name: productName, brand: brand, category: category)
    }
    
    // MARK: - UPCitemdb Lookup (100 free requests/day)
    
    /// Look up a barcode on UPCitemdb.com
    /// Free tier: 100 requests/day, no API key needed
    func lookupUPC(barcode: String) async -> UPCProduct? {
        let urlString = "https://api.upcitemdb.com/prod/trial/lookup?upc=\(barcode)"
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                #if DEBUG
                print("⚠️ UPCitemdb returned status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                #endif
                return nil
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]],
                  let item = items.first else {
                return nil
            }
            
            return UPCProduct(
                title: item["title"] as? String ?? "",
                brand: item["brand"] as? String ?? "",
                description: item["description"] as? String ?? "",
                category: item["category"] as? String ?? "",
                upc: barcode,
                imageURL: (item["images"] as? [String])?.first
            )
        } catch {
            #if DEBUG
            print("⚠️ UPCitemdb error: \(error)")
            #endif
            return nil
        }
    }
    
    // MARK: - Google Shopping Price Search
    
    /// Search Google Shopping for real retailer prices.
    /// Parses the HTML response for price data from major retailers.
    private func searchRetailerPrices(query: String) async -> [RetailerPrice] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        // Google Shopping search URL — tbm=shop enables shopping results
        let urlString = "https://www.google.com/search?q=\(encoded)&tbm=shop&hl=en"
        
        guard let url = URL(string: urlString) else { return [] }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // Mimic a mobile browser to get simpler HTML
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                return []
            }
            
            return parseGoogleShoppingResults(html: html)
        } catch {
            #if DEBUG
            print("⚠️ Google Shopping search error: \(error)")
            #endif
            return []
        }
    }
    
    /// Parse Google Shopping HTML for price and retailer data
    private func parseGoogleShoppingResults(html: String) -> [RetailerPrice] {
        var prices: [RetailerPrice] = []
        
        // Strategy 1: Look for structured price data in the HTML
        // Google Shopping puts prices in various formats; we try multiple patterns
        
        // Pattern: "$XX.XX" followed by retailer name
        // Common in Google Shopping cards: "from $24.99" or "$24.99 at Amazon"
        let priceRetailerPattern = "\\$([\\d,]+\\.\\d{2})(?:[^<]{0,80}?)(?:from |at |by |· )([A-Za-z][A-Za-z0-9 .&']+?)(?:[<\"\\|·]|$)"
        if let regex = try? NSRegularExpression(pattern: priceRetailerPattern, options: []) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            
            for match in matches.prefix(10) {
                if let priceRange = Range(match.range(at: 1), in: html),
                   let retailerRange = Range(match.range(at: 2), in: html) {
                    let priceStr = String(html[priceRange])
                    let retailer = String(html[retailerRange]).trimmingCharacters(in: .whitespaces)
                    
                    if let price = Double(priceStr.replacingOccurrences(of: ",", with: "")),
                       price > 0 && price < 100000,
                       isKnownRetailer(retailer) || retailer.count >= 3 {
                        let cleanRetailer = cleanRetailerName(retailer)
                        // Deduplicate — keep lowest price per retailer
                        if !prices.contains(where: { $0.retailer.lowercased() == cleanRetailer.lowercased() }) {
                            prices.append(RetailerPrice(
                                retailer: cleanRetailer,
                                price: price,
                                formattedPrice: "$\(priceStr)",
                                inStock: true,
                                url: nil,
                                rating: nil
                            ))
                        }
                    }
                }
            }
        }
        
        // Strategy 2: Find standalone prices if strategy 1 didn't get enough
        if prices.count < 2 {
            let standalonePricePattern = "\\$([\\d,]+\\.\\d{2})"
            if let regex = try? NSRegularExpression(pattern: standalonePricePattern, options: []) {
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                
                var foundPrices: [Double] = []
                for match in matches.prefix(20) {
                    if let range = Range(match.range(at: 1), in: html) {
                        let priceStr = String(html[range]).replacingOccurrences(of: ",", with: "")
                        if let price = Double(priceStr), price > 0.50 && price < 100000 {
                            foundPrices.append(price)
                        }
                    }
                }
                
                // If we found prices but no retailers, create a generic entry
                if prices.isEmpty && !foundPrices.isEmpty {
                    let sorted = foundPrices.sorted()
                    let lowest = sorted.first!
                    let highest = sorted.count > 1 ? sorted.last! : lowest
                    
                    prices.append(RetailerPrice(
                        retailer: "Online",
                        price: lowest,
                        formattedPrice: String(format: "$%.2f", lowest),
                        inStock: nil,
                        url: nil,
                        rating: nil
                    ))
                    
                    if highest != lowest && highest < lowest * 3 {
                        prices.append(RetailerPrice(
                            retailer: "Other sellers",
                            price: highest,
                            formattedPrice: String(format: "$%.2f", highest),
                            inStock: nil,
                            url: nil,
                            rating: nil
                        ))
                    }
                }
            }
        }
        
        // Strategy 3: Extract ratings if present
        // Google Shopping often shows ratings like "4.5 (1,234)"
        let ratingPattern = "([\\d.]+)\\s*(?:out of 5|/5|★)\\s*(?:\\(([\\d,]+)\\s*(?:reviews?|ratings?)?\\))?"
        if let regex = try? NSRegularExpression(pattern: ratingPattern, options: []) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            
            if let firstMatch = matches.first,
               let ratingRange = Range(firstMatch.range(at: 1), in: html),
               let rating = Double(String(html[ratingRange])),
               rating >= 1.0 && rating <= 5.0 {
                // Apply rating to the first price entry
                if !prices.isEmpty {
                    let existing = prices[0]
                    prices[0] = RetailerPrice(
                        retailer: existing.retailer,
                        price: existing.price,
                        formattedPrice: existing.formattedPrice,
                        inStock: existing.inStock,
                        url: existing.url,
                        rating: rating
                    )
                }
            }
        }
        
        // Sort by price (lowest first) and limit to top 5 retailers
        return Array(prices.sorted(by: { $0.price < $1.price }).prefix(5))
    }
    
    // MARK: - Retailer Helpers
    
    private let knownRetailers = [
        "amazon", "walmart", "target", "best buy", "costco", "sam's club",
        "home depot", "lowe's", "lowes", "kroger", "walgreens", "cvs",
        "ebay", "etsy", "wayfair", "newegg", "b&h", "adorama",
        "macy's", "macys", "nordstrom", "kohl's", "kohls",
        "staples", "office depot", "gamestop", "apple", "google store",
        "petco", "petsmart", "chewy", "menards", "ace hardware",
        "bed bath", "overstock", "zappos", "dick's", "rei",
        "harbor freight", "autozone", "o'reilly", "advance auto"
    ]
    
    private func isKnownRetailer(_ name: String) -> Bool {
        let lower = name.lowercased()
        return knownRetailers.contains(where: { lower.contains($0) })
    }
    
    private func cleanRetailerName(_ name: String) -> String {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove trailing punctuation
        while clean.last == "." || clean.last == "," || clean.last == "|" {
            clean.removeLast()
        }
        clean = clean.trimmingCharacters(in: .whitespaces)
        
        // Capitalize known retailers properly
        let lower = clean.lowercased()
        let capitalizationMap: [String: String] = [
            "amazon": "Amazon", "amazon.com": "Amazon",
            "walmart": "Walmart", "walmart.com": "Walmart",
            "target": "Target", "target.com": "Target",
            "best buy": "Best Buy", "bestbuy": "Best Buy",
            "costco": "Costco", "costco.com": "Costco",
            "home depot": "Home Depot", "homedepot": "Home Depot",
            "lowe's": "Lowe's", "lowes": "Lowe's",
            "ebay": "eBay", "ebay.com": "eBay",
            "newegg": "Newegg", "newegg.com": "Newegg",
            "walgreens": "Walgreens", "cvs": "CVS",
            "kroger": "Kroger", "menards": "Menards",
            "apple": "Apple", "apple.com": "Apple",
            "b&h": "B&H Photo", "b&h photo": "B&H Photo"
        ]
        
        for (key, value) in capitalizationMap {
            if lower == key || lower.hasPrefix(key) {
                return value
            }
        }
        
        return clean
    }
    
    // MARK: - Summary Builder
    
    private func buildPriceSummary(retailerPrices: [RetailerPrice], avgRating: Double?) -> String {
        guard !retailerPrices.isEmpty else { return "" }
        
        if retailerPrices.count == 1 {
            let p = retailerPrices[0]
            var summary = "\(p.formattedPrice) at \(p.retailer)"
            if let rating = avgRating {
                summary += " · ★\(String(format: "%.1f", rating))"
            }
            return summary
        }
        
        // Multiple retailers — show range
        let lowest = retailerPrices.first!
        let highest = retailerPrices.last!
        
        var summary: String
        if lowest.price == highest.price {
            summary = "\(lowest.formattedPrice) at \(retailerPrices.map { $0.retailer }.joined(separator: ", "))"
        } else {
            summary = "\(lowest.formattedPrice)–\(highest.formattedPrice)"
            summary += " · \(lowest.retailer) lowest"
        }
        
        if let rating = avgRating {
            summary += " · ★\(String(format: "%.1f", rating))"
        }
        
        return summary
    }
    
    private func averageRating(from prices: [RetailerPrice]) -> Double? {
        let ratings = prices.compactMap { $0.rating }
        guard !ratings.isEmpty else { return nil }
        return ratings.reduce(0, +) / Double(ratings.count)
    }
    
    // MARK: - Heuristic Fallback
    
    private func heuristicPriceEstimate(name: String, brand: String, category: String) -> String? {
        let lower = "\(name) \(brand) \(category)".lowercased()
        
        // Beverages
        if lower.contains("coca-cola") || lower.contains("pepsi") || lower.contains("soda") || lower.contains("cola") {
            if lower.contains("2 liter") || lower.contains("2l") { return "$2–3" }
            if lower.contains("12 pack") || lower.contains("12-pack") { return "$6–8" }
            if lower.contains("can") || lower.contains("bottle") { return "$1–2" }
            return "$2–5"
        }
        if lower.contains("water") && (lower.contains("bottle") || lower.contains("spring") || lower.contains("purified")) {
            if lower.contains("case") || lower.contains("pack") { return "$4–7" }
            return "$1–2"
        }
        if lower.contains("coffee") {
            if lower.contains("starbucks") || lower.contains("dunkin") { return "$4–7" }
            if lower.contains("ground") || lower.contains("bean") { return "$8–14" }
            return "$5–12"
        }
        if lower.contains("energy drink") || lower.contains("red bull") || lower.contains("monster") || lower.contains("celsius") {
            return "$2–4"
        }
        if lower.contains("beer") || lower.contains("ale") || lower.contains("lager") || lower.contains("ipa") {
            if lower.contains("6 pack") || lower.contains("six pack") { return "$9–13" }
            if lower.contains("12 pack") { return "$15–20" }
            return "$2–4"
        }
        if lower.contains("wine") { return "$8–20" }
        
        // Snacks
        if lower.contains("chips") || lower.contains("doritos") || lower.contains("lays") || lower.contains("cheetos") || lower.contains("pringles") {
            if lower.contains("family") || lower.contains("party") { return "$5–7" }
            return "$3–5"
        }
        if lower.contains("chocolate") || lower.contains("candy") || lower.contains("bar") {
            if lower.contains("bag") || lower.contains("share") { return "$4–6" }
            return "$1–3"
        }
        
        // Cereal / dairy / bread
        if lower.contains("cereal") || lower.contains("cheerios") || lower.contains("frosted") || lower.contains("granola") { return "$4–6" }
        if lower.contains("milk") { return "$3–5" }
        if lower.contains("cheese") { return "$3–8" }
        if lower.contains("yogurt") { return lower.contains("greek") ? "$4–7" : "$1–4" }
        if lower.contains("bread") || lower.contains("loaf") { return "$3–5" }
        
        // Frozen
        if lower.contains("ice cream") || lower.contains("gelato") { return "$4–7" }
        if lower.contains("frozen") && (lower.contains("pizza") || lower.contains("dinner") || lower.contains("meal")) { return "$5–10" }
        
        // Personal care
        if lower.contains("shampoo") || lower.contains("conditioner") { return "$5–10" }
        if lower.contains("toothpaste") { return "$3–6" }
        if lower.contains("deodorant") { return "$4–8" }
        
        // Cleaning
        if lower.contains("detergent") || lower.contains("laundry") { return "$8–15" }
        if lower.contains("cleaner") || lower.contains("wipes") || lower.contains("spray") { return "$3–6" }
        
        // Electronics
        if lower.contains("airpods pro") { return "$200–250" }
        if lower.contains("airpods") { return "$130–180" }
        if lower.contains("headphones") || lower.contains("earbuds") { return "$20–80" }
        if lower.contains("charger") || lower.contains("cable") { return "$10–30" }
        
        return nil
    }
}
