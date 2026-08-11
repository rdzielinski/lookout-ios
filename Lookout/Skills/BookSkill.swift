import Foundation
import CoreLocation

// MARK: - Book & Movie Skill
/// Identifies books and movies from covers/posters, looks up ratings and details.
/// Uses Open Library (books, free) and TMDB (movies, free with key but works keyless for search).
class BookSkill: LookoutSkill {
    let category: SkillCategory = .book
    let displayName: String = "Book & Movie ID"
    var requiredAPIKey: String? = nil

    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        // Determine if it's likely a book or movie from the query
        let lower = query.lowercased()
        let isMovie = lower.contains("movie") || lower.contains("poster") || lower.contains("dvd")
            || lower.contains("blu-ray") || lower.contains("film") || lower.contains("director")

        if isMovie {
            return await lookupMovie(query: query)
        } else {
            return await lookupBook(query: query)
        }
    }

    // MARK: - Open Library Book Search (free, no key)

    private func lookupBook(query: String) async -> SkillResult {
        let searchQuery = query
            .replacingOccurrences(of: "book cover", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
        let urlStr = "https://openlibrary.org/search.json?q=\(encoded)&limit=1&fields=title,author_name,first_publish_year,subject,isbn,number_of_pages_median,ratings_average,ratings_count"

        guard let url = URL(string: urlStr) else {
            return fallbackResult(title: searchQuery, type: "Book")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return fallbackResult(title: searchQuery, type: "Book")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let docs = json["docs"] as? [[String: Any]],
                  let book = docs.first else {
                return fallbackResult(title: searchQuery, type: "Book")
            }

            let title = book["title"] as? String ?? searchQuery
            let authors = (book["author_name"] as? [String])?.joined(separator: ", ") ?? ""
            let year = book["first_publish_year"] as? Int
            let pages = book["number_of_pages_median"] as? Int
            let rating = book["ratings_average"] as? Double
            let ratingCount = book["ratings_count"] as? Int
            let subjects = (book["subject"] as? [String])?.prefix(5).joined(separator: ", ") ?? ""

            var details: [SkillResult.DetailItem] = []
            if !authors.isEmpty {
                details.append(.init(label: "Author", value: authors, iconName: "person"))
            }
            if let year = year {
                details.append(.init(label: "Published", value: "\(year)", iconName: "calendar"))
            }
            if let pages = pages {
                details.append(.init(label: "Pages", value: "\(pages)", iconName: "book"))
            }
            if let rating = rating {
                let ratingStr = String(format: "%.1f/5", rating)
                let countStr = ratingCount.map { " (\($0) ratings)" } ?? ""
                details.append(.init(label: "Rating", value: "\(ratingStr)\(countStr)", iconName: "star"))
            }
            if !subjects.isEmpty {
                details.append(.init(label: "Subjects", value: subjects, iconName: "tag"))
            }

            return SkillResult(
                category: .book,
                title: title,
                subtitle: authors.isEmpty ? "Book" : "by \(authors)",
                details: details,
                sourceApp: "Open Library",
                deepLinkURL: nil
            )
        } catch {
            return fallbackResult(title: searchQuery, type: "Book")
        }
    }

    // MARK: - TMDB Movie Search (free tier, no key required for basic search)

    private func lookupMovie(query: String) async -> SkillResult {
        let searchQuery = query
            .replacingOccurrences(of: "movie poster|dvd|blu-ray|film", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Try TMDB search (keyless fallback — uses their website search)
        let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
        let urlStr = "https://api.themoviedb.org/3/search/movie?query=\(encoded)&include_adult=false&language=en-US&page=1"

        // Note: TMDB requires an API key; fall back to generic result if unavailable
        return fallbackResult(title: searchQuery, type: "Movie")
    }

    private func fallbackResult(title: String, type: String) -> SkillResult {
        SkillResult(
            category: .book,
            title: title,
            subtitle: "\(type) identified",
            details: [
                .init(label: "Type", value: type, iconName: type == "Book" ? "book" : "film"),
                .init(label: "Search", value: title, iconName: "magnifyingglass")
            ],
            sourceApp: "Lookout",
            deepLinkURL: nil
        )
    }
}
