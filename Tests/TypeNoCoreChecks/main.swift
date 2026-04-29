import CoreGraphics
import Foundation
import TypeNoCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Check failed: \(message)\n", stderr)
        exit(1)
    }
}

func checkEqual(_ lhs: CGRect, _ rhs: CGRect, _ message: String) {
    if lhs != rhs {
        fputs("Check failed: \(message)\nexpected: \(rhs)\nactual:   \(lhs)\n", stderr)
        exit(1)
    }
}

func compactIslandFrameHugsBelowNotchAreaOnNotchedScreens() {
    let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923),
        safeAreaTop: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
        auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32)
    )

    let frame = OverlayGeometry.compactIslandFrame(
        panelSize: CGSize(width: 360, height: 44),
        screen: screen
    )

    checkEqual(frame, CGRect(x: 555, y: 879, width: 360, height: 44), "notched island frame")
    check(frame.maxY <= screen.visibleFrame.maxY, "notched island should not enter the notch safe area")
    check(frame.midX == screen.frame.midX, "notched island should be centered on the screen")
}

func compactIslandFrameExpandsDownwardOnNotchedScreens() {
    let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923),
        safeAreaTop: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
        auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32)
    )

    let compact = OverlayGeometry.compactIslandFrame(
        panelSize: CGSize(width: 360, height: 44),
        screen: screen
    )
    let expanded = OverlayGeometry.compactIslandFrame(
        panelSize: CGSize(width: 360, height: 104),
        screen: screen
    )

    check(compact.maxY == expanded.maxY, "expanded island should keep the top edge below the notch")
    check(expanded.minY < compact.minY, "expanded island should grow downward")
}

func notchAttachedIslandFrameStartsAtTheTopOfTheScreen() {
    let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923),
        safeAreaTop: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
        auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32)
    )

    let frame = OverlayGeometry.notchAttachedIslandFrame(
        panelSize: CGSize(width: 360, height: 96),
        screen: screen
    )

    checkEqual(frame, CGRect(x: 555, y: 860, width: 360, height: 96), "notch attached island frame")
    check(frame.maxY == screen.frame.maxY, "notch attached frame should reach the physical top of the screen")
    check(
        OverlayGeometry.notchAttachmentHeight(for: screen) == 32,
        "notch attachment height should match the visible auxiliary top area"
    )
}

func collapsedRecordingFrameUsesNotchSideAuxiliaryArea() {
    let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923),
        safeAreaTop: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
        auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32)
    )

    let frame = OverlayGeometry.collapsedRecordingFrame(
        panelSize: CGSize(
            width: CompactIslandMetrics.collapsedRecordingWidth(for: screen),
            height: CompactIslandMetrics.collapsedRecordingHeight
        ),
        screen: screen
    )

    let expandedFrame = OverlayGeometry.compactIslandFrame(
        panelSize: CGSize(width: CompactIslandMetrics.width(for: screen), height: CompactIslandMetrics.minimumHeight),
        screen: screen
    )

    checkEqual(frame, CGRect(x: 575, y: 924, width: 320, height: 32), "collapsed recording frame")
    check(frame.minY >= screen.auxiliaryTopLeftArea.minY, "collapsed frame should sit in the top auxiliary area")
    check(frame.maxY <= screen.auxiliaryTopLeftArea.maxY, "collapsed frame should not extend below the auxiliary area")
    check(frame.maxY > screen.visibleFrame.maxY, "collapsed frame should be above the normal visible frame")
    check(frame.midX == screen.frame.midX, "collapsed frame should bridge the notch center")
    check(frame.minX < screen.auxiliaryTopLeftArea.maxX, "collapsed frame should visually attach to the left notch edge")
    check(frame.maxX > screen.auxiliaryTopRightArea.minX, "collapsed frame should visually attach to the right notch edge")
    check(expandedFrame.width > frame.width, "expanded frame should have room for preview text without widening the collapsed rail")
    check(
        CompactIslandMetrics.collapsedRecordingWidth(for: screen) == 320,
        "collapsed rail should hug the current notch without becoming a menu-bar strip"
    )
    check(
        CompactIslandMetrics.collapsedRecordingSpacerWidth(for: screen) == 179,
        "collapsed spacer should match the notch gap plus tight attachment margins"
    )
}

func compactIslandMetricsAdaptToWiderNotchGaps() {
    let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
        safeAreaTop: 37,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 1081, width: 620, height: 36),
        auxiliaryTopRightArea: CGRect(x: 940, y: 1081, width: 788, height: 36)
    )

    let adaptiveWidth = CompactIslandMetrics.width(for: screen)
    let collapsedWidth = CompactIslandMetrics.collapsedRecordingWidth(for: screen)
    let collapsedFrame = OverlayGeometry.collapsedRecordingFrame(
        panelSize: CGSize(width: adaptiveWidth, height: CompactIslandMetrics.collapsedRecordingHeight),
        screen: screen
    )
    let expandedFrame = OverlayGeometry.compactIslandFrame(
        panelSize: CGSize(width: adaptiveWidth, height: CompactIslandMetrics.minimumHeight),
        screen: screen
    )

    check(adaptiveWidth > CompactIslandMetrics.width, "island width should expand for wider notch gaps")
    check(collapsedWidth > CompactIslandMetrics.collapsedRecordingWidth, "collapsed rail should expand for wider notch gaps")
    check(collapsedFrame.minX == expandedFrame.minX, "adaptive collapsed and expanded frames should share x origin")
    check(collapsedFrame.width == expandedFrame.width, "adaptive collapsed and expanded frames should share width")
}

func historyAndPreviewPanelWidthsFollowContent() {
    let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923),
        safeAreaTop: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
        auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32)
    )

    check(
        CompactIslandMetrics.historyPanelWidth(forTextLengths: [8], screen: screen) == 300,
        "short history should keep enough room for copy and close controls without using the recording rail width"
    )
    check(
        CompactIslandMetrics.historyPanelWidth(forTextLengths: [50], screen: screen) == 340,
        "longer history should grow to the history panel cap"
    )
    check(
        CompactIslandMetrics.previewPanelWidth(forTextLength: 10, screen: screen) == 260,
        "short recording preview should stay compact"
    )
    check(
        CompactIslandMetrics.previewPanelWidth(forTextLength: 45, screen: screen) == 340,
        "long recording preview should grow to the preview panel cap"
    )
}

func recordingHoverRegionBridgesCollapsedAndExpandedFrames() {
    let collapsedFrame = CGRect(x: 555, y: 924, width: 360, height: 32)
    let expandedFrame = CGRect(x: 555, y: 819, width: 360, height: 104)

    check(
        OverlayGeometry.recordingHoverRegionContains(
            CGPoint(x: 585, y: 940),
            collapsedFrame: collapsedFrame,
            expandedFrame: expandedFrame
        ),
        "hover region should keep the island open while the pointer is on the collapsed trigger"
    )
    check(
        OverlayGeometry.recordingHoverRegionContains(
            CGPoint(x: 735, y: 923.5),
            collapsedFrame: collapsedFrame,
            expandedFrame: expandedFrame
        ),
        "hover region should bridge the handoff between the collapsed trigger and expanded preview"
    )
    check(
        OverlayGeometry.recordingHoverRegionContains(
            CGPoint(x: 735, y: 860),
            collapsedFrame: collapsedFrame,
            expandedFrame: expandedFrame
        ),
        "hover region should keep the island open on the expanded preview"
    )
    check(
        !OverlayGeometry.recordingHoverRegionContains(
            CGPoint(x: 300, y: 860),
            collapsedFrame: collapsedFrame,
            expandedFrame: expandedFrame
        ),
        "hover region should collapse after the pointer leaves the island area"
    )
}

func compactIslandFrameSitsBelowMenuBarWhenNoNotchIsPresent() {
    let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
        safeAreaTop: 0
    )

    let frame = OverlayGeometry.compactIslandFrame(
        panelSize: CGSize(width: 360, height: 44),
        screen: screen
    )

    checkEqual(frame, CGRect(x: 540, y: 823, width: 360, height: 44), "non-notched island frame")
    check(frame.maxY < screen.visibleFrame.maxY, "non-notched island should sit below the menu bar")
    check(frame.midX == screen.frame.midX, "non-notched island should be centered on the screen")
}

func compactTextViewportCapsLongPreviewText() {
    check(
        CompactIslandMetrics.textViewportHeight(forContentHeight: 42) == 42,
        "short preview text should use its natural height"
    )
    check(
        CompactIslandMetrics.textViewportHeight(forContentHeight: 180) == 108,
        "long preview text should be capped and scroll inside the island"
    )
}

func recordingLayoutPlanKeepsCollapsedSlotsOutsideTheNotchGap() {
    let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923),
        safeAreaTop: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
        auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32)
    )

    let plan = OverlayLayoutPlanner.makePlan(
        OverlayLayoutRequest(
            screen: screen,
            scene: .recording(
                RecordingOverlayScene(isExpanded: false, previewText: "", elapsedText: "0:00")
            )
        )
    )

    check(plan.variant == .recordingRail, "collapsed recording should use rail variant")
    checkEqual(plan.panelFrame, CGRect(x: 575, y: 924, width: 320, height: 32), "collapsed recording plan frame")
    checkEqual(
        plan.slotFrames.leading ?? .zero,
        CGRect(x: 0, y: 0, width: 70, height: 32),
        "recording indicator slot should stay on the left side of the notch"
    )
    checkEqual(
        plan.slotFrames.trailing ?? .zero,
        CGRect(x: 250, y: 0, width: 70, height: 32),
        "timer slot should stay on the right side of the notch"
    )
    check(
        plan.hitRegions.first?.contains(CGPoint(x: plan.contentFrame.midX, y: plan.contentFrame.midY)) == true,
        "hit region should include content frame center"
    )
}

func recordingLayoutPlanUsesMeasuredPreviewViewport() {
    let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923),
        safeAreaTop: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
        auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32)
    )

    let plan = OverlayLayoutPlanner.makePlan(
        OverlayLayoutRequest(
            screen: screen,
            scene: .recording(
                RecordingOverlayScene(
                    isExpanded: true,
                    previewText: String(repeating: "hello ", count: 20),
                    elapsedText: "0:42"
                )
            ),
            measurements: OverlayMeasurements(
                previewTextSize: CGSize(width: 220, height: 180)
            )
        )
    )

    check(plan.variant == .recordingPreview, "expanded recording should use preview variant")
    check(plan.viewportHeight == 108, "long measured preview should cap the viewport")
    check(plan.panelFrame.width == 340, "long preview should use the preview width cap")
    check(plan.panelFrame.height == 160, "expanded preview should combine notch attachment and measured viewport height")
    check(plan.contentFrame.minY == 0, "notch-attached content should begin at the top overlay host")
}

func historyLayoutPlanUsesMeasuredRowsAndCapsViewport() {
    let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923),
        safeAreaTop: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
        auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32)
    )
    let items = (0..<5).map { index in
        TranscriptHistoryItem(text: "history item \(index) with enough content to wrap")
    }

    let plan = OverlayLayoutPlanner.makePlan(
        OverlayLayoutRequest(
            screen: screen,
            scene: .history(HistoryOverlayScene(isExpanded: true, items: items)),
            measurements: OverlayMeasurements(
                historyRowSizes: Array(repeating: CGSize(width: 240, height: 96), count: 5)
            )
        )
    )

    check(plan.variant == .historyList, "multiple history items should use list variant")
    check(plan.viewportHeight == 260, "history list should cap measured rows to the scroll viewport")
    check(plan.panelFrame.height == 336, "history panel should include attachment, header, padding and capped rows")
    check(plan.slotFrames.primaryText?.height == 260, "history text slot should match the list viewport")
}

func transcriptHistoryKeepsNewestItemsFirst() {
    var history = TranscriptHistory(maxCount: 3)
    history.record(" first ")
    history.record("")
    history.record("second")
    history.record("third")
    history.record("fourth")

    check(
        history.items.map(\.text) == ["fourth", "third", "second"],
        "history should ignore empty text, trim whitespace, cap count, and keep newest first"
    )
}

compactIslandFrameHugsBelowNotchAreaOnNotchedScreens()
compactIslandFrameExpandsDownwardOnNotchedScreens()
notchAttachedIslandFrameStartsAtTheTopOfTheScreen()
collapsedRecordingFrameUsesNotchSideAuxiliaryArea()
compactIslandMetricsAdaptToWiderNotchGaps()
historyAndPreviewPanelWidthsFollowContent()
recordingHoverRegionBridgesCollapsedAndExpandedFrames()
compactIslandFrameSitsBelowMenuBarWhenNoNotchIsPresent()
compactTextViewportCapsLongPreviewText()
recordingLayoutPlanKeepsCollapsedSlotsOutsideTheNotchGap()
recordingLayoutPlanUsesMeasuredPreviewViewport()
historyLayoutPlanUsesMeasuredRowsAndCapsViewport()
transcriptHistoryKeepsNewestItemsFirst()
print("TypeNoCoreChecks passed")
