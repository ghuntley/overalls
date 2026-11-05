import Foundation
import SwiftUI
import CoreGraphics

public struct MilaTerminalSpan: Decodable, Sendable {
    public let text: String
    public let foreground: UInt32?
    public let background: UInt32?
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let inverse: Bool
}

/// Decoded display cells from Rust's bounded VT parser. Control strings never reach SwiftUI.
public struct MilaTerminalFrame: Decodable, Sendable {
    public let version: UInt8
    public let columns: UInt16
    public let rows: UInt16
    public let cursorColumn: UInt16
    public let cursorRow: UInt16
    public let lines: [[MilaTerminalSpan]]
    public let images: [MilaTerminalImage]
    enum CodingKeys: String, CodingKey {
        case version, columns, rows, lines, images
        case cursorColumn = "cursor_column", cursorRow = "cursor_row"
    }
    public var text: String { lines.map { $0.map(\.text).joined() }.joined(separator: "\n") }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 << 20 else { throw MilaTerminalError.invalidRequest }
        let frame = try JSONDecoder().decode(Self.self, from: data)
        guard frame.version == 1, (1...4096).contains(frame.columns), (1...512).contains(frame.rows),
              frame.cursorColumn < frame.columns, frame.cursorRow < frame.rows,
              frame.lines.count <= Int(frame.rows),
              frame.lines.allSatisfy({ line in
                  line.reduce(0) { $0 + $1.text.unicodeScalars.count } <= Int(frame.columns) && line.allSatisfy { span in
                      !span.text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
                      span.foreground.map { $0 <= 0xffffff } != false && span.background.map { $0 <= 0xffffff } != false
                  }
              }), frame.lines.flatMap({ $0 }).reduce(0, { $0 + $1.text.unicodeScalars.count }) <= 16_384,
              frame.images.count <= 8,
              frame.images.allSatisfy(\.isValid),
              frame.images.reduce(0, { $0 + $1.pixels.count }) <= 1_048_576 else {
            throw MilaTerminalError.invalidRequest
        }
        return frame
    }

    public var attributed: AttributedString {
        var result = AttributedString()
        func color(_ rgb: UInt32) -> Color {
            Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }
        for (index, line) in lines.enumerated() {
            if index != 0 { result.append(AttributedString("\n")) }
            for span in line {
                var part = AttributedString(span.text)
                var font = Font.system(.body, design: .monospaced).weight(span.bold ? .bold : .regular)
                if span.italic { font = font.italic() }
                part.font = font
                if let foreground = span.inverse ? (span.background ?? 0x101010) : span.foreground { part.foregroundColor = color(foreground) }
                if let background = span.inverse ? (span.foreground ?? 0xd0d0d0) : span.background { part.backgroundColor = color(background) }
                if span.underline { part.underlineStyle = .single }
                result.append(part)
            }
        }
        return result
    }
}

public struct MilaTerminalImage: Decodable, Sendable {
    public let x: UInt16; public let y: UInt16; public let width: UInt16; public let height: UInt16; public let pixels: [UInt32]

    var isValid: Bool {
        width > 0 && height > 0 && width <= 1024 && height <= 1024 &&
        pixels.count == Int(width) * Int(height) && pixels.allSatisfy { $0 <= 0xffffff }
    }

    /// @cc [owner:ghuntley,label:security;terminal] apple-terminal-image-rgba
    /// A bounded 24-bit RGB image MUST project each pixel as exactly four RGBA
    /// bytes with opaque alpha. Invalid dimensions or pixels MUST be refused
    /// before allocation; a valid colour MUST NOT trap during byte conversion.
    var rgbaBytes: Data? {
        guard isValid else { return nil }
        var bytes = Data(capacity: pixels.count * 4)
        for pixel in pixels {
            bytes.append(contentsOf: [UInt8((pixel >> 16) & 0xff), UInt8((pixel >> 8) & 0xff), UInt8(pixel & 0xff), 255])
        }
        return bytes
    }

    var cgImage: CGImage? {
        guard let bytes = rgbaBytes, let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
