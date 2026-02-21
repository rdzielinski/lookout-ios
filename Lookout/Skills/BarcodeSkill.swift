//
//  BarcodeSkill.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/13/26.
//


import Foundation
import CoreLocation
import Vision
import UIKit

// MARK: - Barcode & QR Code Skill
class BarcodeSkill: LookoutSkill {
    let category: SkillCategory = .product
    let displayName: String = "Barcode Scanner"
    var requiredAPIKey: String? = nil

    // In-memory cache: barcode → (result, date)
    private var lookupCache: [String: (result: SkillResult, date: Date)] = [:]
    private let cacheTTL: TimeInterval = 300 // 5 minutes
    
    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        let cleaned = query.filter { $0.isNumber }

        if cleaned.count >= 8 {
            // Return cached result if still fresh
            if let cached = lookupCache[cleaned], Date().timeIntervalSince(cached.date) < cacheTTL {
                return cached.result
            }

            if let product = try? await lookupBarcode(cleaned) {
                lookupCache[cleaned] = (result: product, date: Date())
                return product
            }
        }

        if let product = try? await searchProduct(query) {
            return product
        }

        return createFallbackResult(query: query)
    }
    
    /// Scan an image for barcodes using Apple Vision framework
    func scanImage(_ imageData: Data) async throws -> String? {
        guard let image = UIImage(data: imageData)?.cgImage else { return nil }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let results = request.results as? [VNBarcodeObservation],
                      let barcode = results.first,
                      let payload = barcode.payloadStringValue else {
                    continuation.resume(returning: nil)
                    return
                }
                
                continuation.resume(returning: payload)
            }
            
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - Open Food Facts Barcode Lookup (Free, no key)
    
    private func lookupBarcode(_ barcode: String) async throws -> SkillResult? {
        let urlString = "https://world.openfoodfacts.org/api/v2/product/\(barcode).json"
        
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Lookout iOS App/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        
        let offResponse = try JSONDecoder().decode(OpenFoodFactsResponse.self, from: data)
        
        guard offResponse.status == 1, let product = offResponse.product else {
            return nil
        }
        
        var details: [SkillResult.DetailItem] = []
        
        if let brand = product.brands, !brand.isEmpty {
            details.append(.init(label: "Brand", value: brand, iconName: "tag"))
        }
        if let qty = product.quantity, !qty.isEmpty {
            details.append(.init(label: "Size", value: qty, iconName: "scalemass"))
        }
        if let grade = product.nutriscore_grade?.uppercased() {
            details.append(.init(label: "Nutri-Score", value: grade, iconName: "heart"))
        }
        if let categories = product.categories, !categories.isEmpty {
            let short = categories.components(separatedBy: ",").prefix(3).joined(separator: ", ")
            details.append(.init(label: "Category", value: short, iconName: "square.grid.2x2"))
        }
        if let ingredients = product.ingredients_text_en ?? product.ingredients_text, !ingredients.isEmpty {
            let trimmed = String(ingredients.prefix(200))
            details.append(.init(label: "Ingredients", value: trimmed, iconName: "list.bullet"))
        }
        
        details.append(.init(label: "Barcode", value: barcode, iconName: "barcode"))
        
        let name = product.product_name ?? product.product_name_en ?? "Unknown Product"
        let brand = product.brands ?? ""
        
        let offURL = URL(string: "https://world.openfoodfacts.org/product/\(barcode)")
        
        return SkillResult(
            category: .product,
            title: name,
            subtitle: brand,
            details: details,
            sourceApp: "Open Food Facts",
            deepLinkURL: offURL
        )
    }
    
    // MARK: - Product Search (Open Food Facts)
    
    private func searchProduct(_ query: String) async throws -> SkillResult? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://world.openfoodfacts.org/cgi/search.pl?search_terms=\(encoded)&search_simple=1&action=process&json=1&page_size=1"
        
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Lookout iOS App/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        
        let searchResponse = try JSONDecoder().decode(OpenFoodFactsSearchResponse.self, from: data)
        
        guard let product = searchResponse.products?.first else { return nil }
        
        var details: [SkillResult.DetailItem] = []
        
        if let brand = product.brands, !brand.isEmpty {
            details.append(.init(label: "Brand", value: brand, iconName: "tag"))
        }
        if let qty = product.quantity, !qty.isEmpty {
            details.append(.init(label: "Size", value: qty, iconName: "scalemass"))
        }
        if let grade = product.nutriscore_grade?.uppercased() {
            details.append(.init(label: "Nutri-Score", value: grade, iconName: "heart"))
        }
        
        let name = product.product_name ?? product.product_name_en ?? "Product"
        let brand = product.brands ?? query
        
        return SkillResult(
            category: .product,
            title: name,
            subtitle: brand,
            details: details,
            sourceApp: "Open Food Facts",
            deepLinkURL: nil
        )
    }
    
    private func createFallbackResult(query: String) -> SkillResult {
        SkillResult(
            category: .product,
            title: "Product Spotted",
            subtitle: query,
            details: [
                .init(label: "Description", value: query, iconName: "barcode"),
                .init(label: "Tip", value: "Try centering the barcode in the frame for a better scan.", iconName: "viewfinder")
            ],
            sourceApp: "Lookout",
            deepLinkURL: nil
        )
    }
}

// MARK: - Open Food Facts Models

struct OpenFoodFactsResponse: Codable {
    let status: Int?
    let product: OFFProduct?
}

struct OpenFoodFactsSearchResponse: Codable {
    let products: [OFFProduct]?
}

struct OFFProduct: Codable {
    let product_name: String?
    let product_name_en: String?
    let brands: String?
    let quantity: String?
    let categories: String?
    let nutriscore_grade: String?
    let ingredients_text: String?
    let ingredients_text_en: String?
}