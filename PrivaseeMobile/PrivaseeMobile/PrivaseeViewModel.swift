import Foundation
import Photos
import SwiftUI

struct SensitivePhotoModel: Identifiable, Equatable {
    let asset: PHAsset
    let findings: [ThreatFinding]
    let extractedText: String

    var id: String { asset.localIdentifier }
    var type: String { findings.first?.type ?? "Sensitive" }
    var value: String { findings.first?.value ?? "" }

    static func == (lhs: SensitivePhotoModel, rhs: SensitivePhotoModel) -> Bool {
        lhs.id == rhs.id && lhs.findings == rhs.findings
    }
}

@MainActor
final class PrivaseeViewModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var isAnalyzing = false
    @Published var scannedCount = 0
    @Published var totalPhotosToScan = 0
    @Published var lastRunScannedPhotos = 0
    @Published var totalScannedPhotos = 0
    @Published var lastScanDate: Date?
    @Published var hasUnscannedImages = false
    @Published var hasLimitedPhotoAccess = false
    @Published var sensitivePhotos: [SensitivePhotoModel] = []
    @Published var permissionDenied = false
    @Published var selectedPhoto: SensitivePhotoModel?
    @Published var busyAssetID: String?
    @Published var errorMessage: String?
    let geminiAPIKey: String

    private let photoService: PhotoService
    private let visionService: VisionService
    private let geminiService: GeminiService
    private let persistenceService: PersistenceService
    private let imageManipulationService: ImageManipulationService
    private var safeAssetIDs: Set<String>
    private var activeThreatRecords: [ThreatRecord]

    var hasActiveThreats: Bool {
        !sensitivePhotos.isEmpty
    }

    var dynamicPrimaryColor: Color {
        hasActiveThreats ? PrivaseePalette.error : PrivaseePalette.primary
    }

    init(
        photoService: PhotoService = PhotoService(),
        visionService: VisionService? = nil,
        geminiService: GeminiService = GeminiService(),
        persistenceService: PersistenceService = PersistenceService(),
        imageManipulationService: ImageManipulationService? = nil
    ) {
        self.photoService = photoService
        self.visionService = visionService ?? VisionService(photoService: photoService)
        self.geminiService = geminiService
        self.persistenceService = persistenceService
        self.imageManipulationService = imageManipulationService ?? ImageManipulationService(photoService: photoService)
        self.safeAssetIDs = persistenceService.safeAssetIDs
        self.activeThreatRecords = persistenceService.activeThreats
        self.lastRunScannedPhotos = persistenceService.lastRunScannedPhotos
        self.totalScannedPhotos = persistenceService.totalScannedPhotos
        self.lastScanDate = persistenceService.lastScanDate
        self.geminiAPIKey =
            ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ??
            (Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String) ??
            "YOUR_GEMINI_API_KEY"
        super.init()
        restorePersistedThreats()
        refreshPhotoAccessState()
        PHPhotoLibrary.shared().register(self)
        Task {
            await checkForUnscannedImages()
        }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func scanCameraRoll() async {
        errorMessage = nil
        permissionDenied = false

        let granted = await photoService.requestAccess()
        guard granted else {
            permissionDenied = true
            return
        }

        isAnalyzing = true
        scannedCount = 0
        totalPhotosToScan = 0

        let recentAssets = photoService.fetchRecentPhotos(count: 50)
        let knownThreatIDs = Set(activeThreatRecords.map(\.assetID))
        let skippedIDs = safeAssetIDs.union(knownThreatIDs)
        let assets = recentAssets.filter { !skippedIDs.contains($0.localIdentifier) }
        var processedAssetsCount = 0
        totalPhotosToScan = assets.count

        defer {
            isAnalyzing = false
            busyAssetID = nil
        }

        for asset in assets {
            busyAssetID = asset.localIdentifier

            do {
                let textRegions = try await visionService.recognizedTextRegions(from: asset)
                let texts = textRegions.map(\.text)
                let extractedText = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !texts.isEmpty, !extractedText.isEmpty else {
                    markAssetSafe(asset.localIdentifier)
                    continue
                }

                do {
                    let findings = try await geminiService.checkTextForPII(
                        texts: texts,
                        apiKey: geminiAPIKey
                    )
                    persistThreat(
                        ThreatRecord(
                            assetID: asset.localIdentifier,
                            findings: findings
                        ),
                        asset: asset,
                        extractedText: extractedText
                    )
                } catch GeminiServiceError.noSensitiveData {
                    markAssetSafe(asset.localIdentifier)
                    continue
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            processedAssetsCount += 1
            scannedCount = processedAssetsCount
        }

        lastScanDate = Date()
        persistenceService.lastScanDate = lastScanDate
        lastRunScannedPhotos = processedAssetsCount
        persistenceService.lastRunScannedPhotos = lastRunScannedPhotos
        totalScannedPhotos += processedAssetsCount
        persistenceService.totalScannedPhotos = totalScannedPhotos
        await checkForUnscannedImages()
    }

    func loadThumbnail(for asset: PHAsset) async -> UIImage? {
        await photoService.loadThumbnail(
            for: asset,
            targetSize: CGSize(width: 300, height: 300)
        )
    }

    func loadFullScreenImage(for asset: PHAsset) async -> UIImage? {
        try? await photoService.loadDisplayImage(for: asset)
    }

    func selectPhoto(_ photo: SensitivePhotoModel) {
        selectedPhoto = photo
    }

    func blurAndSaveSelectedPhoto() async {
        guard let selectedPhoto else { return }
        busyAssetID = selectedPhoto.id
        errorMessage = nil

        do {
            try await imageManipulationService.blurAndSave(
                asset: selectedPhoto.asset,
                sensitiveValues: selectedPhoto.findings.map(\.value)
            )
            discardThreat(for: selectedPhoto)
        } catch {
            errorMessage = error.localizedDescription
        }

        busyAssetID = nil
    }

    func blurAndSaveAllThreats() async {
        let photosToProcess = sensitivePhotos
        guard !photosToProcess.isEmpty else { return }

        errorMessage = nil
        busyAssetID = nil

        do {
            let requests = photosToProcess.map {
                BlurReplacementRequest(
                    asset: $0.asset,
                    sensitiveValues: $0.findings.map(\.value)
                )
            }

            try await imageManipulationService.blurAndSaveAll(requests)
            handleBulkThreatResolution(photosToProcess)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discardThreat(for photo: SensitivePhotoModel) {
        activeThreatRecords.removeAll { $0.assetID == photo.id }
        persistenceService.activeThreats = activeThreatRecords
        markAssetSafe(photo.id, persistThreats: false)
        sensitivePhotos.removeAll { $0.id == photo.id }

        if selectedPhoto?.id == photo.id {
            selectedPhoto = nil
        }

        Task {
            await checkForUnscannedImages()
        }
    }

    func checkForUnscannedImages() async {
        refreshPhotoAccessState()
        let status = photoService.authorizationStatus
        guard status == .authorized || status == .limited else {
            hasUnscannedImages = false
            return
        }

        let recentAssets = photoService.fetchRecentPhotos(count: 50)
        let knownThreatIDs = Set(activeThreatRecords.map(\.assetID))
        let handledIDs = safeAssetIDs.union(knownThreatIDs)
        hasUnscannedImages = recentAssets.contains { !handledIDs.contains($0.localIdentifier) }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            await self?.checkForUnscannedImages()
        }
    }

    func refreshPhotoAccessState() {
        hasLimitedPhotoAccess = photoService.authorizationStatus == .limited
    }

    private func restorePersistedThreats() {
        guard !activeThreatRecords.isEmpty else { return }

        let assets = photoService.fetchAssets(withLocalIdentifiers: activeThreatRecords.map(\.assetID))
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })

        sensitivePhotos = activeThreatRecords.compactMap { record in
            guard let asset = assetsByID[record.assetID] else { return nil }

            return SensitivePhotoModel(
                asset: asset,
                findings: record.findings,
                extractedText: record.findings.map(\.value).joined(separator: "\n")
            )
        }
    }

    private func persistThreat(_ record: ThreatRecord, asset: PHAsset, extractedText: String) {
        safeAssetIDs.remove(record.assetID)
        persistenceService.safeAssetIDs = safeAssetIDs

        activeThreatRecords.removeAll { $0.assetID == record.assetID }
        activeThreatRecords.append(record)
        persistenceService.activeThreats = activeThreatRecords

        let model = SensitivePhotoModel(
            asset: asset,
            findings: record.findings,
            extractedText: extractedText
        )

        if let index = sensitivePhotos.firstIndex(where: { $0.id == model.id }) {
            sensitivePhotos[index] = model
        } else {
            sensitivePhotos.append(model)
        }
    }

    private func markAssetSafe(_ assetID: String, persistThreats: Bool = true) {
        safeAssetIDs.insert(assetID)
        persistenceService.safeAssetIDs = safeAssetIDs

        if persistThreats {
            activeThreatRecords.removeAll { $0.assetID == assetID }
            persistenceService.activeThreats = activeThreatRecords
        }
    }

    private func handleBulkThreatResolution(_ photos: [SensitivePhotoModel]) {
        let resolvedIDs = Set(photos.map(\.id))

        for id in resolvedIDs {
            safeAssetIDs.insert(id)
        }
        persistenceService.safeAssetIDs = safeAssetIDs

        activeThreatRecords.removeAll { resolvedIDs.contains($0.assetID) }
        persistenceService.activeThreats = activeThreatRecords

        sensitivePhotos.removeAll { resolvedIDs.contains($0.id) }

        if let selectedPhoto, resolvedIDs.contains(selectedPhoto.id) {
            self.selectedPhoto = nil
        }

        Task {
            await checkForUnscannedImages()
        }
    }
}
