import Photos
import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = PrivaseeViewModel()
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var activeTab: AppTab = .scan
    @State private var showingSecureAllConfirmation = false

    var body: some View {
        ZStack {
            PrivaseePalette.background
                .ignoresSafeArea()

            Group {
                switch activeTab {
                case .scan:
                    DashboardView(
                        viewModel: viewModel,
                        thumbnails: thumbnails,
                        onThumbnailNeeded: loadThumbnail
                    )
                case .threats:
                    ScrollView(showsIndicators: false) {
                        ThreatsGridView(
                            viewModel: viewModel,
                            thumbnails: thumbnails,
                            onThumbnailNeeded: loadThumbnail,
                            onSecureAllTapped: {
                                showingSecureAllConfirmation = true
                            }
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 32)
                    }
                case .settings:
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 20) {
                            if viewModel.hasLimitedPhotoAccess {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Photo Access")
                                        .font(.system(size: 12, weight: .bold))
                                        .tracking(1.8)
                                        .foregroundStyle(PrivaseePalette.onSurfaceVariant)

                                    Button {
                                        presentLimitedLibraryPicker()
                                    } label: {
                                        Text("Update Current Selection")
                                            .font(.system(size: 15, weight: .heavy))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 16)
                                            .background(viewModel.dynamicPrimaryColor)
                                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    }
                                    .buttonStyle(PressScaleButtonStyle())

                                    Text("Choose which photos Privasee can currently access without changing full-library permission.")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(PrivaseePalette.onSurfaceVariant.opacity(0.72))
                                }
                                .padding(20)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                                )
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: viewModel.hasActiveThreats)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomNavBar(activeTab: $activeTab, accentColor: viewModel.dynamicPrimaryColor)
        }
        .task {
            viewModel.refreshPhotoAccessState()
            await viewModel.checkForUnscannedImages()
        }
        .preferredColorScheme(.dark)
        .alert("Photo Access Required", isPresented: $viewModel.permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Privasee needs access to your photo library to scan and save privacy-protected images locally.")
        }
        .alert("Secure All Threats?", isPresented: $showingSecureAllConfirmation) {
            Button("Blur & Replace All", role: .destructive) {
                Task { await viewModel.blurAndSaveAllThreats() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Privasee will locally blur the sensitive text in every flagged photo, save protected replacements, and request deletion of the originals.")
        }
        .fullScreenCover(isPresented: isPhotoViewerPresented) {
            FullScreenPhotoViewer(
                viewModel: viewModel,
                thumbnails: thumbnails,
                selectedPhotoId: selectedPhotoIDBinding
            )
            .preferredColorScheme(.dark)
        }
    }

    private var isPhotoViewerPresented: Binding<Bool> {
        Binding(
            get: { viewModel.selectedPhoto != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.selectedPhoto = nil
                }
            }
        )
    }

    private var selectedPhotoIDBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedPhoto?.id },
            set: { newID in
                guard let newID else {
                    viewModel.selectedPhoto = nil
                    return
                }

                viewModel.selectedPhoto = viewModel.sensitivePhotos.first { $0.id == newID }
            }
        )
    }

    private func loadThumbnail(for asset: PHAsset) async {
        guard thumbnails[asset.localIdentifier] == nil else { return }
        if let image = await viewModel.loadThumbnail(for: asset) {
            thumbnails[asset.localIdentifier] = image
        }
    }

    private func presentLimitedLibraryPicker() {
        guard let controller = topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    private func topViewController() -> UIViewController? {
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let rootController = activeScene?
            .windows
            .first(where: \.isKeyWindow)?
            .rootViewController

        var current = rootController
        while let presented = current?.presentedViewController {
            current = presented
        }
        return current
    }
}

struct DashboardView: View {
    @ObservedObject var viewModel: PrivaseeViewModel
    let thumbnails: [String: UIImage]
    let onThumbnailNeeded: (PHAsset) async -> Void

    private let statsColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private var progress: CGFloat {
        guard viewModel.totalPhotosToScan > 0 else { return 0 }
        return min(CGFloat(viewModel.scannedCount) / CGFloat(viewModel.totalPhotosToScan), 1)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                // Security Status Text
                VStack(alignment: .leading, spacing: 8) {
                    Text("SECURITY STATUS")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(2.2)
                        .foregroundStyle(PrivaseePalette.onSurfaceVariant)

                    (
                        Text("Your digital life is ")
                            .foregroundStyle(.white)
                        + Text(viewModel.hasActiveThreats ? "at risk" : "shielded.")
                            .foregroundStyle(viewModel.dynamicPrimaryColor)
                    )
                    .font(.system(size: 42, weight: .heavy))
                    .tracking(-1.2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 16) // Small breathing room right below the safe area

                HeroScanCard(viewModel: viewModel, progress: progress)

                LazyVGrid(columns: statsColumns, spacing: 16) {
                    StatsCard(
                        icon: "exclamationmark.shield.fill",
                        iconColor: viewModel.dynamicPrimaryColor,
                        eyebrow: "Threats",
                        title: "Action Needed",
                        titleSize: 16,
                        badge: viewModel.sensitivePhotos.isEmpty ? "0 RISKS" : "\(viewModel.sensitivePhotos.count) RISKS",
                        badgeColor: viewModel.dynamicPrimaryColor
                    )

                    StatsCard(
                        icon: "lock.fill",
                        iconColor: viewModel.dynamicPrimaryColor,
                        eyebrow: "Scanned",
                        title: "\(viewModel.lastRunScannedPhotos) Photos",
                        titleSize: 22,
                        badge: nil,
                        badgeColor: nil
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .animation(.easeInOut(duration: 0.35), value: viewModel.hasActiveThreats)
        .onAppear {
            Task { await viewModel.checkForUnscannedImages() }
        }
    }
}

struct ThreatsGridView: View {
    @ObservedObject var viewModel: PrivaseeViewModel
    let thumbnails: [String: UIImage]
    let onThumbnailNeeded: (PHAsset) async -> Void
    let onSecureAllTapped: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var threatAccentColor: Color {
        viewModel.dynamicPrimaryColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Detected Threats")
                    .font(.system(size: 34, weight: .heavy))
                    .tracking(-1.2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(threatAccentColor)
                            .frame(width: 7, height: 7)
                        Text("\(viewModel.sensitivePhotos.count) HIGH RISK ITEMS")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(threatAccentColor)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(threatAccentColor.opacity(0.10))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(threatAccentColor.opacity(0.20), lineWidth: 1)
                    )

                    if !viewModel.sensitivePhotos.isEmpty {
                        Button {
                            onSecureAllTapped()
                        } label: {
                            Text("Secure All")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.1)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(viewModel.dynamicPrimaryColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .disabled(viewModel.busyAssetID != nil)
                    }
                }
            }
            .padding(.horizontal, 16)

            if let errorMessage = viewModel.errorMessage {
                InlineErrorCard(message: errorMessage)
                    .padding(.horizontal, 16)
            }

            if viewModel.sensitivePhotos.isEmpty {
                PlaceholderPanel(
                    accentColor: viewModel.dynamicPrimaryColor,
                    eyebrow: "Threat Feed",
                    title: "No active threats detected.",
                    subtitle: "Run a scan to populate this grid with sensitive photo findings."
                )
                .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(viewModel.sensitivePhotos) { photo in
                        ThreatCard(
                            photo: photo,
                            image: thumbnails[photo.id],
                            accentColor: viewModel.dynamicPrimaryColor
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectPhoto(photo)
                        }
                        .task {
                            await onThumbnailNeeded(photo.asset)
                        }
                    }
                }

                Text("Items will be processed locally and saved as privacy-protected copies.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PrivaseePalette.onSurfaceVariant.opacity(0.65))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: viewModel.hasActiveThreats)
    }
}

struct FullScreenPhotoViewer: View {
    @ObservedObject var viewModel: PrivaseeViewModel
    @State private var loadedImages: [String: UIImage]
    @Binding var selectedPhotoId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var verticalOffset: CGFloat = 0
    @State private var isDetailsExpanded = false

    init(
        viewModel: PrivaseeViewModel,
        thumbnails: [String: UIImage],
        selectedPhotoId: Binding<String?>
    ) {
        self.viewModel = viewModel
        self._loadedImages = State(initialValue: [:])
        self._selectedPhotoId = selectedPhotoId
    }

    private var currentPhoto: SensitivePhotoModel? {
        guard let selectedPhotoId else { return nil }
        return viewModel.sensitivePhotos.first { $0.id == selectedPhotoId }
    }

    private var currentPhotoIsBusy: Bool {
        guard let currentPhoto else { return false }
        return viewModel.busyAssetID == currentPhoto.id
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            PrivaseePalette.background
                .ignoresSafeArea()

            TabView(selection: $selectedPhotoId) {
                ForEach(viewModel.sensitivePhotos) { photo in
                    GeometryReader { proxy in
                        ZStack {
                            Group {
                                if let image = loadedImages[photo.id] {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                } else {
                                    ProgressView()
                                        .tint(.white)
                                }
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                        .task {
                            await loadImageIfNeeded(for: photo)
                        }
                    }
                    .tag(photo.id as String?)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: max(verticalOffset, 0))
            .simultaneousGesture(viewerDragGesture)
            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: verticalOffset)

            if let currentPhoto {
                bottomOverlay(for: currentPhoto)
            }
        }
        .onChange(of: selectedPhotoId) { _, newValue in
            if newValue == nil {
                dismiss()
            } else {
                isDetailsExpanded = false
                verticalOffset = 0
            }
        }
    }

    @ViewBuilder
    private func bottomOverlay(for photo: SensitivePhotoModel) -> some View {
        VStack(spacing: 0) {
            if isDetailsExpanded {
                VStack(alignment: .leading, spacing: 18) {
                    actionButtons(for: photo)

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(photo.findings.enumerated()), id: \.offset) { index, finding in
                            VStack(alignment: .leading, spacing: 14) {
                                DetailTile(
                                    label: photo.findings.count == 1 ? "Threat Type" : "Threat Type \(index + 1)",
                                    value: finding.type
                                )
                                DetailTile(
                                    label: photo.findings.count == 1 ? "Detected Value" : "Detected Value \(index + 1)",
                                    value: finding.value
                                )
                            }
                        }
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                actionButtons(for: photo)
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: isDetailsExpanded)
    }

    private func actionButtons(for photo: SensitivePhotoModel) -> some View {
        HStack(spacing: 12) {
            if let currentPhoto {
                Button {
                    Task { await viewModel.blurAndSaveSelectedPhoto() }
                } label: {
                    HStack(spacing: 10) {
                        if currentPhotoIsBusy {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "drop.triangle.fill")
                                .font(.system(size: 15, weight: .bold))
                        }

                        Text(currentPhotoIsBusy ? "Replacing..." : "Blur & Replace")
                            .font(.system(size: 15, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(PrivaseePalette.actionBlue)
                    .clipShape(Capsule())
                }
                .buttonStyle(PressScaleButtonStyle())
                .disabled(currentPhotoIsBusy)

                Button {
                    viewModel.discardThreat(for: currentPhoto)
                } label: {
                    Text("Mark Not Sensitive")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                .buttonStyle(PressScaleButtonStyle())
            }
        }
    }

    private var viewerDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }

                if isDetailsExpanded {
                    return
                }

                if value.translation.height > 0 {
                    verticalOffset = value.translation.height
                }
            }
            .onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }

                let verticalTranslation = value.translation.height

                if isDetailsExpanded {
                    if verticalTranslation > 70 {
                        isDetailsExpanded = false
                    } else if verticalTranslation < -30 {
                        isDetailsExpanded = true
                    }
                } else {
                    if verticalTranslation > 120 {
                        selectedPhotoId = nil
                        dismiss()
                    } else if verticalTranslation < -70 {
                        isDetailsExpanded = true
                    }
                }

                verticalOffset = 0
            }
    }

    private func loadImageIfNeeded(for photo: SensitivePhotoModel) async {
        if let image = await viewModel.loadFullScreenImage(for: photo.asset) {
            loadedImages[photo.id] = image
        } else if let fallback = await viewModel.loadThumbnail(for: photo.asset) {
            loadedImages[photo.id] = fallback
        }
    }
}

struct HeroScanCard: View {
    @ObservedObject var viewModel: PrivaseeViewModel
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                if viewModel.isAnalyzing {
                    Circle()
                        .stroke(.white.opacity(0.06), lineWidth: 4)
                        .frame(width: 192, height: 192)

                    Circle()
                        .trim(from: 0, to: max(progress, 0.02))
                        .stroke(
                            AngularGradient(
                                colors: [
                                    viewModel.dynamicPrimaryColor.opacity(0.35),
                                    viewModel.dynamicPrimaryColor,
                                    viewModel.dynamicPrimaryColor.opacity(0.7)
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 192, height: 192)
                        .shadow(color: viewModel.dynamicPrimaryColor.opacity(0.35), radius: 10)
                }

                ZStack {
                    Circle()
                        .fill(Color.black)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [viewModel.dynamicPrimaryColor.opacity(0.08), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    VStack(spacing: 10) {
                        Image(systemName: heroIconName)
                            .font(.system(size: 46, weight: .medium))
                            .foregroundStyle(heroIconColor)
                            .symbolEffect(.pulse.byLayer, options: .repeating, value: viewModel.isAnalyzing)

                        if viewModel.isAnalyzing {
                            Text("\(min(viewModel.scannedCount, viewModel.totalPhotosToScan))")
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }

                    VStack {
                        LinearGradient(
                            colors: [.clear, viewModel.dynamicPrimaryColor.opacity(0.10), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 70)
                        .offset(y: viewModel.isAnalyzing ? -50 : -120)
                        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false), value: viewModel.isAnalyzing)
                        Spacer()
                    }
                }
                .frame(width: 160, height: 160)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                Text("Scan Camera Roll")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)

                Text(statusText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PrivaseePalette.onSurfaceVariant)
            }

            Button {
                Task { await viewModel.scanCameraRoll() }
            } label: {
                Text(viewModel.isAnalyzing ? "Scanning..." : "Start Local Scan")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(PrivaseePalette.onPrimaryContainer)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(viewModel.dynamicPrimaryColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(viewModel.isAnalyzing)
        }
        .padding(28)
        .background(.ultraThinMaterial.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 32, y: 18)
    }

    private var statusText: String {
        if viewModel.isAnalyzing {
            let total = viewModel.totalPhotosToScan
            guard total > 0 else { return "Preparing scan..." }
            let current = min(viewModel.scannedCount + 1, total)
            return "Analyzing photo \(current) of \(total)..."
        }

        if let lastScanDate = viewModel.lastScanDate {
            return "Last scan on \(lastScanDate.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year(.twoDigits).hour().minute()))"
        }

        return "Ready to inspect your accessible photos entirely on-device."
    }

    private var heroIconName: String {
        if viewModel.isAnalyzing {
            return "sensor.tag.radiowaves.forward.fill"
        }

        if viewModel.lastScanDate != nil {
            return "checkmark.circle.fill"
        }

        return "viewfinder"
    }

    private var heroIconColor: Color {
        viewModel.dynamicPrimaryColor
    }
}

struct StatsCard: View {
    let icon: String
    let iconColor: Color
    let eyebrow: String
    let title: String
    let titleSize: CGFloat
    let badge: String?
    let badgeColor: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(iconColor)

                Spacer()

                if let badge, let badgeColor {
                    Text(badge)
                        .font(.system(size: 11, weight: .heavy))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(badgeColor.opacity(0.10))
                        .foregroundStyle(badgeColor)
                        .clipShape(Capsule())
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(PrivaseePalette.onSurfaceVariant)
                Text(title)
                    .font(.system(size: titleSize, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .padding(20)
        .frame(height: 164)
        .background(PrivaseePalette.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.05), lineWidth: 1)
        )
    }
}

struct ThreatCard: View {
    let photo: SensitivePhotoModel
    let image: UIImage?
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.width)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(PrivaseePalette.surfaceContainerHighest)
                            .frame(width: geo.size.width, height: geo.size.width)
                            .overlay {
                                ProgressView()
                                    .tint(.white)
                            }
                            .clipped()
                    }
                }

                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(PrivaseePalette.error)
                            .frame(width: 6, height: 6)
                        Text(photo.type.uppercased())
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(6)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
    }
}

struct DetailTile: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(PrivaseePalette.outline)
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.05), lineWidth: 1)
        )
    }
}

struct PlaceholderPanel: View {
    let accentColor: Color
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(2)
                .foregroundStyle(accentColor)
            Text(title)
                .font(.system(size: 34, weight: .heavy))
                .tracking(-1)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PrivaseePalette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(.ultraThinMaterial.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct InlineErrorCard: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PrivaseePalette.error)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct BottomNavBar: View {
    @Binding var activeTab: AppTab
    let accentColor: Color

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    activeTab = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: activeTab == tab ? .bold : .medium))
                        Text(tab.label)
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.0)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    .foregroundStyle(activeTab == tab ? accentColor : PrivaseePalette.onSurfaceVariant)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(activeTab == tab ? accentColor.opacity(0.10) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .opacity(activeTab == tab ? 1 : 0.62)
                }
                .buttonStyle(PressScaleButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.regularMaterial.opacity(0.92))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.white.opacity(0.05))
                        .frame(height: 1)
                }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case scan
    case threats
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scan: return "SCAN"
        case .threats: return "THREATS"
        case .settings: return "SETTINGS"
        }
    }

    var symbol: String {
        switch self {
        case .scan: return "viewfinder"
        case .threats: return "exclamationmark.shield.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

enum PrivaseePalette {
    static let background = Color(hex: "#0A0A0B")
    static let surfaceDim = Color(hex: "#131315")
    static let surfaceContainer = Color(hex: "#121212")
    static let surfaceContainerHighest = Color(hex: "#2C2C2E")
    static let onSurfaceVariant = Color(hex: "#C0C6D6")
    static let outline = Color(hex: "#8B91A0")
    static let primary = Color(hex: "#AAC7FF")
    static let actionBlue = Color(hex: "#0A84FF")
    static let error = Color(hex: "#FFB4AB")
    static let success = Color(hex: "#34C759")
    static let onPrimaryContainer = Color(hex: "#002957")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64

        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
