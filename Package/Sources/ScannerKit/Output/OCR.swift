import CoreGraphics
import Foundation
import Vision

/// Eine erkannte Textzeile.
public struct TextLine: Sendable, Equatable {
    public let text: String
    /// Umrahmung in Bruchteilen der Bildgröße (0 bis 1), Ursprung unten links wie bei Vision und PDF.
    public let box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

public enum OCR {
    /// Erkennt Text zeilenweise (Vision, genaue Stufe, Deutsch und Englisch).
    public static func lines(in image: CGImage) async throws -> [TextLine] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { obs in
                guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { return nil }
                return TextLine(text: text, box: obs.boundingBox)
            }
        }.value
    }
}
