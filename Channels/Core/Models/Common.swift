//
//  Common.swift
//  Channels
//
//  Shared model primitives + lenient decoding helpers (doc 14).
//

import Foundation

// MARK: - Poster

struct PosterList: Codable, Hashable {
    var fileUrl: String? = nil
    var fileType: String? = nil      // e.g. portrait / landscape / icon (vocab TO CONFIRM)
    var size: String? = nil
    var name: String? = nil
    var channelCode: String? = nil
}

extension Array where Element == PosterList {
    /// Best-effort channel logo URL (prefers an icon/logo poster).
    var iconURL: URL? { url(preferring: ["icon", "logo"]) }

    var anyURL: URL? { compactMap { $0.fileUrl }.compactMap { URL(string: $0) }.first }

    private func url(preferring types: [String]) -> URL? {
        for t in types {
            if let match = first(where: { ($0.fileType ?? "").lowercased().contains(t) }),
               let s = match.fileUrl, let u = URL(string: s) {
                return u
            }
        }
        return anyURL
    }
}

/// Every portal response carries a returnCode.
struct BaseResult: Codable {
    let returnCode: String?
    let errorMessage: String?
}

extension String {
    /// Success family: returnCode starting "aaa1000..." (confirm exact codes via capture).
    var isSuccessReturnCode: Bool { hasPrefix("aaa1000") || self == "aaa100094" }
}

// MARK: - Lenient scalar decoding

/// Decodes an Int that may arrive as a String or number.
@propertyWrapper
struct LenientInt: Codable, Hashable {
    var wrappedValue: Int?

    init(wrappedValue: Int?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { wrappedValue = i }
        else if let s = try? c.decode(String.self) { wrappedValue = Int(s) }
        else if let d = try? c.decode(Double.self) { wrappedValue = Int(d) }
        else { wrappedValue = nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}
