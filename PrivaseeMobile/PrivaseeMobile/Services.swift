import CoreGraphics
import CoreImage
import Foundation
import Photos
import UIKit
import Vision

struct ThreatFinding: Codable, Equatable, Hashable {
    let type: String
    let value: String
}

struct ThreatRecord: Codable, Equatable {
    let assetID: String
    let findings: [ThreatFinding]

    init(assetID: String, findings: [ThreatFinding]) {
        self.assetID = assetID
        self.findings = findings
    }

    private enum CodingKeys: String, CodingKey {
        case assetID
        case findings
        case tag
        case sensitiveValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try container.decode(String.self, forKey: .assetID)

        if let findings = try container.decodeIfPresent([ThreatFinding].self, forKey: .findings) {
            self.findings = findings
            return
        }

        let legacyTag = try container.decodeIfPresent(String.self, forKey: .tag) ?? ""
        let legacyValue = try container.decodeIfPresent(String.self, forKey: .sensitiveValue) ?? ""

        if legacyTag.isEmpty || legacyTag.caseInsensitiveCompare("Not Sensitive") == .orderedSame {
            findings = []
        } else {
            findings = [ThreatFinding(type: legacyTag, value: legacyValue)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assetID, forKey: .assetID)
        try container.encode(findings, forKey: .findings)
    }
}

final class PersistenceService {
    private enum Keys {
        static let lastScanDate = "privasee.lastScanDate"
        static let safeAssetIDs = "privasee.safeAssetIDs"
        static let activeThreats = "privasee.activeThreats"
        static let totalScannedPhotos = "privasee.totalScannedPhotos"
        static let lastRunScannedPhotos = "privasee.lastRunScannedPhotos"
    }

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var lastScanDate: Date? {
        get { userDefaults.object(forKey: Keys.lastScanDate) as? Date }
        set { userDefaults.set(newValue, forKey: Keys.lastScanDate) }
    }

    var safeAssetIDs: Set<String> {
        get {
            let values = userDefaults.stringArray(forKey: Keys.safeAssetIDs) ?? []
            return Set(values)
        }
        set {
            userDefaults.set(Array(newValue), forKey: Keys.safeAssetIDs)
        }
    }

    var activeThreats: [ThreatRecord] {
        get {
            guard let data = userDefaults.data(forKey: Keys.activeThreats) else { return [] }
            return (try? decoder.decode([ThreatRecord].self, from: data)) ?? []
        }
        set {
            if let data = try? encoder.encode(newValue) {
                userDefaults.set(data, forKey: Keys.activeThreats)
            }
        }
    }

    var totalScannedPhotos: Int {
        get { userDefaults.integer(forKey: Keys.totalScannedPhotos) }
        set { userDefaults.set(newValue, forKey: Keys.totalScannedPhotos) }
    }

    var lastRunScannedPhotos: Int {
        get { userDefaults.integer(forKey: Keys.lastRunScannedPhotos) }
        set { userDefaults.set(newValue, forKey: Keys.lastRunScannedPhotos) }
    }
}

/// Handles local photo-library access and image loading.
final class PhotoService {
    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAccess() async -> Bool {
        let status = authorizationStatus
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return newStatus == .authorized || newStatus == .limited
        default:
            return false
        }
    }

    func fetchRecentPhotos(count: Int = 50) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = count
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    func loadThumbnail(
        for asset: PHAsset,
        targetSize: CGSize = CGSize(width: 400, height: 400)
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                continuation.resume(returning: image)
            }
        }
    }

    func loadDisplayImage(for asset: PHAsset) async throws -> UIImage {
        let (data, _) = try await loadImageData(for: asset)
        guard let image = UIImage(data: data) else {
            throw PhotoServiceError.imageDataUnavailable
        }
        return image
    }

    func loadImageData(for asset: PHAsset) async throws -> (data: Data, orientation: CGImagePropertyOrientation) {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, orientation, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data else {
                    continuation.resume(throwing: PhotoServiceError.imageDataUnavailable)
                    return
                }

                continuation.resume(returning: (data, orientation))
            }
        }
    }

    func fetchAssets(withLocalIdentifiers identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }

        return identifiers.compactMap { assetsByID[$0] }
    }
}

final class VisionService {
    private let photoService: PhotoService
    private let ciContext = CIContext()

    init(photoService: PhotoService = PhotoService()) {
        self.photoService = photoService
    }

    func extractText(from asset: PHAsset) async throws -> String {
        let regions = try await recognizedTextRegions(from: asset)
        return regions
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func recognizedTextRegions(from asset: PHAsset) async throws -> [RecognizedTextRegion] {
        let (data, orientation) = try await photoService.loadImageData(for: asset)
        guard
            let ciImage = CIImage(data: data),
            let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
        else {
            throw VisionServiceError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let regions = observations.compactMap { observation -> RecognizedTextRegion? in
                    guard let candidate = observation.topCandidates(1).first else {
                        return nil
                    }

                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        return nil
                    }

                    return RecognizedTextRegion(
                        text: text,
                        boundingBox: observation.boundingBox
                    )
                }

                continuation.resume(returning: regions)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Sends OCR text directly to Gemini. Raw images never leave the device.
final class GeminiService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func checkTextForPII(texts: [String], apiKey: String) async throws -> [ThreatFinding] {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty, cleanedKey != "YOUR_GEMINI_API_KEY" else {
            throw GeminiServiceError.missingAPIKey
        }

        let normalizedTexts = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedTexts.isEmpty else {
            throw GeminiServiceError.noSensitiveData
        }

        guard var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent") else {
            throw GeminiServiceError.invalidRequest
        }
        components.queryItems = [URLQueryItem(name: "key", value: cleanedKey)]

        guard let url = components.url else {
            throw GeminiServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GeminiGenerateContentRequest(
                contents: [
                    .init(parts: [
                        .init(text: """
                        Analyze the following OCR text array and determine which entries contain PII such as SSN, credit card number, address, phone number, passport number, driver's license number, account number, or similar sensitive identifiers.
                        Reply strictly as JSON.
                        If sensitive text exists, return an array like [{"type":"SSN","value":"123-45-6789"},{"type":"Address","value":"1 Main St"}].
                        If none of the entries are sensitive, return [].
                        Do not include markdown formatting or extra text.
                        OCR text array: \(jsonArrayString(from: normalizedTexts))
                        """)
                    ])
                ],
                generationConfig: .init(
                    responseMimeType: "application/json",
                    temperature: 0
                )
            )
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw GeminiServiceError.timedOut
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiServiceError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw GeminiServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        let payload = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        guard
            let rawContent = payload.candidates.first?.content.parts.first(where: { $0.text != nil })?.text
        else {
            throw GeminiServiceError.invalidResponse
        }

        let jsonString = extractJSONArrayOrObject(from: rawContent)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw GeminiServiceError.invalidResponse
        }

        let findings = try decodeThreatFindings(from: jsonData)
            .map {
                ThreatFinding(
                    type: $0.type.trimmingCharacters(in: .whitespacesAndNewlines),
                    value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter {
                !$0.type.isEmpty &&
                $0.type.caseInsensitiveCompare("Not Sensitive") != .orderedSame &&
                !$0.value.isEmpty
            }

        guard !findings.isEmpty else {
            throw GeminiServiceError.noSensitiveData
        }

        return deduplicated(findings)
    }

    private func extractJSONArrayOrObject(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.first == "["
            && trimmed.last == "]")
            || (trimmed.first == "{"
                && trimmed.last == "}") {
            return trimmed
        }

        if let firstBracket = trimmed.firstIndex(of: "["),
           let lastBracket = trimmed.lastIndex(of: "]") {
            return String(trimmed[firstBracket...lastBracket])
        }

        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            return String(trimmed[firstBrace...lastBrace])
        }

        return trimmed
    }

    private func decodeThreatFindings(from data: Data) throws -> [PIIResult] {
        if let array = try? JSONDecoder().decode([PIIResult].self, from: data) {
            return array
        }

        let single = try JSONDecoder().decode(PIIResult.self, from: data)
        return [single]
    }

    private func jsonArrayString(from values: [String]) -> String {
        guard
            let data = try? JSONEncoder().encode(values),
            let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }

    private func deduplicated(_ findings: [ThreatFinding]) -> [ThreatFinding] {
        var seen = Set<ThreatFinding>()
        return findings.filter { seen.insert($0).inserted }
    }
}

final class ImageManipulationService {
    private let photoService: PhotoService
    private let visionService: VisionService
    private let ciContext = CIContext()

    init(
        photoService: PhotoService = PhotoService(),
        visionService: VisionService? = nil
    ) {
        self.photoService = photoService
        self.visionService = visionService ?? VisionService(photoService: photoService)
    }

    func blurAndSave(asset: PHAsset, sensitiveValues: [String]) async throws {
        let partiallyBlurredImage = try await renderBlurredImage(
            for: asset,
            sensitiveValues: sensitiveValues
        )

        try await saveBlurredImages([partiallyBlurredImage], deleting: [asset])
    }

    func blurAndSaveAll(_ requests: [BlurReplacementRequest]) async throws {
        guard !requests.isEmpty else { return }

        var blurredImages: [UIImage] = []
        blurredImages.reserveCapacity(requests.count)

        for request in requests {
            let image = try await renderBlurredImage(
                for: request.asset,
                sensitiveValues: request.sensitiveValues
            )
            blurredImages.append(image)
        }

        try await saveBlurredImages(blurredImages, deleting: requests.map(\.asset))
    }

    private func renderBlurredImage(
        for asset: PHAsset,
        sensitiveValues: [String]
    ) async throws -> UIImage {
        let (data, orientation) = try await photoService.loadImageData(for: asset)
        guard let ciImage = CIImage(data: data) else {
            throw ImageManipulationError.invalidImage
        }

        let textRegions = try await visionService.recognizedTextRegions(from: asset)
        let blurRegions = matchingRegions(
            for: sensitiveValues,
            in: textRegions
        )

        guard !blurRegions.isEmpty else {
            throw ImageManipulationError.noBlurRegionsFound
        }

        guard let filter = CIFilter(name: "CIGaussianBlur") else {
            throw ImageManipulationError.filterFailed
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(18, forKey: kCIInputRadiusKey)

        guard let blurredImage = filter.outputImage?.cropped(to: ciImage.extent) else {
            throw ImageManipulationError.filterFailed
        }

        guard let maskImage = makeMaskImage(for: blurRegions, imageExtent: ciImage.extent) else {
            throw ImageManipulationError.renderFailed
        }

        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else {
            throw ImageManipulationError.filterFailed
        }

        blendFilter.setValue(blurredImage, forKey: kCIInputImageKey)
        blendFilter.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(maskImage, forKey: kCIInputMaskImageKey)

        guard let outputImage = blendFilter.outputImage?.cropped(to: ciImage.extent) else {
            throw ImageManipulationError.filterFailed
        }

        guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            throw ImageManipulationError.renderFailed
        }

        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation.uiImageOrientation)
    }

    private func saveBlurredImages(
        _ images: [UIImage],
        deleting assets: [PHAsset]
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ImageManipulationError.saveFailed)
                }
            }
        }
    }

    private func matchingRegions(
        for sensitiveValues: [String],
        in regions: [RecognizedTextRegion]
    ) -> [RecognizedTextRegion] {
        let normalizedTargets = sensitiveValues
            .map(normalizeForMatch)
            .filter { !$0.isEmpty }

        let targetTokens = Set(
            sensitiveValues
                .flatMap {
                    $0.components(separatedBy: CharacterSet.alphanumerics.inverted)
                }
                .map(normalizeForMatch)
                .filter { $0.count >= 4 }
        )

        guard !normalizedTargets.isEmpty && !targetTokens.isEmpty || !normalizedTargets.isEmpty else {
            return []
        }

        var matched: [RecognizedTextRegion] = []
        var seenTexts = Set<String>()

        for region in regions {
            let normalizedRegion = normalizeForMatch(region.text)
            guard !normalizedRegion.isEmpty else { continue }

            let fullMatch = normalizedTargets.contains {
                normalizedRegion.contains($0) || $0.contains(normalizedRegion)
            }
            let tokenMatch = targetTokens.contains {
                normalizedRegion.contains($0) || $0.contains(normalizedRegion)
            }

            guard fullMatch || tokenMatch else { continue }

            if seenTexts.insert(region.text + "\(region.boundingBox)").inserted {
                matched.append(region)
            }
        }

        return matched
    }

    private func normalizeForMatch(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func makeMaskImage(
        for regions: [RecognizedTextRegion],
        imageExtent: CGRect
    ) -> CIImage? {
        let background = CIImage(color: .clear).cropped(to: imageExtent)
        let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        return regions.reduce(background) { partialMask, region in
            let rect = expandedRect(
                from: region.boundingBox,
                imageExtent: imageExtent
            )
            let rectImage = CIImage(color: white).cropped(to: rect)

            guard let composite = CIFilter(
                name: "CISourceOverCompositing",
                parameters: [
                    kCIInputImageKey: rectImage,
                    kCIInputBackgroundImageKey: partialMask
                ]
            )?.outputImage else {
                return partialMask
            }

            return composite.cropped(to: imageExtent)
        }
    }

    private func expandedRect(
        from normalizedBox: CGRect,
        imageExtent: CGRect
    ) -> CGRect {
        let width = imageExtent.width
        let height = imageExtent.height
        var rect = CGRect(
            x: imageExtent.minX + (normalizedBox.minX * width),
            y: imageExtent.minY + (normalizedBox.minY * height),
            width: normalizedBox.width * width,
            height: normalizedBox.height * height
        )

        let horizontalInset = max(rect.width * 0.08, 8)
        let verticalInset = max(rect.height * 0.35, 10)
        rect = rect.insetBy(dx: -horizontalInset, dy: -verticalInset)

        return rect.intersection(imageExtent)
    }
}

struct RecognizedTextRegion {
    let text: String
    let boundingBox: CGRect
}

struct BlurReplacementRequest {
    let asset: PHAsset
    let sensitiveValues: [String]
}

private struct GeminiGenerateContentRequest: Encodable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
}

private struct GeminiContent: Encodable {
    let parts: [GeminiPart]
}

private struct GeminiPart: Encodable {
    let text: String?
}

private struct GeminiGenerationConfig: Encodable {
    let responseMimeType: String
    let temperature: Double
}

private struct GeminiGenerateContentResponse: Decodable {
    let candidates: [GeminiCandidate]
}

private struct GeminiCandidate: Decodable {
    let content: GeminiResponseContent
}

private struct GeminiResponseContent: Decodable {
    let parts: [GeminiResponsePart]
}

private struct GeminiResponsePart: Decodable {
    let text: String?
}

private struct PIIResult: Decodable {
    let type: String
    let value: String
}

enum PhotoServiceError: LocalizedError {
    case imageDataUnavailable

    var errorDescription: String? {
        switch self {
        case .imageDataUnavailable:
            return "Failed to load image data from the photo library."
        }
    }
}

enum VisionServiceError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The selected asset could not be converted into an image for OCR."
        }
    }
}

enum GeminiServiceError: LocalizedError {
    case missingAPIKey
    case invalidRequest
    case invalidResponse
    case httpError(statusCode: Int)
    case noSensitiveData
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Set your Gemini API key in the view model before scanning."
        case .invalidRequest:
            return "The Gemini request could not be created."
        case .invalidResponse:
            return "Gemini returned an unexpected response format."
        case .httpError(let statusCode):
            return "Gemini request failed with status code \(statusCode)."
        case .noSensitiveData:
            return "No sensitive text was detected."
        case .timedOut:
            return "Gemini took too long to respond and this photo was skipped."
        }
    }
}

enum ImageManipulationError: LocalizedError {
    case invalidImage
    case filterFailed
    case renderFailed
    case saveFailed
    case noBlurRegionsFound

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The photo could not be loaded for local redaction."
        case .filterFailed:
            return "The local blur filter could not be applied."
        case .renderFailed:
            return "The redacted image could not be rendered."
        case .saveFailed:
            return "The redacted photo could not be saved."
        case .noBlurRegionsFound:
            return "Privasee could not find the sensitive text region to blur."
        }
    }
}

private extension CGImagePropertyOrientation {
    var uiImageOrientation: UIImage.Orientation {
        switch self {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
