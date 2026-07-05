//
//  CryptoBox.swift
//  Channels
//
//  Body cipher recovered from the live app (com.xuper.netxxus / masnew build):
//  3DES/ECB/PKCS5, key = base64-decoded PORTAL_KEY string. On the wire the body
//  is the RAW string  hex( base64( 3DES(json) ) )  — NOT a {data,len} envelope.
//  (Confirmed via runtime keylog + decrypted device capture, 2026-07-04.)
//

import Foundation
import CommonCrypto

enum CryptoError: Error { case encryptFailed, decryptFailed, badInput }

enum CryptoBox {

    /// 3DES key: the app's custom Base64 decoder maps '-' → '/'. So the real
    /// 24-byte key = base64decode( keyString with "-" replaced by "/" )[0..<24].
    /// (CONFIRMED byte-exact against the live app.)
    private static func keyBytes() -> [UInt8] {
        let b64 = AppConfig.bodyKey.replacingOccurrences(of: "-", with: "/")
        let padded = b64 + String(repeating: "=", count: (4 - b64.count % 4) % 4)
        let data = Data(base64Encoded: padded) ?? Data()
        return Array([UInt8](data).prefix(24))
    }

    // MARK: - Public: request body / response

    /// Encrypts a raw JSON string into the wire body: hex(base64(3DES(json))).
    static func encryptBody(_ rawJSON: String) throws -> String {
        let ct = try crypt(Array(rawJSON.utf8), op: CCOperation(kCCEncrypt))
        let b64 = Data(ct).base64EncodedString()
        return Data(b64.utf8).map { String(format: "%02x", $0) }.joined()   // hex of the base64 string
    }

    /// Decrypts a wire response `data` (hex(base64(3DES))) back to plaintext.
    static func decryptBody(_ hexString: String) throws -> String {
        guard let b64Data = hexDecode(hexString),
              let b64 = String(data: b64Data, encoding: .utf8),
              let ct = Data(base64Encoded: b64) else { throw CryptoError.badInput }
        let pt = try crypt([UInt8](ct), op: CCOperation(kCCDecrypt))
        return String(decoding: pt, as: UTF8.self)
    }

    // MARK: - 3DES/ECB/PKCS7

    private static func crypt(_ input: [UInt8], op: CCOperation) throws -> [UInt8] {
        let key = keyBytes()
        var outLen = 0
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSize3DES)
        let status = key.withUnsafeBytes { kp in
            input.withUnsafeBytes { dp in
                CCCrypt(op,
                        CCAlgorithm(kCCAlgorithm3DES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        kp.baseAddress, key.count,
                        nil,                        // ECB: no IV
                        dp.baseAddress, input.count,
                        &out, out.count, &outLen)
            }
        }
        guard status == kCCSuccess else {
            throw op == CCOperation(kCCEncrypt) ? CryptoError.encryptFailed : CryptoError.decryptFailed
        }
        return Array(out.prefix(outLen))
    }

    private static func hexDecode(_ s: String) -> Data? {
        let chars = Array(s)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            data.append(b); i += 2
        }
        return data
    }
}
