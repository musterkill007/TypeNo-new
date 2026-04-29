import CoreGraphics
import Foundation

public struct ScreenGeometry: Equatable {
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let safeAreaTop: CGFloat
    public let auxiliaryTopLeftArea: CGRect
    public let auxiliaryTopRightArea: CGRect

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect = .zero,
        auxiliaryTopRightArea: CGRect = .zero
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }
}

public enum OverlayGeometry {
    public static func compactIslandFrame(panelSize: CGSize, screen: ScreenGeometry) -> CGRect {
        let horizontalMargin: CGFloat = 8
        let topVisibleGap: CGFloat = 8

        let centeredX = screen.frame.midX - panelSize.width / 2
        let minX = screen.visibleFrame.minX + horizontalMargin
        let maxX = screen.visibleFrame.maxX - panelSize.width - horizontalMargin
        let x = min(max(centeredX, minX), maxX)

        let hasNotchSafeArea = screen.safeAreaTop > 0
            && !screen.auxiliaryTopLeftArea.isEmpty
            && !screen.auxiliaryTopRightArea.isEmpty
        let safeTopBoundary = min(
            screen.visibleFrame.maxY,
            screen.frame.maxY - screen.safeAreaTop
        )
        let y = hasNotchSafeArea
            ? safeTopBoundary - panelSize.height
            : screen.visibleFrame.maxY - panelSize.height - topVisibleGap

        return CGRect(
            x: x,
            y: y,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    public static func notchAttachedIslandFrame(panelSize: CGSize, screen: ScreenGeometry) -> CGRect {
        guard screen.safeAreaTop > 0,
              !screen.auxiliaryTopLeftArea.isEmpty,
              !screen.auxiliaryTopRightArea.isEmpty else {
            return compactIslandFrame(panelSize: panelSize, screen: screen)
        }

        let horizontalMargin: CGFloat = 8
        let centeredX = screen.frame.midX - panelSize.width / 2
        let minX = screen.visibleFrame.minX + horizontalMargin
        let maxX = screen.visibleFrame.maxX - panelSize.width - horizontalMargin
        let x = min(max(centeredX, minX), maxX)

        return CGRect(
            x: x,
            y: screen.frame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    public static func notchAttachmentHeight(for screen: ScreenGeometry) -> CGFloat {
        guard screen.safeAreaTop > 0,
              !screen.auxiliaryTopLeftArea.isEmpty,
              !screen.auxiliaryTopRightArea.isEmpty else {
            return 0
        }

        let auxiliaryHeight = min(screen.auxiliaryTopLeftArea.height, screen.auxiliaryTopRightArea.height)
        return max(0, min(screen.safeAreaTop, auxiliaryHeight))
    }

    public static func collapsedRecordingFrame(panelSize: CGSize, screen: ScreenGeometry) -> CGRect {
        guard screen.safeAreaTop > 0,
              !screen.auxiliaryTopLeftArea.isEmpty,
              !screen.auxiliaryTopRightArea.isEmpty else {
            return compactIslandFrame(panelSize: panelSize, screen: screen)
        }

        let x = screen.frame.midX - panelSize.width / 2
        let auxiliaryMinY = max(screen.auxiliaryTopLeftArea.minY, screen.auxiliaryTopRightArea.minY)
        let auxiliaryMaxY = min(screen.auxiliaryTopLeftArea.maxY, screen.auxiliaryTopRightArea.maxY)
        let y: CGFloat

        if panelSize.height <= auxiliaryMaxY - auxiliaryMinY {
            y = auxiliaryMinY + ((auxiliaryMaxY - auxiliaryMinY) - panelSize.height) / 2
        } else {
            y = auxiliaryMaxY - panelSize.height
        }

        return CGRect(
            x: x,
            y: y,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    public static func recordingHoverRegionContains(
        _ point: CGPoint,
        collapsedFrame: CGRect,
        expandedFrame: CGRect,
        padding: CGFloat = 8
    ) -> Bool {
        let paddedCollapsedFrame = collapsedFrame.insetBy(dx: -padding, dy: -padding)
        let paddedExpandedFrame = expandedFrame.insetBy(dx: -padding, dy: -padding)
        if paddedCollapsedFrame.contains(point) || paddedExpandedFrame.contains(point) {
            return true
        }

        let bridgeFrame = collapsedFrame.union(expandedFrame).insetBy(dx: -padding, dy: -padding)
        return bridgeFrame.contains(point)
    }
}

public enum CompactIslandMetrics {
    public static let width: CGFloat = 360
    public static let minimumHeight: CGFloat = 44
    public static let collapsedRecordingWidth: CGFloat = 320
    public static let collapsedRecordingSideSlotWidth: CGFloat = 70
    public static let collapsedRecordingHeight: CGFloat = 32
    public static let collapsedPillHeight: CGFloat = 28
    public static let collapsedNotchAttachmentGap: CGFloat = 0
    public static let maximumTextViewportHeight: CGFloat = 108
    public static let maximumHistoryViewportHeight: CGFloat = 260
    public static let historyPanelMinimumWidth: CGFloat = 300
    public static let historyPanelMaximumWidth: CGFloat = 340
    public static let previewPanelMinimumWidth: CGFloat = 260
    public static let previewPanelMaximumWidth: CGFloat = 340

    public static func width(for screen: ScreenGeometry) -> CGFloat {
        let availableWidth = max(240, screen.visibleFrame.width - 16)
        let notchAwareWidth = max(width, collapsedRecordingWidth(for: screen))
        return min(notchAwareWidth, availableWidth)
    }

    public static func collapsedRecordingWidth(for screen: ScreenGeometry) -> CGFloat {
        let availableWidth = max(240, screen.visibleFrame.width - 16)
        let notchGap = topNotchGap(for: screen)
        guard notchGap > 0 else {
            return min(collapsedRecordingWidth, availableWidth)
        }

        let notchAwareWidth = max(
            collapsedRecordingWidth,
            notchGap + collapsedNotchAttachmentGap * 2 + collapsedRecordingSideSlotWidth * 2
        )
        return min(notchAwareWidth, availableWidth)
    }

    public static func collapsedRecordingSpacerWidth(for screen: ScreenGeometry) -> CGFloat {
        let notchGap = topNotchGap(for: screen)
        guard notchGap > 0 else { return 150 }

        return max(96, notchGap + collapsedNotchAttachmentGap * 2)
    }

    public static func historyPanelWidth(forTextLengths textLengths: [Int], screen: ScreenGeometry) -> CGFloat {
        let availableWidth = max(240, screen.visibleFrame.width - 16)
        let notchAnchoredWidth = expandedNotchMinimumWidth(for: screen, sideExtension: 40)
        let maximumWidth = min(
            max(historyPanelMaximumWidth, notchAnchoredWidth),
            availableWidth
        )
        let minimumWidth = min(
            max(historyPanelMinimumWidth, notchAnchoredWidth),
            maximumWidth
        )
        let longestTextLength = CGFloat(textLengths.max() ?? 0)
        let estimatedContentWidth = longestTextLength * 5.6 + 84

        return min(max(estimatedContentWidth, minimumWidth), maximumWidth)
    }

    public static func previewPanelWidth(forTextLength textLength: Int, screen: ScreenGeometry) -> CGFloat {
        let availableWidth = max(240, screen.visibleFrame.width - 16)
        let notchAnchoredWidth = expandedNotchMinimumWidth(for: screen, sideExtension: 40)
        let maximumWidth = min(
            max(previewPanelMaximumWidth, notchAnchoredWidth),
            availableWidth
        )
        let minimumWidth = min(
            max(previewPanelMinimumWidth, notchAnchoredWidth),
            maximumWidth
        )
        let estimatedContentWidth = CGFloat(textLength) * 5.8 + 128

        return min(max(estimatedContentWidth, minimumWidth), maximumWidth)
    }

    public static func historyRowsViewportHeight(forTextLengths textLengths: [Int], panelWidth: CGFloat) -> CGFloat {
        let visibleTextLengths = Array(textLengths.prefix(4))
        guard !visibleTextLengths.isEmpty else { return 0 }

        let textColumnWidth = max(120, panelWidth - 86)
        let charactersPerLine = max(10, Int(textColumnWidth / 6.4))
        let rowHeights = visibleTextLengths.map { textLength -> CGFloat in
            let lineCount = min(2, max(1, Int(ceil(Double(textLength) / Double(charactersPerLine)))))
            return CGFloat(lineCount) * 18 + 18
        }
        let totalSpacing = CGFloat(max(0, visibleTextLengths.count - 1)) * 8

        return min(rowHeights.reduce(0, +) + totalSpacing, maximumHistoryViewportHeight)
    }

    public static func textViewportHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
        min(contentHeight, maximumTextViewportHeight)
    }

    private static func topNotchGap(for screen: ScreenGeometry) -> CGFloat {
        guard screen.safeAreaTop > 0,
              !screen.auxiliaryTopLeftArea.isEmpty,
              !screen.auxiliaryTopRightArea.isEmpty else {
            return 0
        }

        return max(0, screen.auxiliaryTopRightArea.minX - screen.auxiliaryTopLeftArea.maxX)
    }

    private static func expandedNotchMinimumWidth(for screen: ScreenGeometry, sideExtension: CGFloat) -> CGFloat {
        let notchGap = topNotchGap(for: screen)
        guard notchGap > 0 else { return 0 }

        return notchGap + sideExtension * 2
    }
}

public struct TranscriptHistoryItem: Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

public struct TranscriptHistory: Equatable {
    public private(set) var items: [TranscriptHistoryItem] = []
    public let maxCount: Int

    public init(maxCount: Int = 20) {
        self.maxCount = maxCount
    }

    public mutating func record(_ text: String, createdAt: Date = Date()) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        items.insert(TranscriptHistoryItem(text: normalized, createdAt: createdAt), at: 0)
        if items.count > maxCount {
            items.removeLast(items.count - maxCount)
        }
    }
}

public struct OverlayInsets: Equatable {
    public let top: CGFloat
    public let leading: CGFloat
    public let bottom: CGFloat
    public let trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

public struct RecordingOverlayScene: Equatable {
    public let isExpanded: Bool
    public let previewText: String
    public let elapsedText: String

    public init(isExpanded: Bool, previewText: String, elapsedText: String) {
        self.isExpanded = isExpanded
        self.previewText = previewText
        self.elapsedText = elapsedText
    }
}

public struct HistoryOverlayScene: Equatable {
    public let isExpanded: Bool
    public let items: [TranscriptHistoryItem]

    public init(isExpanded: Bool, items: [TranscriptHistoryItem]) {
        self.isExpanded = isExpanded
        self.items = items
    }
}

public enum OverlayScene: Equatable {
    case recording(RecordingOverlayScene)
    case history(HistoryOverlayScene)
}

public struct OverlayMeasurements: Equatable {
    public let previewTextSize: CGSize?
    public let historyRowSizes: [CGSize]
    public let leadingSlotSize: CGSize?
    public let trailingSlotSize: CGSize?

    public init(
        previewTextSize: CGSize? = nil,
        historyRowSizes: [CGSize] = [],
        leadingSlotSize: CGSize? = nil,
        trailingSlotSize: CGSize? = nil
    ) {
        self.previewTextSize = previewTextSize
        self.historyRowSizes = historyRowSizes
        self.leadingSlotSize = leadingSlotSize
        self.trailingSlotSize = trailingSlotSize
    }
}

public struct OverlayLayoutRequest: Equatable {
    public let screen: ScreenGeometry
    public let scene: OverlayScene
    public let measurements: OverlayMeasurements
    public let previousPlan: OverlayLayoutPlan?

    public init(
        screen: ScreenGeometry,
        scene: OverlayScene,
        measurements: OverlayMeasurements = OverlayMeasurements(),
        previousPlan: OverlayLayoutPlan? = nil
    ) {
        self.screen = screen
        self.scene = scene
        self.measurements = measurements
        self.previousPlan = previousPlan
    }
}

public enum OverlayVariant: Equatable {
    case recordingRail
    case recordingPreview
    case historyEntry
    case singleHistory
    case historyList
}

public struct OverlaySlotFrames: Equatable {
    public let leading: CGRect?
    public let primaryText: CGRect?
    public let trailing: CGRect?

    public init(leading: CGRect? = nil, primaryText: CGRect? = nil, trailing: CGRect? = nil) {
        self.leading = leading
        self.primaryText = primaryText
        self.trailing = trailing
    }
}

public struct OverlaySurfacePlan: Equatable {
    public let width: CGFloat
    public let height: CGFloat
    public let attachmentHeight: CGFloat
    public let topCornerRadius: CGFloat
    public let bottomCornerRadius: CGFloat

    public init(
        width: CGFloat,
        height: CGFloat,
        attachmentHeight: CGFloat,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) {
        self.width = width
        self.height = height
        self.attachmentHeight = attachmentHeight
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }
}

public struct OverlayLayoutPlan: Equatable {
    public let variant: OverlayVariant
    public let panelFrame: CGRect
    public let hostFrame: CGRect
    public let contentFrame: CGRect
    public let safeInsets: OverlayInsets
    public let slotFrames: OverlaySlotFrames
    public let surface: OverlaySurfacePlan
    public let viewportHeight: CGFloat?
    public let hitRegions: [CGRect]
    public let islandWidth: CGFloat
    public let collapsedRailWidth: CGFloat
    public let collapsedSpacerWidth: CGFloat
    public let attachmentHeight: CGFloat

    public init(
        variant: OverlayVariant,
        panelFrame: CGRect,
        hostFrame: CGRect,
        contentFrame: CGRect,
        safeInsets: OverlayInsets,
        slotFrames: OverlaySlotFrames,
        surface: OverlaySurfacePlan,
        viewportHeight: CGFloat?,
        hitRegions: [CGRect],
        islandWidth: CGFloat,
        collapsedRailWidth: CGFloat,
        collapsedSpacerWidth: CGFloat,
        attachmentHeight: CGFloat
    ) {
        self.variant = variant
        self.panelFrame = panelFrame
        self.hostFrame = hostFrame
        self.contentFrame = contentFrame
        self.safeInsets = safeInsets
        self.slotFrames = slotFrames
        self.surface = surface
        self.viewportHeight = viewportHeight
        self.hitRegions = hitRegions
        self.islandWidth = islandWidth
        self.collapsedRailWidth = collapsedRailWidth
        self.collapsedSpacerWidth = collapsedSpacerWidth
        self.attachmentHeight = attachmentHeight
    }
}

public enum OverlayLayoutPlanner {
    public static func makePlan(_ request: OverlayLayoutRequest) -> OverlayLayoutPlan {
        switch request.scene {
        case .recording(let scene):
            return recordingPlan(scene: scene, request: request)
        case .history(let scene):
            return historyPlan(scene: scene, request: request)
        }
    }

    private static func recordingPlan(
        scene: RecordingOverlayScene,
        request: OverlayLayoutRequest
    ) -> OverlayLayoutPlan {
        let screen = request.screen
        let attachmentHeight = OverlayGeometry.notchAttachmentHeight(for: screen)
        let railWidth = CompactIslandMetrics.collapsedRecordingWidth(for: screen)
        let spacerWidth = CompactIslandMetrics.collapsedRecordingSpacerWidth(for: screen)
        let islandWidth = CompactIslandMetrics.width(for: screen)

        guard scene.isExpanded else {
            let panelFrame = OverlayGeometry.collapsedRecordingFrame(
                panelSize: CGSize(width: railWidth, height: CompactIslandMetrics.collapsedRecordingHeight),
                screen: screen
            )
            let contentFrame = hostContentFrame(for: panelFrame, screen: screen)
            return OverlayLayoutPlan(
                variant: .recordingRail,
                panelFrame: panelFrame,
                hostFrame: hostFrame(for: panelFrame, screen: screen),
                contentFrame: contentFrame,
                safeInsets: OverlayInsets(leading: 12, trailing: 12),
                slotFrames: collapsedSlotFrames(width: railWidth, height: panelFrame.height),
                surface: OverlaySurfacePlan(
                    width: railWidth,
                    height: panelFrame.height,
                    attachmentHeight: 0,
                    topCornerRadius: 6,
                    bottomCornerRadius: 14
                ),
                viewportHeight: nil,
                hitRegions: [contentFrame.insetBy(dx: -8, dy: -8)],
                islandWidth: islandWidth,
                collapsedRailWidth: railWidth,
                collapsedSpacerWidth: spacerWidth,
                attachmentHeight: attachmentHeight
            )
        }

        let width = previewPanelWidth(
            textLength: scene.previewText.count,
            screen: screen
        )
        let measuredHeight = normalizedMeasuredHeight(request.measurements.previewTextSize?.height)
        let fallbackHeight = estimatedPreviewTextHeight(
            text: scene.previewText,
            width: width
        )
        let viewportHeight = CompactIslandMetrics.textViewportHeight(
            forContentHeight: measuredHeight ?? fallbackHeight
        )
        let bodyHeight = max(
            CompactIslandMetrics.minimumHeight,
            20 + max(18, viewportHeight)
        )
        let height = attachmentHeight + bodyHeight
        let panelFrame = OverlayGeometry.notchAttachedIslandFrame(
            panelSize: CGSize(width: width, height: height),
            screen: screen
        )
        let contentFrame = hostContentFrame(for: panelFrame, screen: screen)
        let safeInsets = OverlayInsets(
            top: attachmentHeight + 10,
            leading: 24,
            bottom: 10,
            trailing: 24
        )

        return OverlayLayoutPlan(
            variant: .recordingPreview,
            panelFrame: panelFrame,
            hostFrame: hostFrame(for: panelFrame, screen: screen),
            contentFrame: contentFrame,
            safeInsets: safeInsets,
            slotFrames: expandedRecordingSlotFrames(
                width: width,
                attachmentHeight: attachmentHeight,
                viewportHeight: viewportHeight
            ),
            surface: OverlaySurfacePlan(
                width: width,
                height: height,
                attachmentHeight: attachmentHeight,
                topCornerRadius: 16,
                bottomCornerRadius: 20
            ),
            viewportHeight: viewportHeight,
            hitRegions: [contentFrame.insetBy(dx: -8, dy: -8)],
            islandWidth: islandWidth,
            collapsedRailWidth: railWidth,
            collapsedSpacerWidth: spacerWidth,
            attachmentHeight: attachmentHeight
        )
    }

    private static func historyPlan(
        scene: HistoryOverlayScene,
        request: OverlayLayoutRequest
    ) -> OverlayLayoutPlan {
        let screen = request.screen
        let attachmentHeight = OverlayGeometry.notchAttachmentHeight(for: screen)
        let railWidth = CompactIslandMetrics.collapsedRecordingWidth(for: screen)
        let spacerWidth = CompactIslandMetrics.collapsedRecordingSpacerWidth(for: screen)
        let islandWidth = CompactIslandMetrics.width(for: screen)

        guard scene.isExpanded else {
            let panelFrame = OverlayGeometry.collapsedRecordingFrame(
                panelSize: CGSize(width: railWidth, height: CompactIslandMetrics.collapsedRecordingHeight),
                screen: screen
            )
            let contentFrame = hostContentFrame(for: panelFrame, screen: screen)
            return OverlayLayoutPlan(
                variant: .historyEntry,
                panelFrame: panelFrame,
                hostFrame: hostFrame(for: panelFrame, screen: screen),
                contentFrame: contentFrame,
                safeInsets: OverlayInsets(leading: 12, trailing: 12),
                slotFrames: collapsedSlotFrames(width: railWidth, height: panelFrame.height),
                surface: OverlaySurfacePlan(
                    width: railWidth,
                    height: panelFrame.height,
                    attachmentHeight: 0,
                    topCornerRadius: 6,
                    bottomCornerRadius: 14
                ),
                viewportHeight: nil,
                hitRegions: [contentFrame.insetBy(dx: -8, dy: -8)],
                islandWidth: islandWidth,
                collapsedRailWidth: railWidth,
                collapsedSpacerWidth: spacerWidth,
                attachmentHeight: attachmentHeight
            )
        }

        let width = historyPanelWidth(
            items: scene.items,
            measurements: request.measurements,
            screen: screen
        )
        let viewportHeight = historyRowsViewportHeight(
            items: scene.items,
            measurements: request.measurements,
            panelWidth: width
        )
        let isSingleHistory = scene.items.count == 1
        let bodyHeight: CGFloat
        if isSingleHistory {
            bodyHeight = 16 + max(30, viewportHeight)
        } else {
            bodyHeight = 20 + 18 + 6 + viewportHeight
        }
        let height = attachmentHeight + bodyHeight
        let panelFrame = OverlayGeometry.notchAttachedIslandFrame(
            panelSize: CGSize(width: width, height: height),
            screen: screen
        )
        let contentFrame = hostContentFrame(for: panelFrame, screen: screen)
        let safeInsets = OverlayInsets(
            top: attachmentHeight + 10,
            leading: 22,
            bottom: 10,
            trailing: 22
        )

        return OverlayLayoutPlan(
            variant: isSingleHistory ? .singleHistory : .historyList,
            panelFrame: panelFrame,
            hostFrame: hostFrame(for: panelFrame, screen: screen),
            contentFrame: contentFrame,
            safeInsets: safeInsets,
            slotFrames: historySlotFrames(
                width: width,
                attachmentHeight: attachmentHeight,
                viewportHeight: viewportHeight,
                isSingleHistory: isSingleHistory
            ),
            surface: OverlaySurfacePlan(
                width: width,
                height: height,
                attachmentHeight: attachmentHeight,
                topCornerRadius: 16,
                bottomCornerRadius: 20
            ),
            viewportHeight: viewportHeight,
            hitRegions: [contentFrame.insetBy(dx: -8, dy: -8)],
            islandWidth: islandWidth,
            collapsedRailWidth: railWidth,
            collapsedSpacerWidth: spacerWidth,
            attachmentHeight: attachmentHeight
        )
    }

    private static func collapsedSlotFrames(width: CGFloat, height: CGFloat) -> OverlaySlotFrames {
        let slotWidth = CompactIslandMetrics.collapsedRecordingSideSlotWidth
        return OverlaySlotFrames(
            leading: CGRect(x: 0, y: 0, width: slotWidth, height: height),
            primaryText: CGRect(x: slotWidth, y: 0, width: max(0, width - slotWidth * 2), height: height),
            trailing: CGRect(x: max(0, width - slotWidth), y: 0, width: slotWidth, height: height)
        )
    }

    private static func expandedRecordingSlotFrames(
        width: CGFloat,
        attachmentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> OverlaySlotFrames {
        let horizontalPadding: CGFloat = 24
        let leadingWidth: CGFloat = 14
        let trailingWidth: CGFloat = 56
        let spacing: CGFloat = 16
        let top = attachmentHeight + 10
        let textX = horizontalPadding + leadingWidth + 8
        let textWidth = max(
            120,
            width - horizontalPadding * 2 - leadingWidth - trailingWidth - spacing
        )

        return OverlaySlotFrames(
            leading: CGRect(x: horizontalPadding, y: top, width: leadingWidth, height: viewportHeight),
            primaryText: CGRect(x: textX, y: top, width: textWidth, height: viewportHeight),
            trailing: CGRect(
                x: max(textX + textWidth + 8, width - horizontalPadding - trailingWidth),
                y: top,
                width: trailingWidth,
                height: viewportHeight
            )
        )
    }

    private static func historySlotFrames(
        width: CGFloat,
        attachmentHeight: CGFloat,
        viewportHeight: CGFloat,
        isSingleHistory: Bool
    ) -> OverlaySlotFrames {
        let horizontalPadding: CGFloat = 22
        let top = attachmentHeight + 10
        let trailingWidth: CGFloat = isSingleHistory ? 54 : 28
        return OverlaySlotFrames(
            leading: nil,
            primaryText: CGRect(
                x: horizontalPadding,
                y: top,
                width: max(120, width - horizontalPadding * 2 - trailingWidth - 8),
                height: viewportHeight
            ),
            trailing: CGRect(
                x: width - horizontalPadding - trailingWidth,
                y: top,
                width: trailingWidth,
                height: viewportHeight
            )
        )
    }

    private static func previewPanelWidth(textLength: Int, screen: ScreenGeometry) -> CGFloat {
        clampPanelWidth(
            estimatedWidth: CGFloat(textLength) * 5.8 + 128,
            minimumWidth: CompactIslandMetrics.previewPanelMinimumWidth,
            maximumWidth: CompactIslandMetrics.previewPanelMaximumWidth,
            screen: screen,
            sideExtension: 40
        )
    }

    private static func historyPanelWidth(
        items: [TranscriptHistoryItem],
        measurements _: OverlayMeasurements,
        screen: ScreenGeometry
    ) -> CGFloat {
        let textEstimate = CGFloat(items.map { $0.text.count }.max() ?? 0) * 5.6 + 84
        return clampPanelWidth(
            estimatedWidth: textEstimate,
            minimumWidth: CompactIslandMetrics.historyPanelMinimumWidth,
            maximumWidth: CompactIslandMetrics.historyPanelMaximumWidth,
            screen: screen,
            sideExtension: 40
        )
    }

    private static func historyRowsViewportHeight(
        items: [TranscriptHistoryItem],
        measurements: OverlayMeasurements,
        panelWidth: CGFloat
    ) -> CGFloat {
        let visibleMeasuredHeights = Array(measurements.historyRowSizes.prefix(4))
            .map(\.height)
            .filter { $0 > 0 }
        guard !visibleMeasuredHeights.isEmpty else {
            return CompactIslandMetrics.historyRowsViewportHeight(
                forTextLengths: items.map { $0.text.count },
                panelWidth: panelWidth
            )
        }

        let spacing = CGFloat(max(0, visibleMeasuredHeights.count - 1)) * 8
        let measuredRowsHeight = visibleMeasuredHeights.reduce(0, +) + spacing
        return min(measuredRowsHeight, CompactIslandMetrics.maximumHistoryViewportHeight)
    }

    private static func estimatedPreviewTextHeight(text: String, width: CGFloat) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 18 }

        let textColumnWidth = max(120, width - 112)
        let charactersPerLine = max(18, Int(textColumnWidth / 7))
        let lineCount = max(
            1,
            Int(ceil(Double(trimmed.count) / Double(charactersPerLine)))
        )
        return CGFloat(lineCount) * 17
    }

    private static func normalizedMeasuredHeight(_ height: CGFloat?) -> CGFloat? {
        guard let height, height.isFinite, height > 0 else { return nil }
        return max(18, height)
    }

    private static func clampPanelWidth(
        estimatedWidth: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat,
        screen: ScreenGeometry,
        sideExtension: CGFloat
    ) -> CGFloat {
        let availableWidth = max(240, screen.visibleFrame.width - 16)
        let notchAnchoredWidth = expandedNotchMinimumWidth(for: screen, sideExtension: sideExtension)
        let maximumWidth = min(max(maximumWidth, notchAnchoredWidth), availableWidth)
        let minimumWidth = min(max(minimumWidth, notchAnchoredWidth), maximumWidth)

        return min(max(estimatedWidth, minimumWidth), maximumWidth)
    }

    private static func expandedNotchMinimumWidth(for screen: ScreenGeometry, sideExtension: CGFloat) -> CGFloat {
        let notchGap = topNotchGap(for: screen)
        guard notchGap > 0 else { return 0 }

        return notchGap + sideExtension * 2
    }

    private static func topNotchGap(for screen: ScreenGeometry) -> CGFloat {
        guard screen.safeAreaTop > 0,
              !screen.auxiliaryTopLeftArea.isEmpty,
              !screen.auxiliaryTopRightArea.isEmpty else {
            return 0
        }

        return max(0, screen.auxiliaryTopRightArea.minX - screen.auxiliaryTopLeftArea.maxX)
    }

    private static func hostFrame(for panelFrame: CGRect, screen: ScreenGeometry) -> CGRect {
        let hostHeight = max(
            CGFloat(420),
            panelFrame.height + max(0, screen.frame.maxY - panelFrame.maxY)
        )
        return CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - hostHeight,
            width: screen.frame.width,
            height: hostHeight
        )
    }

    private static func hostContentFrame(for panelFrame: CGRect, screen: ScreenGeometry) -> CGRect {
        CGRect(
            x: panelFrame.minX - screen.frame.minX,
            y: screen.frame.maxY - panelFrame.maxY,
            width: panelFrame.width,
            height: panelFrame.height
        )
    }
}
