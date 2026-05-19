import AppKit
import QuartzCore

private let bubbleSize: CGFloat = 52
private let stickerSize: CGFloat = 320
private let resizeHandleSize: CGFloat = 18
private let resizeEdgeThickness: CGFloat = 10
private let minimumStickerSize = NSSize(width: 220, height: 180)
private let previewHideDelay: TimeInterval = 0.06
private let previewPollInterval: TimeInterval = 0.03
private let restoreHotspotWidth: CGFloat = 16
private let hideMenuSize = NSSize(width: 52, height: 52)
private let hideMenuGap: CGFloat = 8
private let hideMenuHideDelay: TimeInterval = 0.35
private let stickerAnimationOffset: CGFloat = 160
private let stickerSlideInDuration: TimeInterval = 0.18
private let stickerSlideOutDuration: TimeInterval = 0.14
private let baseStickerFontSize: CGFloat = 17
private let minimumStickerFontSize: CGFloat = 8
private let maximumStickerFontSize: CGFloat = 28
private let minimumStickerZoomScale: CGFloat = 0.38
private let maximumStickerZoomScale: CGFloat = 1.80

private enum StickerInteractionMode {
    case display
    case editing
}

fileprivate struct StoredSticker: Codable {
    let id: UUID
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let text: String
    let zoom: Double?
    let zIndex: Int?
}

private final class StickerStorage {
    private var fileURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent("FloatingSticker", isDirectory: true)
            .appendingPathComponent("stickers.json")
    }

    func load() -> [StoredSticker] {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([StoredSticker].self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            NSLog("FloatingSticker load failed: \(error)")
            return []
        }
    }

    func save(_ records: [StoredSticker]) {
        do {
            let folderURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("FloatingSticker save failed: \(error)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum VisibilityState {
        case pinned
        case hidden
        case peek
    }

    private var bubbleWindow: BubbleWindow?
    private var stickerWindows: [StickerWindow] = []
    private var restoreHotspotWindows: [RestoreHotspotWindow] = []
    private let storage = StickerStorage()
    private var saveTimer: Timer?
    private var previewLocalClickMonitor: Any?
    private var previewGlobalClickMonitor: Any?
    private var previewHoverPollTimer: Timer?
    private var previewLastInsideAt: Date?
    private var previewPressedMouseButtons = 0
    private var visibilityState: VisibilityState = .pinned
    private var restoreHotspotRequiresReentry = false
    private var presentationGeneration = 0
    private var isRestoringStickerWindows = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showBubble()
        restoreStoredStickers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveStickerState()
    }

    private func showBubble() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let origin = NSPoint(
            x: screenFrame.maxX - bubbleSize - 18,
            y: screenFrame.maxY - bubbleSize - 18
        )

        let window = BubbleWindow(contentRect: NSRect(origin: origin, size: NSSize(width: bubbleSize, height: bubbleSize)))
        window.onCreateSticker = { [weak self] in
            self?.createSticker()
        }
        window.onHideAll = { [weak self] in
            self?.hideAll()
        }
        window.onQuit = {
            NSApp.terminate(nil)
        }
        window.orderFrontRegardless()
        bubbleWindow = window
    }

    private func createSticker() {
        NSApp.activate(ignoringOtherApps: true)
        if visibilityState != .pinned {
            restoreAll()
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let count = stickerWindows.filter { $0.isVisible }.count
        let offset = CGFloat(min(count, 8)) * 22
        let origin = NSPoint(
            x: min(visibleFrame.maxX - stickerSize - 24, visibleFrame.midX - stickerSize / 2 + offset),
            y: min(visibleFrame.maxY - stickerSize - 64, visibleFrame.midY - stickerSize / 2 - offset)
        )

        let initialText = NSPasteboard.general.string(forType: .string) ?? ""
        let window = makeStickerWindow(
            id: UUID(),
            frame: NSRect(origin: origin, size: NSSize(width: stickerSize, height: stickerSize)),
            text: initialText,
            zoomScale: 1
        )
        stickerWindows.append(window)
        presentStickerWindow(window, animated: true, focusEditor: true)
        bubbleWindow?.showPersistentHideMenu()
        scheduleSave()
    }

    private func makeStickerWindow(id: UUID, frame: NSRect, text: String, zoomScale: CGFloat) -> StickerWindow {
        let window = StickerWindow(id: id, contentRect: frame, text: text, zoomScale: zoomScale)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.stickerWindows.removeAll { $0 === window }
            window.close()
            if self.stickerWindows.isEmpty && self.visibilityState == .pinned {
                self.bubbleWindow?.hideHoverMenuImmediately()
            }
            self.saveStickerState()
        }
        window.onChange = { [weak self] in
            self?.scheduleSave()
        }
        window.onActivate = { [weak self, weak window] in
            guard let self, let window else { return }
            self.bringStickerToFront(window)
        }
        return window
    }

    private func restoreStoredStickers() {
        let records = storage.load().enumerated().sorted { left, right in
            let leftZIndex = left.element.zIndex ?? left.offset
            let rightZIndex = right.element.zIndex ?? right.offset
            if leftZIndex == rightZIndex {
                return left.offset < right.offset
            }
            return leftZIndex < rightZIndex
        }.map(\.element)
        isRestoringStickerWindows = true
        defer { isRestoringStickerWindows = false }

        for record in records {
            let window = makeStickerWindow(
                id: record.id,
                frame: restoredFrame(for: record),
                text: record.text,
                zoomScale: CGFloat(record.zoom ?? 1)
            )
            stickerWindows.append(window)
            presentStickerWindow(window, animated: false, focusEditor: false)
        }
        if !stickerWindows.isEmpty {
            bubbleWindow?.showPersistentHideMenu()
            saveStickerState()
        }
    }

    private func restoredFrame(for record: StoredSticker) -> NSRect {
        let frame = NSRect(
            x: CGFloat(record.x),
            y: CGFloat(record.y),
            width: max(minimumStickerSize.width, CGFloat(record.width)),
            height: max(minimumStickerSize.height, CGFloat(record.height))
        )

        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            return frame
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSRect(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2,
            width: frame.width,
            height: frame.height
        )
    }

    private func bringStickerToFront(_ window: StickerWindow) {
        guard !isRestoringStickerWindows,
              visibilityState != .hidden,
              let index = stickerWindows.firstIndex(where: { $0 === window }) else {
            return
        }

        if index != stickerWindows.index(before: stickerWindows.endIndex) {
            stickerWindows.remove(at: index)
            stickerWindows.append(window)
        }

        if window.isVisible {
            window.orderFrontRegardless()
        }
        scheduleSave()
    }

    private func hideAll() {
        saveStickerState()
        advancePresentationGeneration()
        visibilityState = .hidden
        restoreHotspotRequiresReentry = isInRestoreHotspot(NSEvent.mouseLocation)
        previewLastInsideAt = nil
        stopPreviewHoverPolling()
        stopPreviewClickMonitors()
        bubbleWindow?.hideHoverMenuImmediately()
        stickerWindows.forEach { hideStickerWindow($0, animated: true) }
        bubbleWindow?.orderOut(nil)
        showRestoreHotspots()
    }

    private func restoreAll() {
        advancePresentationGeneration()
        visibilityState = .pinned
        restoreHotspotRequiresReentry = false
        previewLastInsideAt = nil
        stopPreviewHoverPolling()
        stopPreviewClickMonitors()
        hideRestoreHotspots()

        stickerWindows.forEach { presentStickerWindow($0, animated: false, focusEditor: false) }
        bubbleWindow?.orderFrontRegardless()
        bubbleWindow?.showPersistentHideMenu()
    }

    private func showRestoreHotspots() {
        hideRestoreHotspots()

        restoreHotspotWindows = NSScreen.screens.map { screen in
            let frame = NSRect(
                x: screen.frame.maxX - restoreHotspotWidth,
                y: screen.frame.minY,
                width: restoreHotspotWidth,
                height: screen.frame.height
            )
            let window = RestoreHotspotWindow(contentRect: frame)
            window.onHover = { [weak self] in
                self?.handleRestoreHotspotHover()
            }
            window.onExit = { [weak self] in
                self?.restoreHotspotRequiresReentry = false
            }
            return window
        }

        restoreHotspotWindows.forEach { $0.orderFrontRegardless() }
    }

    private func hideRestoreHotspots() {
        restoreHotspotWindows.forEach { window in
            window.orderOut(nil)
            window.close()
        }
        restoreHotspotWindows.removeAll()
    }

    private func handleRestoreHotspotHover() {
        guard visibilityState == .hidden else { return }
        guard !restoreHotspotRequiresReentry else { return }
        showPreviewFromHidden()
    }

    private func isInRestoreHotspot(_ location: NSPoint) -> Bool {
        for screen in NSScreen.screens {
            let hotspot = NSRect(
                x: screen.frame.maxX - restoreHotspotWidth,
                y: screen.frame.minY,
                width: restoreHotspotWidth,
                height: screen.frame.height
            )

            if hotspot.contains(location) {
                return true
            }
        }

        return false
    }

    private func showPreviewFromHidden() {
        guard visibilityState == .hidden else { return }

        advancePresentationGeneration()
        visibilityState = .peek
        restoreHotspotRequiresReentry = false
        hideRestoreHotspots()
        startPreviewClickMonitors()
        startPreviewHoverPolling()
        stickerWindows.forEach { presentStickerWindow($0, animated: true, focusEditor: false) }
        bubbleWindow?.orderFrontRegardless()
        bubbleWindow?.showPersistentHideMenu()
        previewLastInsideAt = Date()
        previewPressedMouseButtons = NSEvent.pressedMouseButtons
    }

    private func hidePreviewFromHidden() {
        guard visibilityState == .peek || visibilityState == .hidden else { return }

        advancePresentationGeneration()
        visibilityState = .hidden
        restoreHotspotRequiresReentry = isInRestoreHotspot(NSEvent.mouseLocation)
        previewLastInsideAt = nil
        stopPreviewHoverPolling()
        stopPreviewClickMonitors()
        bubbleWindow?.hideHoverMenuImmediately()
        stickerWindows.forEach { hideStickerWindow($0, animated: true) }
        bubbleWindow?.orderOut(nil)
        showRestoreHotspots()
    }

    private func startPreviewClickMonitors() {
        guard previewLocalClickMonitor == nil, previewGlobalClickMonitor == nil else { return }

        previewLocalClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let clickLocation = NSEvent.mouseLocation
            self?.handlePreviewClick(at: clickLocation)
            return event
        }

        previewGlobalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self?.handlePreviewClick(at: clickLocation)
            }
        }
    }

    private func stopPreviewClickMonitors() {
        if let previewLocalClickMonitor {
            NSEvent.removeMonitor(previewLocalClickMonitor)
            self.previewLocalClickMonitor = nil
        }

        if let previewGlobalClickMonitor {
            NSEvent.removeMonitor(previewGlobalClickMonitor)
            self.previewGlobalClickMonitor = nil
        }
    }

    private func startPreviewHoverPolling() {
        previewHoverPollTimer?.invalidate()
        previewPressedMouseButtons = NSEvent.pressedMouseButtons
        let timer = Timer(timeInterval: previewPollInterval, repeats: true) { [weak self] _ in
            self?.checkPreviewHover()
        }
        RunLoop.main.add(timer, forMode: .common)
        previewHoverPollTimer = timer
    }

    private func stopPreviewHoverPolling() {
        previewHoverPollTimer?.invalidate()
        previewHoverPollTimer = nil
    }

    private func checkPreviewHover() {
        guard visibilityState == .peek else { return }

        let location = NSEvent.mouseLocation
        if handlePreviewMousePressIfNeeded(at: location) {
            return
        }

        if isInRestoreHotspot(location) || isFloatingUILocation(location) {
            previewLastInsideAt = Date()
        } else {
            let leftAt = previewLastInsideAt ?? Date()
            previewLastInsideAt = leftAt
            if Date().timeIntervalSince(leftAt) >= previewHideDelay {
                hidePreviewFromHidden()
            }
        }
    }

    private func handlePreviewMousePressIfNeeded(at location: NSPoint) -> Bool {
        let pressedButtons = NSEvent.pressedMouseButtons
        defer { previewPressedMouseButtons = pressedButtons }

        guard previewPressedMouseButtons == 0, pressedButtons != 0 else {
            return false
        }

        handlePreviewClick(at: location)
        return true
    }

    private func handlePreviewClick(at location: NSPoint) {
        guard visibilityState == .peek else { return }

        if isFloatingUILocation(location) {
            restoreAll()
        } else {
            hidePreviewFromHidden()
        }
    }

    private func advancePresentationGeneration() {
        presentationGeneration &+= 1
    }

    private func hideStickerWindow(_ window: StickerWindow, targetFrame explicitTargetFrame: NSRect? = nil, animated: Bool = false) {
        let targetFrame = explicitTargetFrame ?? window.presentationTargetFrame ?? window.frame
        guard animated, window.isVisible else {
            window.presentationTargetFrame = nil
            window.suppressesFrameChangeNotifications = false
            window.alphaValue = 0
            window.setFrame(targetFrame, display: false)
            window.orderOut(nil)
            return
        }

        let animationGeneration = presentationGeneration
        let hiddenFrame = hiddenStickerFrame(for: targetFrame)
        window.presentationTargetFrame = targetFrame
        window.suppressesFrameChangeNotifications = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = stickerSlideOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(hiddenFrame, display: true)
        } completionHandler: { [weak self, weak window] in
            guard let self, let window else { return }
            guard self.presentationGeneration == animationGeneration, self.visibilityState == .hidden else {
                return
            }

            window.presentationTargetFrame = nil
            window.suppressesFrameChangeNotifications = false
            window.alphaValue = 0
            window.setFrame(targetFrame, display: false)
            window.orderOut(nil)
        }
    }

    private func hiddenStickerFrame(for targetFrame: NSRect) -> NSRect {
        targetFrame.offsetBy(dx: stickerAnimationOffset, dy: 0)
    }

    private func restoreStickerWindow(_ window: StickerWindow, targetFrame: NSRect, focusEditor: Bool) {
        window.suppressesFrameChangeNotifications = false
        window.setFrame(targetFrame, display: false)
        window.alphaValue = 1
        window.presentationTargetFrame = nil
        if focusEditor {
            window.focusEditor()
        }
    }

    private func finishCancelledStickerPresentation(_ window: StickerWindow, targetFrame: NSRect) {
        switch visibilityState {
        case .hidden:
            hideStickerWindow(window, targetFrame: targetFrame, animated: true)
        case .pinned:
            window.orderFrontRegardless()
            restoreStickerWindow(window, targetFrame: targetFrame, focusEditor: false)
        case .peek:
            break
        }
    }

    private func isFloatingUILocation(_ location: NSPoint) -> Bool {
        if bubbleWindow?.containsFloatingUILocation(location) == true {
            return true
        }

        return stickerWindows.contains { window in
            window.isVisible && window.containsStableMouseLocation(location)
        }
    }

    private func presentStickerWindow(_ window: StickerWindow, animated: Bool, focusEditor: Bool) {
        let targetFrame = window.presentationTargetFrame ?? window.frame

        guard animated else {
            window.setFrame(targetFrame, display: true)
            window.orderFrontRegardless()
            restoreStickerWindow(window, targetFrame: targetFrame, focusEditor: focusEditor)
            return
        }

        let startFrame = hiddenStickerFrame(for: targetFrame)
        let animationGeneration = presentationGeneration

        window.presentationTargetFrame = targetFrame
        window.suppressesFrameChangeNotifications = true
        window.alphaValue = 0
        window.setFrame(startFrame, display: true)
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = stickerSlideInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak window] in
            guard let self, let window else { return }
            guard self.presentationGeneration == animationGeneration else {
                self.finishCancelledStickerPresentation(window, targetFrame: targetFrame)
                return
            }
            self.restoreStickerWindow(window, targetFrame: targetFrame, focusEditor: focusEditor)
            window.notifyPresentationFinished()
            self.scheduleSave()
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.saveStickerState()
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    private func saveStickerState() {
        saveTimer?.invalidate()
        saveTimer = nil
        storage.save(stickerWindows.enumerated().map { index, window in
            window.storedRecord(zIndex: index)
        })
    }
}

final class BubbleWindow: NSWindow {
    var onCreateSticker: (() -> Void)?
    var onHideAll: (() -> Void)?
    var onQuit: (() -> Void)?

    private var hoverMenuWindow: HideMenuWindow?
    private var isBubbleHovered = false
    private var isHoverMenuHovered = false
    private var isHoverMenuPinned = false
    private var hideMenuWorkItem: DispatchWorkItem?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .readOnly
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false

        let button = BubbleButton(frame: NSRect(origin: .zero, size: contentRect.size))
        button.onCreateSticker = { [weak self] in self?.onCreateSticker?() }
        button.onHideAll = { [weak self] in self?.onHideAll?() }
        button.onQuit = { [weak self] in self?.onQuit?() }
        button.onHoverChanged = { [weak self] hovering in
            self?.setBubbleHovering(hovering)
        }
        contentView = button
    }

    override var canBecomeKey: Bool { true }

    func hideHoverMenuImmediately() {
        hideMenuWorkItem?.cancel()
        hideMenuWorkItem = nil
        isHoverMenuPinned = false
        hoverMenuWindow?.orderOut(nil)
        stopHoverMenuClickMonitors()
        isBubbleHovered = false
        isHoverMenuHovered = false
    }

    func showPersistentHideMenu() {
        isHoverMenuPinned = true
        showHoverMenu()
    }

    func containsFloatingUILocation(_ location: NSPoint) -> Bool {
        if containsMouseLocation(location) {
            return true
        }

        return hoverMenuWindow?.isVisible == true && hoverMenuWindow?.containsMouseLocation(location) == true
    }

    private func setBubbleHovering(_ hovering: Bool) {
        isBubbleHovered = hovering
        if hovering {
            showHoverMenu()
        } else if !isHoverMenuPinned {
            scheduleHoverMenuHide()
        }
    }

    private func setHoverMenuHovering(_ hovering: Bool) {
        isHoverMenuHovered = hovering
        if hovering {
            hideMenuWorkItem?.cancel()
            hideMenuWorkItem = nil
        } else if !isHoverMenuPinned {
            scheduleHoverMenuHide()
        }
    }

    private func showHoverMenu() {
        hideMenuWorkItem?.cancel()
        hideMenuWorkItem = nil

        let menuWindow = hoverMenuWindow ?? makeHoverMenuWindow()
        menuWindow.setFrame(hoverMenuFrame(), display: true)
        menuWindow.orderFrontRegardless()
        hoverMenuWindow = menuWindow
        startHoverMenuClickMonitors()
    }

    private func makeHoverMenuWindow() -> HideMenuWindow {
        let menuWindow = HideMenuWindow(contentRect: hoverMenuFrame())
        menuWindow.onHideAll = { [weak self] in
            self?.hideHoverMenuImmediately()
            self?.onHideAll?()
        }
        menuWindow.onHoverChanged = { [weak self] hovering in
            self?.setHoverMenuHovering(hovering)
        }
        return menuWindow
    }

    private func hoverMenuFrame() -> NSRect {
        let screenFrame = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        let margin: CGFloat = 8
        let centeredX = frame.midX - hideMenuSize.width / 2
        let x = min(max(centeredX, screenFrame.minX + margin), screenFrame.maxX - hideMenuSize.width - margin)
        let belowY = frame.minY - hideMenuSize.height - hideMenuGap
        let aboveY = frame.maxY + hideMenuGap
        let y = belowY >= screenFrame.minY + margin ? belowY : min(aboveY, screenFrame.maxY - hideMenuSize.height - margin)

        return NSRect(x: x, y: y, width: hideMenuSize.width, height: hideMenuSize.height)
    }

    private func scheduleHoverMenuHide() {
        guard !isHoverMenuPinned else { return }

        hideMenuWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isBubbleHovered && !self.isHoverMenuHovered {
                self.hoverMenuWindow?.orderOut(nil)
                self.stopHoverMenuClickMonitors()
            }
        }
        hideMenuWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hideMenuHideDelay, execute: workItem)
    }

    private func startHoverMenuClickMonitors() {
        guard localMouseDownMonitor == nil, globalMouseDownMonitor == nil else { return }

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            if self?.handleHoverMenuClick() == true {
                return nil
            }
            return event
        }

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                _ = self?.handleHoverMenuClick()
            }
        }
    }

    private func stopHoverMenuClickMonitors() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }

        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private func handleHoverMenuClick() -> Bool {
        guard let hoverMenuWindow, hoverMenuWindow.isVisible else { return false }
        guard hoverMenuWindow.containsMouseLocation(NSEvent.mouseLocation) else { return false }

        hideHoverMenuImmediately()
        onHideAll?()
        return true
    }
}

private extension NSWindow {
    func containsMouseLocation(_ location: NSPoint) -> Bool {
        frame.contains(location)
    }
}

final class RestoreHotspotWindow: NSWindow {
    var onHover: (() -> Void)? {
        didSet { hotspotView.onHover = onHover }
    }

    var onExit: (() -> Void)? {
        didSet { hotspotView.onExit = onExit }
    }

    private let hotspotView: RestoreHotspotView

    init(contentRect: NSRect) {
        hotspotView = RestoreHotspotView(frame: NSRect(origin: .zero, size: contentRect.size))

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .readOnly
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = hotspotView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class RestoreHotspotView: NSView {
    var onHover: (() -> Void)?
    var onExit: (() -> Void)?

    private var trackingAreaToken: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingAreaToken {
            removeTrackingArea(trackingAreaToken)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaToken = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?()
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }

    override func mouseDown(with event: NSEvent) {
        onHover?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onHover?()
    }
}

final class BubbleButton: NSButton {
    var onCreateSticker: (() -> Void)?
    var onHideAll: (() -> Void)?
    var onQuit: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let circleRect = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(ovalIn: circleRect)
        let topColor = isHovering
            ? NSColor(calibratedRed: 0.23, green: 0.58, blue: 1.00, alpha: 1.0)
            : NSColor(calibratedRed: 0.12, green: 0.44, blue: 0.92, alpha: 1.0)
        let bottomColor = isHovering
            ? NSColor(calibratedRed: 0.09, green: 0.34, blue: 0.88, alpha: 1.0)
            : NSColor(calibratedRed: 0.07, green: 0.24, blue: 0.70, alpha: 1.0)

        NSGradient(starting: topColor, ending: bottomColor)?.draw(in: path, angle: 90)

        NSColor.white.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 1
        path.stroke()

        NSColor.white.setStroke()
        let plus = NSBezierPath()
        plus.lineWidth = 4
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: bounds.midX, y: bounds.midY - 11))
        plus.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 11))
        plus.move(to: NSPoint(x: bounds.midX - 11, y: bounds.midY))
        plus.line(to: NSPoint(x: bounds.midX + 11, y: bounds.midY))
        plus.stroke()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
            return
        }
        onCreateSticker?()
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "New Sticker", action: #selector(createStickerFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide All", action: #selector(hideAllFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FloatingSticker", action: #selector(quitFromMenu), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func createStickerFromMenu() {
        onCreateSticker?()
    }

    @objc private func hideAllFromMenu() {
        onHideAll?()
    }

    @objc private func quitFromMenu() {
        onQuit?()
    }
}

final class HideMenuWindow: NSWindow {
    var onHideAll: (() -> Void)? {
        didSet { hideMenuView.onHideAll = onHideAll }
    }

    var onHoverChanged: ((Bool) -> Void)? {
        didSet { hideMenuView.onHoverChanged = onHoverChanged }
    }

    private let hideMenuView = HideMenuView(frame: NSRect(origin: .zero, size: hideMenuSize))

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .readOnly
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = hideMenuView
    }

    override var canBecomeKey: Bool { true }
}

final class HideMenuView: NSView {
    var onHideAll: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let circleRect = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(ovalIn: circleRect)
        let topColor = isHovering
            ? NSColor(calibratedRed: 0.25, green: 0.31, blue: 0.40, alpha: 1.0)
            : NSColor(calibratedRed: 0.15, green: 0.19, blue: 0.27, alpha: 0.98)
        let bottomColor = isHovering
            ? NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.24, alpha: 1.0)
            : NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.18, alpha: 0.98)

        NSGradient(starting: topColor, ending: bottomColor)?.draw(in: path, angle: 90)
        NSColor.white.withAlphaComponent(0.20).setStroke()
        path.lineWidth = 1
        path.stroke()

        let eyeRect = NSRect(x: bounds.midX - 13, y: bounds.midY - 7, width: 26, height: 14)
        NSColor.white.withAlphaComponent(0.92).setStroke()

        let eye = NSBezierPath(ovalIn: eyeRect)
        eye.lineWidth = 2
        eye.stroke()

        let slash = NSBezierPath()
        slash.lineWidth = 2.4
        slash.lineCapStyle = .round
        slash.move(to: NSPoint(x: bounds.midX - 13, y: bounds.midY - 13))
        slash.line(to: NSPoint(x: bounds.midX + 13, y: bounds.midY + 13))
        slash.stroke()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onHideAll?()
    }
}

private final class StickerModeButton: NSButton {
    var mode: StickerInteractionMode = .display {
        didSet {
            toolTip = mode == .display ? "Edit" : "Done"
            needsDisplay = true
        }
    }

    private var isHovering = false {
        didSet { needsDisplay = true }
    }
    private var trackingAreaToken: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        wantsLayer = true
        toolTip = "Edit"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingAreaToken {
            removeTrackingArea(trackingAreaToken)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaToken = trackingArea
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let isDoneMode = mode == .editing
        let baseColor = isDoneMode
            ? NSColor(calibratedRed: 0.23, green: 0.50, blue: 0.28, alpha: 0.96)
            : NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.25, alpha: 0.88)
        let hoverColor = isDoneMode
            ? NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.23, alpha: 1.0)
            : NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.34, alpha: 0.96)
        (isHovering || isHighlighted ? hoverColor : baseColor).setFill()
        path.fill()

        let strokeColor = isDoneMode
            ? NSColor(calibratedRed: 0.07, green: 0.24, blue: 0.10, alpha: 0.36)
            : NSColor(calibratedRed: 0.48, green: 0.35, blue: 0.08, alpha: 0.30)
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let label = isDoneMode ? "Done" : "Edit"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: isDoneMode ? NSColor.white : NSColor(calibratedRed: 0.24, green: 0.17, blue: 0.04, alpha: 0.95),
            .paragraphStyle: paragraph
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            in: NSRect(x: rect.minX, y: rect.midY - textSize.height / 2 - 0.5, width: rect.width, height: textSize.height + 2),
            withAttributes: attributes
        )
    }
}

final class ZoomControlView: NSView {
    var onZoomOut: (() -> Void)?
    var onReset: (() -> Void)?
    var onZoomIn: (() -> Void)?

    private enum Segment {
        case zoomOut
        case reset
        case zoomIn
    }

    private var zoomScale: CGFloat = 1
    private var hoveredSegment: Segment? {
        didSet { needsDisplay = true }
    }
    private var pressedSegment: Segment? {
        didSet { needsDisplay = true }
    }
    private var trackingAreaToken: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Zoom: click the percentage to reset"
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setZoomScale(_ scale: CGFloat) {
        zoomScale = scale
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let trackingAreaToken {
            removeTrackingArea(trackingAreaToken)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaToken = trackingArea
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        hoveredSegment = segment(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredSegment = segment(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSegment = nil
        pressedSegment = nil
    }

    override func mouseDown(with event: NSEvent) {
        pressedSegment = segment(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let releasedSegment = segment(at: convert(event.locationInWindow, from: nil))
        defer { pressedSegment = nil }

        guard let pressedSegment, pressedSegment == releasedSegment else {
            return
        }

        switch pressedSegment {
        case .zoomOut:
            onZoomOut?()
        case .reset:
            onReset?()
        case .zoomIn:
            onZoomIn?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)

        NSColor(calibratedRed: 0.98, green: 0.86, blue: 0.36, alpha: 0.78).setFill()
        path.fill()

        NSColor(calibratedRed: 0.46, green: 0.34, blue: 0.08, alpha: 0.34).setStroke()
        path.lineWidth = 1
        path.stroke()

        for segment in [Segment.zoomOut, .reset, .zoomIn] {
            drawHighlight(for: segment, in: rect)
        }

        drawSeparators(in: rect)
        drawLabel("-", in: segmentRect(.zoomOut), font: .systemFont(ofSize: 17, weight: .bold))
        drawLabel("\(Int(round(zoomScale * 100)))%", in: segmentRect(.reset), font: .systemFont(ofSize: 11.5, weight: .semibold))
        drawLabel("+", in: segmentRect(.zoomIn), font: .systemFont(ofSize: 16, weight: .bold))
    }

    private func drawHighlight(for segment: Segment, in outerRect: NSRect) {
        guard hoveredSegment == segment || pressedSegment == segment else {
            return
        }

        let rect = segmentRect(segment).insetBy(dx: 2, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let alpha: CGFloat = pressedSegment == segment ? 0.52 : 0.34
        NSColor.white.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    private func drawSeparators(in rect: NSRect) {
        NSColor(calibratedRed: 0.47, green: 0.35, blue: 0.10, alpha: 0.24).setStroke()
        for x in [segmentRect(.reset).minX, segmentRect(.zoomIn).minX] {
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: x, y: rect.minY + 6))
            path.line(to: NSPoint(x: x, y: rect.maxY - 6))
            path.stroke()
        }
    }

    private func drawLabel(_ label: String, in rect: NSRect, font: NSFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 0.24, green: 0.17, blue: 0.04, alpha: 0.95),
            .paragraphStyle: paragraph
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: rect.minX,
            y: rect.midY - textSize.height / 2 - 0.5,
            width: rect.width,
            height: textSize.height + 2
        )
        (label as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func segment(at point: NSPoint) -> Segment? {
        guard bounds.contains(point) else {
            return nil
        }

        if segmentRect(.zoomOut).contains(point) {
            return .zoomOut
        }
        if segmentRect(.zoomIn).contains(point) {
            return .zoomIn
        }
        return .reset
    }

    private func segmentRect(_ segment: Segment) -> NSRect {
        let sideWidth: CGFloat = 34
        switch segment {
        case .zoomOut:
            return NSRect(x: bounds.minX, y: bounds.minY, width: sideWidth, height: bounds.height)
        case .reset:
            return NSRect(x: bounds.minX + sideWidth, y: bounds.minY, width: max(0, bounds.width - sideWidth * 2), height: bounds.height)
        case .zoomIn:
            return NSRect(x: bounds.maxX - sideWidth, y: bounds.minY, width: sideWidth, height: bounds.height)
        }
    }
}

final class StickerWindow: NSPanel {
    let id: UUID
    var onClose: (() -> Void)?
    var onChange: (() -> Void)?
    var onActivate: (() -> Void)?
    fileprivate var suppressesFrameChangeNotifications = false
    fileprivate var presentationTargetFrame: NSRect?
    private weak var stickerView: StickerView?

    fileprivate func storedRecord(zIndex: Int) -> StoredSticker {
        let recordFrame = presentationTargetFrame ?? frame

        return StoredSticker(
            id: id,
            x: Double(recordFrame.origin.x),
            y: Double(recordFrame.origin.y),
            width: Double(recordFrame.width),
            height: Double(recordFrame.height),
            text: stickerView?.editor.string ?? "",
            zoom: Double(stickerView?.zoomScale ?? 1),
            zIndex: zIndex
        )
    }

    init(id: UUID, contentRect: NSRect, text: String, zoomScale: CGFloat) {
        self.id = id
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .readOnly
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = minimumStickerSize
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let stickerView = StickerView(frame: NSRect(origin: .zero, size: contentRect.size), text: text, zoomScale: zoomScale)
        stickerView.onClose = { [weak self] in self?.onClose?() }
        stickerView.onTextChanged = { [weak self] in self?.onChange?() }
        contentView = stickerView
        self.stickerView = stickerView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameChanged),
            name: NSWindow.didMoveNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameChanged),
            name: NSWindow.didResizeNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFocusLost),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFocusGained),
            name: NSWindow.didBecomeKeyNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            onActivate?()
        }
        super.sendEvent(event)
    }

    fileprivate func containsStableMouseLocation(_ location: NSPoint) -> Bool {
        (presentationTargetFrame ?? frame).contains(location)
    }

    func focusEditor() {
        stickerView?.focusEditor()
    }

    fileprivate func notifyPresentationFinished() {
        onChange?()
    }

    @objc private func windowFrameChanged() {
        guard !suppressesFrameChangeNotifications else { return }
        onChange?()
    }

    @objc private func windowFocusGained() {
        onActivate?()
    }

    @objc private func windowFocusLost() {
        stickerView?.showPreviewAfterEditing()
    }
}

final class StickerView: NSView, NSTextViewDelegate {
    var onClose: (() -> Void)?
    var onTextChanged: (() -> Void)?
    let editor = StickerTextView()
    private let scrollView = NSScrollView()
    private let previewScrollView = NSScrollView()
    private let previewView = MarkdownPreviewView()
    private let zoomControl = ZoomControlView(frame: NSRect(x: 14, y: 0, width: 116, height: 26))
    private let modeButton = StickerModeButton(frame: NSRect(x: 0, y: 0, width: 54, height: 22))
    private(set) var zoomScale: CGFloat
    private var interactionMode: StickerInteractionMode = .editing
    private var isChangingInteractionMode = false

    private let backgroundColor = NSColor(calibratedRed: 1.00, green: 0.97, blue: 0.76, alpha: 0.98)
    private let headerTopColor = NSColor(calibratedRed: 1.00, green: 0.91, blue: 0.48, alpha: 0.72)
    private let headerBottomColor = NSColor(calibratedRed: 1.00, green: 0.95, blue: 0.64, alpha: 0.24)
    private let borderColor = NSColor(calibratedRed: 0.74, green: 0.60, blue: 0.20, alpha: 0.30)

    init(frame frameRect: NSRect, text: String, zoomScale: CGFloat) {
        self.zoomScale = Self.clampedZoomScale(zoomScale)
        super.init(frame: frameRect)
        wantsLayer = true
        buildView()
        editor.string = text
        editor.refreshParagraphLayoutPreservingSelection()
        setInteractionMode(.display, focusEditor: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let headerHeight: CGFloat = 34
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        backgroundColor.setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let headerRect = NSRect(x: rect.minX, y: rect.maxY - headerHeight, width: rect.width, height: headerHeight)
        NSGradient(starting: headerTopColor, ending: headerBottomColor)?.draw(in: headerRect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 18, y: bounds.height - 19, width: 36, height: 4), xRadius: 2, yRadius: 2).fill()

        NSColor(calibratedRed: 0.70, green: 0.55, blue: 0.12, alpha: 0.18).setStroke()
        let headerLine = NSBezierPath()
        headerLine.lineWidth = 1
        headerLine.move(to: NSPoint(x: rect.minX + 10, y: rect.maxY - headerHeight))
        headerLine.line(to: NSPoint(x: rect.maxX - 10, y: rect.maxY - headerHeight))
        headerLine.stroke()

        NSColor(calibratedRed: 0.58, green: 0.46, blue: 0.13, alpha: 0.22).setStroke()
        let resizeMark = NSBezierPath()
        resizeMark.lineWidth = 1
        resizeMark.move(to: NSPoint(x: rect.maxX - 18, y: rect.minY + 8))
        resizeMark.line(to: NSPoint(x: rect.maxX - 8, y: rect.minY + 18))
        resizeMark.move(to: NSPoint(x: rect.maxX - 13, y: rect.minY + 7))
        resizeMark.line(to: NSPoint(x: rect.maxX - 7, y: rect.minY + 13))
        resizeMark.stroke()

        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTextLayout()
    }

    private func buildView() {
        let headerHeight: CGFloat = 34

        let header = DragHeaderView(frame: NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight))
        header.autoresizingMask = [.width, .minYMargin]
        addSubview(header)

        let closeButton = NSButton(frame: NSRect(x: bounds.width - 30, y: bounds.height - 26, width: 18, height: 18))
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        closeButton.title = "x"
        closeButton.font = .systemFont(ofSize: 13, weight: .semibold)
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(calibratedRed: 0.40, green: 0.31, blue: 0.10, alpha: 0.74)
        closeButton.target = self
        closeButton.action = #selector(closeSticker)
        addSubview(closeButton)

        modeButton.frame.origin = NSPoint(x: bounds.width - 88, y: bounds.height - 28)
        modeButton.autoresizingMask = [.minXMargin, .minYMargin]
        modeButton.target = self
        modeButton.action = #selector(toggleInteractionMode)
        addSubview(modeButton)

        zoomControl.frame.origin.y = bounds.height - 29
        zoomControl.autoresizingMask = [.maxXMargin, .minYMargin]
        zoomControl.onZoomOut = { [weak self] in self?.zoomOut() }
        zoomControl.onReset = { [weak self] in self?.resetZoom() }
        zoomControl.onZoomIn = { [weak self] in self?.zoomIn() }
        addSubview(zoomControl)

        scrollView.frame = NSRect(x: 18, y: 18, width: bounds.width - 36, height: bounds.height - headerHeight - 28)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        editor.frame = scrollView.bounds
        editor.autoresizingMask = [.width]
        editor.drawsBackground = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.isRichText = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.isGrammarCheckingEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = true
        editor.isAutomaticDashSubstitutionEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.isAutomaticTextReplacementEnabled = true
        editor.isAutomaticLinkDetectionEnabled = true
        editor.font = .systemFont(ofSize: baseStickerFontSize)
        editor.textColor = NSColor(calibratedRed: 0.17, green: 0.14, blue: 0.07, alpha: 1.0)
        editor.insertionPointColor = editor.textColor
        editor.textContainerInset = NSSize(width: 5, height: 7)
        editor.string = ""
        editor.minSize = NSSize(width: 0, height: scrollView.bounds.height)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.delegate = self
        editor.onZoomIn = { [weak self] in self?.zoomIn() }
        editor.onZoomOut = { [weak self] in self?.zoomOut() }
        editor.onZoomReset = { [weak self] in self?.resetZoom() }
        editor.onFinishEditing = { [weak self] in
            self?.showDisplay()
        }
        editor.textContainer?.containerSize = NSSize(width: scrollView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true

        scrollView.documentView = editor
        addSubview(scrollView)

        previewScrollView.frame = scrollView.frame
        previewScrollView.autoresizingMask = scrollView.autoresizingMask
        previewScrollView.borderType = .noBorder
        previewScrollView.drawsBackground = false
        previewScrollView.hasVerticalScroller = true
        previewScrollView.hasHorizontalScroller = true
        previewScrollView.autohidesScrollers = true
        previewScrollView.isHidden = true
        previewView.onBeginEditing = { [weak self] in
            self?.focusEditor()
        }
        previewScrollView.documentView = previewView
        addSubview(previewScrollView)

        addResizeHandles()
        updateTextLayout()
    }

    private func addResizeHandles() {
        for handleType in ResizeHandleType.allCases {
            let handle = ResizeHandleView(frame: frame(for: handleType), handleType: handleType)
            handle.autoresizingMask = autoresizingMask(for: handleType)
            addSubview(handle)
        }
    }

    private func frame(for handleType: ResizeHandleType) -> NSRect {
        let horizontalLength = max(0, bounds.width - resizeHandleSize * 2)
        let verticalLength = max(0, bounds.height - resizeHandleSize * 2)

        switch handleType {
        case .topLeft:
            return NSRect(x: 0, y: bounds.height - resizeHandleSize, width: resizeHandleSize, height: resizeHandleSize)
        case .top:
            return NSRect(x: resizeHandleSize, y: bounds.height - resizeEdgeThickness, width: horizontalLength, height: resizeEdgeThickness)
        case .topRight:
            return NSRect(x: bounds.width - resizeHandleSize, y: bounds.height - resizeHandleSize, width: resizeHandleSize, height: resizeHandleSize)
        case .right:
            return NSRect(x: bounds.width - resizeEdgeThickness, y: resizeHandleSize, width: resizeEdgeThickness, height: verticalLength)
        case .bottomRight:
            return NSRect(x: bounds.width - resizeHandleSize, y: 0, width: resizeHandleSize, height: resizeHandleSize)
        case .bottom:
            return NSRect(x: resizeHandleSize, y: 0, width: horizontalLength, height: resizeEdgeThickness)
        case .bottomLeft:
            return NSRect(x: 0, y: 0, width: resizeHandleSize, height: resizeHandleSize)
        case .left:
            return NSRect(x: 0, y: resizeHandleSize, width: resizeEdgeThickness, height: verticalLength)
        }
    }

    private func autoresizingMask(for handleType: ResizeHandleType) -> NSView.AutoresizingMask {
        switch handleType {
        case .topLeft:
            return [.maxXMargin, .minYMargin]
        case .top:
            return [.width, .minYMargin]
        case .topRight:
            return [.minXMargin, .minYMargin]
        case .right:
            return [.minXMargin, .height]
        case .bottomRight:
            return [.minXMargin, .maxYMargin]
        case .bottom:
            return [.width, .maxYMargin]
        case .bottomLeft:
            return [.maxXMargin, .maxYMargin]
        case .left:
            return [.maxXMargin, .height]
        }
    }

    private func updateTextLayout() {
        updateTypography()
        let visibleWidth = max(0, scrollView.contentSize.width)
        let documentWidth = editor.preferredDocumentWidth(forVisibleWidth: visibleWidth)
        let documentHeight = max(scrollView.contentSize.height, editor.frame.height)

        editor.isHorizontallyResizable = documentWidth > visibleWidth + 1
        editor.textContainer?.widthTracksTextView = !editor.isHorizontallyResizable
        editor.textContainer?.containerSize = NSSize(width: documentWidth, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: max(0, scrollView.contentSize.height))
        editor.setFrameSize(NSSize(width: documentWidth, height: documentHeight))
        editor.refreshParagraphLayoutPreservingSelection()
        updateDisplayLayout()
    }

    private func updateTypography() {
        let effectiveFontSize = self.effectiveFontSize()
        editor.setDisplayFontSize(effectiveFontSize)
        previewView.backgroundFillColor = backgroundColor
        previewView.baseFontSize = effectiveFontSize
        zoomControl.setZoomScale(zoomScale)
    }

    private func effectiveFontSize() -> CGFloat {
        let adaptiveScale = adaptiveTextScale()
        return min(max(baseStickerFontSize * adaptiveScale * zoomScale, minimumStickerFontSize), maximumStickerFontSize)
    }

    private func adaptiveTextScale() -> CGFloat {
        let area = max(minimumStickerSize.width * minimumStickerSize.height, bounds.width * bounds.height)
        let baseArea = stickerSize * stickerSize
        return min(max(sqrt(area / baseArea), 0.82), 1.35)
    }

    func focusEditor() {
        setInteractionMode(.editing, focusEditor: true)
    }

    func showDisplay() {
        setInteractionMode(.display, focusEditor: false)
    }

    override func magnify(with event: NSEvent) {
        setZoomScale(zoomScale * (1 + event.magnification))
    }

    @objc private func zoomOut() {
        setZoomScale(zoomScale / 1.12)
    }

    @objc private func resetZoom() {
        setZoomScale(1)
    }

    @objc private func zoomIn() {
        setZoomScale(zoomScale * 1.12)
    }

    private func setZoomScale(_ scale: CGFloat) {
        let newScale = Self.clampedZoomScale(scale)
        guard abs(newScale - zoomScale) > 0.005 else {
            return
        }

        zoomScale = newScale
        updateTextLayout()
        onTextChanged?()
    }

    private static func clampedZoomScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumStickerZoomScale), maximumStickerZoomScale)
    }

    @objc private func closeSticker() {
        onClose?()
    }

    @objc private func toggleInteractionMode() {
        switch interactionMode {
        case .display:
            focusEditor()
        case .editing:
            showDisplay()
        }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard replacementString == "\n", affectedCharRange.length == 0 else {
            return true
        }

        return handleNumberedListReturn(in: textView, at: affectedCharRange)
    }

    private func handleNumberedListReturn(in textView: NSTextView, at affectedCharRange: NSRange) -> Bool {
        let nsString = textView.string as NSString
        guard affectedCharRange.location <= nsString.length else {
            return true
        }

        let currentLineRange = nsString.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
        let currentLineStart = currentLineRange.location
        let cursorOffsetInLine = affectedCharRange.location - currentLineStart
        let linePrefix = nsString.substring(with: NSRange(location: currentLineStart, length: cursorOffsetInLine))

        if let match = MarkdownParagraphLayout.checklistMatch(in: linePrefix) {
            if match.body.trimmingCharacters(in: .whitespaces).isEmpty {
                textView.insertText("", replacementRange: NSRange(location: currentLineStart, length: cursorOffsetInLine))
                finishHandledTextChange(in: textView)
                return false
            }

            textView.insertText("\n\(match.indent)\(match.marker) [ ] ", replacementRange: affectedCharRange)
            finishHandledTextChange(in: textView)
            return false
        }

        if let match = MarkdownParagraphLayout.bulletListMatch(in: linePrefix) {
            if match.body.trimmingCharacters(in: .whitespaces).isEmpty {
                textView.insertText("", replacementRange: NSRange(location: currentLineStart, length: cursorOffsetInLine))
                finishHandledTextChange(in: textView)
                return false
            }

            textView.insertText("\n\(match.indent)\(match.marker) ", replacementRange: affectedCharRange)
            finishHandledTextChange(in: textView)
            return false
        }

        guard let match = MarkdownParagraphLayout.orderedListMatch(in: linePrefix) else {
            let indent = MarkdownParagraphLayout.leadingWhitespace(in: linePrefix)
            let bodyStart = linePrefix.index(linePrefix.startIndex, offsetBy: indent.count)
            let body = linePrefix[bodyStart...].trimmingCharacters(in: .whitespaces)

            if !indent.isEmpty && !body.isEmpty {
                textView.insertText("\n\(indent)", replacementRange: affectedCharRange)
                finishHandledTextChange(in: textView)
                return false
            }

            return true
        }

        if match.body.trimmingCharacters(in: .whitespaces).isEmpty {
            textView.insertText("", replacementRange: NSRange(location: currentLineStart, length: cursorOffsetInLine))
            finishHandledTextChange(in: textView)
            return false
        }

        let nextNumber = match.number + 1
        let nextPrefix = "\(match.indent)\(nextNumber)\(match.separator) "
        textView.insertText("\n\(nextPrefix)", replacementRange: affectedCharRange)
        finishHandledTextChange(in: textView)
        return false
    }

    private func finishHandledTextChange(in textView: NSTextView) {
        (textView as? StickerTextView)?.renumberOrderedListsPreservingSelection()
        updateTextLayout()
        onTextChanged?()
    }

    func textDidChange(_ notification: Notification) {
        (notification.object as? StickerTextView)?.renumberOrderedListsPreservingSelection()
        updateTextLayout()
        onTextChanged?()
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard !isChangingInteractionMode else { return }
        setInteractionMode(.editing, focusEditor: false)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard !isChangingInteractionMode else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.interactionMode == .editing,
                  self.window?.firstResponder !== self.editor else {
                return
            }
            self.showDisplay()
        }
    }

    private func updateDisplayLayout() {
        let visibleWidth = max(0, previewScrollView.contentSize.width)
        guard visibleWidth > 0 else {
            return
        }

        let previewSize = previewView.configure(markdown: editor.string, visibleWidth: visibleWidth)
        previewView.setFrameSize(previewSize)

        guard interactionMode == .display else {
            previewScrollView.isHidden = true
            scrollView.isHidden = false
            return
        }

        previewScrollView.isHidden = false
        scrollView.isHidden = true
    }

    func showPreviewAfterEditing() {
        showDisplay()
    }

    private func setInteractionMode(_ mode: StickerInteractionMode, focusEditor shouldFocusEditor: Bool) {
        if interactionMode == mode, !(mode == .editing && shouldFocusEditor) {
            updateDisplayLayout()
            return
        }

        isChangingInteractionMode = true
        interactionMode = mode
        modeButton.mode = mode

        switch mode {
        case .display:
            editor.isEditable = false
            editor.isSelectable = true
            updateDisplayLayout()
            scrollView.isHidden = true
            previewScrollView.isHidden = false
            window?.makeFirstResponder(previewView)
        case .editing:
            editor.isEditable = true
            editor.isSelectable = true
            previewScrollView.isHidden = true
            scrollView.isHidden = false
            if shouldFocusEditor {
                window?.makeFirstResponder(editor)
            }
        }

        isChangingInteractionMode = false
    }
}

private enum MarkdownTableAlignment {
    case left
    case center
    case right

    var textAlignment: NSTextAlignment {
        switch self {
        case .left:
            return .left
        case .center:
            return .center
        case .right:
            return .right
        }
    }
}

private enum MarkdownPreviewTextStyle {
    case heading(level: Int)
    case body
}

private struct MarkdownPreviewTextBlock {
    let text: String
    let style: MarkdownPreviewTextStyle
}

private struct MarkdownPreviewTable {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
}

private enum MarkdownPipeTableParser {
    static func parseTable(lines: [String], start: Int) -> (table: MarkdownPreviewTable, nextIndex: Int)? {
        guard start + 1 < lines.count,
              isTableRow(lines[start]),
              isSeparatorLine(lines[start + 1]) else {
            return nil
        }

        let headers = cells(in: lines[start]).map { $0.trimmingCharacters(in: .whitespaces) }
        let separatorCells = cells(in: lines[start + 1])
        guard headers.count >= 2, separatorCells.count >= 2 else {
            return nil
        }

        let columnCount = headers.count
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, isTableRow(lines[index]) {
            rows.append(normalizedCells(cells(in: lines[index]), columnCount: columnCount))
            index += 1
        }

        let alignments = (0..<columnCount).map { columnIndex in
            columnIndex < separatorCells.count ? alignment(for: separatorCells[columnIndex]) : .left
        }

        return (
            table: MarkdownPreviewTable(
                headers: Array(headers.prefix(columnCount)),
                alignments: alignments,
                rows: rows
            ),
            nextIndex: index
        )
    }

    static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), !isSeparatorLine(trimmed) else {
            return false
        }

        let rowCells = cells(in: trimmed)
        return rowCells.count >= 2 && rowCells.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func isSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else {
            return false
        }

        let separatorCells = cells(in: trimmed)
        guard separatorCells.count >= 2 else {
            return false
        }

        return separatorCells.allSatisfy(isSeparatorCell)
    }

    static func cells(in line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)[...]
        if trimmed.first == "|" {
            trimmed = trimmed.dropFirst()
        }
        if trimmed.last == "|" {
            trimmed = trimmed.dropLast()
        }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }

    private static func normalizedCells(_ cells: [String], columnCount: Int) -> [String] {
        var values = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        if values.count < columnCount {
            values.append(contentsOf: Array(repeating: "", count: columnCount - values.count))
        }
        return Array(values.prefix(columnCount))
    }

    private static func alignment(for marker: String) -> MarkdownTableAlignment {
        let visibleCharacters = marker.filter { !$0.isWhitespace }
        let starts = visibleCharacters.first.map(isAlignmentColon) ?? false
        let ends = visibleCharacters.last.map(isAlignmentColon) ?? false

        if starts && ends {
            return .center
        }
        if ends {
            return .right
        }
        return .left
    }

    private static func isSeparatorCell(_ cell: String) -> Bool {
        let marker = cell.trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty else {
            return false
        }

        var dashScore = 0
        var hasWideDash = false
        for character in marker {
            if character.isWhitespace || isAlignmentColon(character) {
                continue
            }
            guard let dash = separatorDash(for: character) else {
                return false
            }
            dashScore += dash.score
            hasWideDash = hasWideDash || dash.isWide
        }

        return dashScore >= 3 || (hasWideDash && dashScore >= 2)
    }

    private static func isAlignmentColon(_ character: Character) -> Bool {
        character == ":" || character == "："
    }

    private static func separatorDash(for character: Character) -> (score: Int, isWide: Bool)? {
        switch character {
        case "-":
            return (1, false)
        case "‐", "‑", "‒", "–", "—", "―", "−", "﹘", "﹣", "－", "─", "━":
            return (2, true)
        default:
            return nil
        }
    }
}

private enum MarkdownParagraphLayout {
    struct OrderedListMatch {
        let indent: String
        let numberText: String
        let number: Int
        let separator: String
        let spacing: String
        let body: String
    }

    struct ChecklistMatch {
        let indent: String
        let marker: String
        let spacing: String
        let body: String
    }

    struct BulletListMatch {
        let indent: String
        let marker: String
        let spacing: String
        let body: String
    }

    private static let orderedListLineRegex = try? NSRegularExpression(pattern: #"^([ \t]*)(\d+)([.)、])([ \t]*)(.*)$"#)
    private static let checklistLineRegex = try? NSRegularExpression(pattern: #"^([ \t]*)([-*•])([ \t]+\[[ xX]\][ \t]*)(.*)$"#)
    private static let bulletLineRegex = try? NSRegularExpression(pattern: #"^([ \t]*)([-*•])([ \t]+)(.*)$"#)

    static func defaultParagraphStyle(font: NSFont, lineSpacing: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = lineSpacing
        style.defaultTabInterval = max(24, measuredWidth(of: "    ", font: font))
        style.tabStops = []
        return style
    }

    static func paragraphStyle(for line: String, font: NSFont, lineSpacing: CGFloat = 0, maxContinuationIndent: CGFloat) -> NSParagraphStyle {
        let style = defaultParagraphStyle(font: font, lineSpacing: lineSpacing).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = min(measuredWidth(of: continuationPrefix(for: line), font: font), maxContinuationIndent)
        return style
    }

    static func contentLine(in text: NSString, paragraphRange: NSRange) -> String {
        var contentLength = paragraphRange.length
        while contentLength > 0 {
            let tail = text.substring(with: NSRange(location: paragraphRange.location + contentLength - 1, length: 1))
            if tail == "\n" || tail == "\r" {
                contentLength -= 1
            } else {
                break
            }
        }

        return text.substring(with: NSRange(location: paragraphRange.location, length: contentLength))
    }

    static func leadingWhitespace(in line: String) -> String {
        var indent = ""
        for character in line {
            if character == " " || character == "\t" {
                indent.append(character)
            } else {
                break
            }
        }
        return indent
    }

    static func measuredWidth(of prefix: String, font: NSFont) -> CGFloat {
        guard !prefix.isEmpty else {
            return 0
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var width: CGFloat = 0
        for character in prefix {
            let printable = character == "\t" ? "    " : String(character)
            width += (printable as NSString).size(withAttributes: attributes).width
        }
        return ceil(width)
    }

    static func indentationWidth(for indent: String) -> Int {
        indent.reduce(0) { total, character in
            total + (character == "\t" ? 4 : 1)
        }
    }

    static func orderedListMatch(in line: String) -> OrderedListMatch? {
        guard let regex = orderedListLineRegex else {
            return nil
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: fullRange),
              match.numberOfRanges == 6 else {
            return nil
        }

        let numberText = nsLine.substring(with: match.range(at: 2))
        guard let number = Int(numberText) else {
            return nil
        }

        return OrderedListMatch(
            indent: nsLine.substring(with: match.range(at: 1)),
            numberText: numberText,
            number: number,
            separator: nsLine.substring(with: match.range(at: 3)),
            spacing: nsLine.substring(with: match.range(at: 4)),
            body: nsLine.substring(with: match.range(at: 5))
        )
    }

    static func checklistMatch(in line: String) -> ChecklistMatch? {
        guard let regex = checklistLineRegex else {
            return nil
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: fullRange),
              match.numberOfRanges == 5 else {
            return nil
        }

        return ChecklistMatch(
            indent: nsLine.substring(with: match.range(at: 1)),
            marker: nsLine.substring(with: match.range(at: 2)),
            spacing: nsLine.substring(with: match.range(at: 3)),
            body: nsLine.substring(with: match.range(at: 4))
        )
    }

    static func bulletListMatch(in line: String) -> BulletListMatch? {
        guard let regex = bulletLineRegex else {
            return nil
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: fullRange),
              match.numberOfRanges == 5 else {
            return nil
        }

        return BulletListMatch(
            indent: nsLine.substring(with: match.range(at: 1)),
            marker: nsLine.substring(with: match.range(at: 2)),
            spacing: nsLine.substring(with: match.range(at: 3)),
            body: nsLine.substring(with: match.range(at: 4))
        )
    }

    private static func continuationPrefix(for line: String) -> String {
        if let match = orderedListMatch(in: line) {
            return "\(match.indent)\(match.numberText)\(match.separator)\(match.spacing)"
        }

        if let match = checklistMatch(in: line) {
            return "\(match.indent)\(match.marker)\(match.spacing)"
        }

        if let match = bulletListMatch(in: line) {
            return "\(match.indent)\(match.marker)\(match.spacing)"
        }

        return leadingWhitespace(in: line)
    }
}

private enum MarkdownPreviewBlock {
    case text(MarkdownPreviewTextBlock)
    case table(MarkdownPreviewTable)
    case spacer
}

final class MarkdownPreviewView: NSView {
    var onBeginEditing: (() -> Void)?
    var backgroundFillColor = NSColor(calibratedRed: 1.00, green: 0.97, blue: 0.76, alpha: 0.98)
    var baseFontSize: CGFloat = baseStickerFontSize

    private struct TextLayout {
        let attributedText: NSAttributedString
        let rect: NSRect
    }

    private struct TableLayout {
        let table: MarkdownPreviewTable
        let columnWidths: [CGFloat]
        let headerCells: [NSAttributedString]
        let rowCells: [[NSAttributedString]]
        let rowHeights: [CGFloat]
        let tableFrame: NSRect
    }

    private enum BlockLayout {
        case text(TextLayout)
        case table(TableLayout)
    }

    private struct Layout {
        let blocks: [BlockLayout]
        let size: NSSize
    }

    private let outerPadding: CGFloat = 16
    private let cellHorizontalPadding: CGFloat = 14
    private let cellVerticalPadding: CGFloat = 14
    private let textBlockGap: CGFloat = 12
    private let tableBlockGap: CGFloat = 16
    private let spacerHeight: CGFloat = 8
    private let minimumHeaderHeight: CGFloat = 28
    private let minimumBodyHeight: CGFloat = 34
    private let maximumRegularColumnWidth: CGFloat = 210
    private let maximumLongColumnWidth: CGFloat = 380
    private let gridColor = NSColor(calibratedWhite: 0.82, alpha: 0.75)
    private let rowGridColor = NSColor(calibratedWhite: 0.88, alpha: 0.70)
    private let textColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.08, alpha: 1.0)

    private var layout: Layout?
    private var sourceMarkdown = ""

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(markdown: String, visibleWidth: CGFloat) -> NSSize {
        sourceMarkdown = markdown
        let blocks = parseBlocks(from: markdown)
        let layout = makeLayout(for: blocks, visibleWidth: max(visibleWidth, 160))
        self.layout = layout
        needsDisplay = true
        return layout.size
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 3 {
            onBeginEditing?()
            return
        }

        window?.makeFirstResponder(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        if key == "e" {
            onBeginEditing?()
            return
        }

        if key == "c" {
            copyAll()
            return
        }

        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: #selector(beginEditingFromMenu), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        let copyItem = NSMenuItem(title: "Copy All", action: #selector(copyAllFromMenu), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = !sourceMarkdown.isEmpty
        menu.addItem(copyItem)
        return menu
    }

    @objc private func beginEditingFromMenu() {
        onBeginEditing?()
    }

    @objc private func copyAllFromMenu() {
        copyAll()
    }

    private func copyAll() {
        guard !sourceMarkdown.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sourceMarkdown, forType: .string)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else {
            return
        }

        backgroundFillColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()

        for block in layout.blocks {
            switch block {
            case .text(let textLayout):
                textLayout.attributedText.draw(with: textLayout.rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            case .table(let tableLayout):
                drawTable(tableLayout)
            }
        }
    }

    private func drawTable(_ layout: TableLayout) {
        let x = layout.tableFrame.minX
        var y = layout.tableFrame.minY

        backgroundFillColor.setFill()
        NSBezierPath(rect: layout.tableFrame).fill()

        drawCells(layout.headerCells, columnWidths: layout.columnWidths, tableX: x, rowY: y, rowHeight: layout.rowHeights[0], alignments: layout.table.alignments)

        gridColor.setStroke()
        drawHorizontalLine(x: x, y: y + layout.rowHeights[0], width: layout.tableFrame.width, lineWidth: 1.2)
        y += layout.rowHeights[0]

        for (rowIndex, cells) in layout.rowCells.enumerated() {
            let rowHeight = layout.rowHeights[rowIndex + 1]
            drawCells(cells, columnWidths: layout.columnWidths, tableX: x, rowY: y, rowHeight: rowHeight, alignments: layout.table.alignments)
            rowGridColor.setStroke()
            drawHorizontalLine(x: x, y: y + rowHeight, width: layout.tableFrame.width, lineWidth: 0.8)
            y += rowHeight
        }
    }

    private func drawCells(_ cells: [NSAttributedString], columnWidths: [CGFloat], tableX: CGFloat, rowY: CGFloat, rowHeight: CGFloat, alignments: [MarkdownTableAlignment]) {
        var x = tableX

        for index in cells.indices {
            let width = columnWidths[index]
            let availableWidth = max(0, width - cellHorizontalPadding * 2)
            let measuredHeight = ceil(cells[index].boundingRect(
                with: NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)
            let cellRect = NSRect(
                x: x + cellHorizontalPadding,
                y: rowY + max(cellVerticalPadding / 2, (rowHeight - measuredHeight) / 2),
                width: availableWidth,
                height: max(measuredHeight + 2, rowHeight - cellVerticalPadding)
            )

            cells[index].draw(with: cellRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            x += width
        }
    }

    private func drawHorizontalLine(x: CGFloat, y: CGFloat, width: CGFloat, lineWidth: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.move(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x + width, y: y))
        path.stroke()
    }

    private func makeLayout(for blocks: [MarkdownPreviewBlock], visibleWidth: CGFloat) -> Layout {
        var y = outerPadding
        var maxContentWidth = visibleWidth
        var layouts: [BlockLayout] = []
        var lastWasSpacer = false

        for block in blocks {
            switch block {
            case .spacer:
                if !lastWasSpacer, !layouts.isEmpty {
                    y += spacerHeight
                    lastWasSpacer = true
                }
            case .text(let textBlock):
                let textWidth = max(80, visibleWidth - outerPadding * 2)
                let attributedText = attributedTextBlock(textBlock, wrapWidth: textWidth)
                let measuredHeight = ceil(attributedText.boundingRect(
                    with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height)
                let rect = NSRect(x: outerPadding, y: y, width: textWidth, height: measuredHeight + 2)
                layouts.append(.text(TextLayout(attributedText: attributedText, rect: rect)))
                y += rect.height + textBlockGap
                lastWasSpacer = false
            case .table(let table):
                let tableLayout = makeTableLayout(for: table, y: y, visibleWidth: visibleWidth)
                layouts.append(.table(tableLayout))
                y += tableLayout.tableFrame.height + tableBlockGap
                maxContentWidth = max(maxContentWidth, tableLayout.tableFrame.maxX + outerPadding)
                lastWasSpacer = false
            }
        }

        let contentHeight = layouts.isEmpty ? outerPadding * 2 : max(outerPadding * 2, y - min(textBlockGap, tableBlockGap) + outerPadding)
        return Layout(blocks: layouts, size: NSSize(width: max(visibleWidth, maxContentWidth), height: contentHeight))
    }

    private func makeTableLayout(for table: MarkdownPreviewTable, y: CGFloat, visibleWidth: CGFloat) -> TableLayout {
        let headerFont = NSFont.systemFont(ofSize: scaledFontSize(16), weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: scaledFontSize(16), weight: .regular)
        let boldBodyFont = NSFont.systemFont(ofSize: scaledFontSize(16), weight: .semibold)

        let headerCells = table.headers.enumerated().map { index, text in
            attributedInlineText(text, font: headerFont, boldFont: headerFont, alignment: table.alignments[index])
        }
        let rowCells = table.rows.map { row in
            row.enumerated().map { index, text in
                attributedInlineText(text, font: bodyFont, boldFont: boldBodyFont, alignment: table.alignments[index])
            }
        }

        var columnWidths = Array(repeating: CGFloat(0), count: table.headers.count)
        for index in table.headers.indices {
            let isLongColumn = index == table.headers.count - 1 || table.headers[index].contains("目的")
            let maxColumnWidth = isLongColumn ? maximumLongColumnWidth : maximumRegularColumnWidth
            let minColumnWidth: CGFloat = index == 0 ? 150 : 96
            let values = [headerCells[index]] + rowCells.map { $0[index] }
            let measuredWidth = values.map { ceil($0.size().width) }.max() ?? minColumnWidth
            columnWidths[index] = min(max(measuredWidth + cellHorizontalPadding * 2, minColumnWidth), maxColumnWidth)
        }

        let naturalTableWidth = columnWidths.reduce(0, +)
        let minimumVisibleTableWidth = max(0, visibleWidth - outerPadding * 2)
        if naturalTableWidth < minimumVisibleTableWidth, !columnWidths.isEmpty {
            let extra = (minimumVisibleTableWidth - naturalTableWidth) / CGFloat(columnWidths.count)
            columnWidths = columnWidths.map { $0 + extra }
        }

        let tableWidth = columnWidths.reduce(0, +)

        var rowHeights = [max(minimumHeaderHeight, measuredRowHeight(cells: headerCells, widths: columnWidths))]
        for row in rowCells {
            rowHeights.append(max(minimumBodyHeight, measuredRowHeight(cells: row, widths: columnWidths)))
        }

        return TableLayout(
            table: table,
            columnWidths: columnWidths,
            headerCells: headerCells,
            rowCells: rowCells,
            rowHeights: rowHeights,
            tableFrame: NSRect(x: outerPadding, y: y, width: tableWidth, height: rowHeights.reduce(0, +))
        )
    }

    private func measuredRowHeight(cells: [NSAttributedString], widths: [CGFloat]) -> CGFloat {
        zip(cells, widths).map { cell, width in
            ceil(cell.boundingRect(
                with: NSSize(width: max(0, width - cellHorizontalPadding * 2), height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height) + cellVerticalPadding * 2
        }.max() ?? minimumBodyHeight
    }

    private func scaledFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size * baseFontSize / baseStickerFontSize, minimumStickerFontSize), maximumStickerFontSize + 4)
    }

    private func attributedTextBlock(_ block: MarkdownPreviewTextBlock, wrapWidth: CGFloat) -> NSAttributedString {
        switch block.style {
        case .heading(let level):
            let size: CGFloat
            switch level {
            case 1:
                size = 24
            case 2:
                size = 21
            default:
                size = 18
            }
            let font = NSFont.systemFont(ofSize: scaledFontSize(size), weight: .bold)
            return attributedInlineText(block.text, font: font, boldFont: font, alignment: .left, lineSpacing: 3)
        case .body:
            let font = NSFont.systemFont(ofSize: scaledFontSize(16), weight: .regular)
            let boldFont = NSFont.systemFont(ofSize: scaledFontSize(16), weight: .semibold)
            let text = NSMutableAttributedString(attributedString: attributedInlineText(block.text, font: font, boldFont: boldFont, alignment: .left, lineSpacing: 4))
            applyBodyParagraphStyles(to: text, font: font, wrapWidth: wrapWidth)
            return text
        }
    }

    private func applyBodyParagraphStyles(to attributedText: NSMutableAttributedString, font: NSFont, wrapWidth: CGFloat) {
        let nsText = attributedText.string as NSString
        var location = 0

        while location < nsText.length {
            let paragraphRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let line = MarkdownParagraphLayout.contentLine(in: nsText, paragraphRange: paragraphRange)
            attributedText.addAttribute(
                .paragraphStyle,
                value: paragraphStyle(forBodyLine: line, font: font, wrapWidth: wrapWidth),
                range: paragraphRange
            )
            location = paragraphRange.location + paragraphRange.length
        }
    }

    private func paragraphStyle(forBodyLine line: String, font: NSFont, wrapWidth: CGFloat) -> NSParagraphStyle {
        MarkdownParagraphLayout.paragraphStyle(for: line, font: font, lineSpacing: 4, maxContinuationIndent: max(0, wrapWidth - 48))
    }

    private func attributedInlineText(_ text: String, font: NSFont, boldFont: NSFont, alignment: MarkdownTableAlignment, lineSpacing: CGFloat = 2) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment.textAlignment
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = lineSpacing

        let result = NSMutableAttributedString()
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        let boldAttributes: [NSAttributedString.Key: Any] = [
            .font: boldFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        var remaining = text[...]
        while let start = remaining.range(of: "**") {
            result.append(NSAttributedString(string: String(remaining[..<start.lowerBound]), attributes: baseAttributes))
            let afterStart = remaining[start.upperBound...]
            guard let end = afterStart.range(of: "**") else {
                result.append(NSAttributedString(string: String(remaining[start.lowerBound...]), attributes: baseAttributes))
                return result
            }

            result.append(NSAttributedString(string: String(afterStart[..<end.lowerBound]), attributes: boldAttributes))
            remaining = afterStart[end.upperBound...]
        }

        result.append(NSAttributedString(string: String(remaining), attributes: baseAttributes))
        return result
    }

    private func parseBlocks(from markdown: String) -> [MarkdownPreviewBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [MarkdownPreviewBlock] = []
        var paragraphLines: [String] = []
        var lastAddedSpacer = false

        func flushParagraph() {
            let text = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            paragraphLines.removeAll()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            blocks.append(.text(MarkdownPreviewTextBlock(text: text, style: .body)))
            lastAddedSpacer = false
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                if !blocks.isEmpty, !lastAddedSpacer {
                    blocks.append(.spacer)
                    lastAddedSpacer = true
                }
                index += 1
                continue
            }

            if let parsedTable = MarkdownPipeTableParser.parseTable(lines: lines, start: index) {
                flushParagraph()
                blocks.append(.table(parsedTable.table))
                lastAddedSpacer = false
                index = parsedTable.nextIndex
                continue
            }

            if let heading = headingBlock(in: trimmed) {
                flushParagraph()
                blocks.append(.text(heading))
                lastAddedSpacer = false
                index += 1
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        while let last = blocks.last {
            if case .spacer = last {
                blocks.removeLast()
            } else {
                break
            }
        }

        return blocks
    }

    private func headingBlock(in trimmedLine: String) -> MarkdownPreviewTextBlock? {
        var level = 0
        for character in trimmedLine {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }

        guard (1...3).contains(level) else {
            return nil
        }

        let contentStart = trimmedLine.index(trimmedLine.startIndex, offsetBy: level)
        guard contentStart < trimmedLine.endIndex,
              trimmedLine[contentStart].isWhitespace else {
            return nil
        }

        let content = trimmedLine[contentStart...].trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else {
            return nil
        }

        return MarkdownPreviewTextBlock(text: content, style: .heading(level: level))
    }

}

final class StickerTextView: NSTextView {
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?
    var onFinishEditing: (() -> Void)?

    private struct CaretAnchor {
        let lineIndex: Int
        let distanceFromLineEnd: Int
    }

    private struct MarkdownTableBlock {
        let range: NSRange
        let rowRanges: [NSRange]
        let separatorRowIndex: Int
    }

    private var isRefreshingParagraphLayout = false
    private var isRenumberingOrderedLists = false

    private var displayFont: NSFont {
        font ?? NSFont.systemFont(ofSize: baseStickerFontSize)
    }

    private var tableFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: max(minimumStickerFontSize, (font?.pointSize ?? baseStickerFontSize) - 2), weight: .regular)
    }

    private var tableHeaderFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: max(minimumStickerFontSize, (font?.pointSize ?? baseStickerFontSize) - 2), weight: .semibold)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onFinishEditing?()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        if flags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onFinishEditing?()
            return
        }

        guard flags.contains(.command) else {
            super.keyDown(with: event)
            return
        }

        if key == "b" {
            wrapSelection(with: "**")
            return
        }

        if key == "i" {
            wrapSelection(with: "*")
            return
        }

        if key == "c" {
            copySelectedPlainText()
            return
        }

        if key == "x" {
            cutSelectedPlainText()
            return
        }

        if key == "v" {
            pastePlainTextFromPasteboard()
            return
        }

        if key == "a" {
            selectAllText()
            return
        }

        if key == "=" || key == "+" {
            onZoomIn?()
            return
        }

        if key == "-" || key == "_" {
            onZoomOut?()
            return
        }

        if key == "0" {
            onZoomReset?()
            return
        }

        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let hasSelection = selectedRange().length > 0
        let hasPasteText = NSPasteboard.general.string(forType: .string) != nil

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copyFromMenu), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = hasSelection
        menu.addItem(copyItem)

        let cutItem = NSMenuItem(title: "Cut", action: #selector(cutFromMenu), keyEquivalent: "")
        cutItem.target = self
        cutItem.isEnabled = hasSelection && isEditable
        menu.addItem(cutItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(pasteFromMenu), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = hasPasteText && isEditable
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAllFromMenu), keyEquivalent: "")
        selectAllItem.target = self
        selectAllItem.isEnabled = (string as NSString).length > 0
        menu.addItem(selectAllItem)

        return menu
    }

    override func insertTab(_ sender: Any?) {
        transformSelectedLines { "    \($0)" }
    }

    override func insertBacktab(_ sender: Any?) {
        transformSelectedLines { line in
            if line.hasPrefix("    ") {
                return String(line.dropFirst(4))
            }
            if line.hasPrefix("\t") || line.hasPrefix(" ") {
                return String(line.dropFirst(1))
            }
            return line
        }
    }

    private func wrapSelection(with marker: String) {
        let range = selectedRange()

        if range.length == 0 {
            insertText("\(marker)\(marker)", replacementRange: range)
            setSelectedRange(NSRange(location: range.location + (marker as NSString).length, length: 0))
            return
        }

        let nsString = string as NSString
        let selectedText = nsString.substring(with: range)
        let replacement = "\(marker)\(selectedText)\(marker)"
        guard shouldChangeText(in: range, replacementString: replacement) else {
            return
        }

        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (marker as NSString).length, length: (selectedText as NSString).length))
        refreshParagraphLayoutPreservingSelection()
    }

    @discardableResult
    private func copySelectedPlainText() -> Bool {
        let range = selectedRange()
        guard range.length > 0 else {
            return false
        }

        let selectedText = (string as NSString).substring(with: range)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
        return true
    }

    private func cutSelectedPlainText() {
        let range = selectedRange()
        guard isEditable, copySelectedPlainText() else {
            return
        }

        insertText("", replacementRange: range)
    }

    private func pastePlainTextFromPasteboard() {
        guard isEditable,
              let pastedText = NSPasteboard.general.string(forType: .string) else {
            return
        }

        insertText(pastedText, replacementRange: selectedRange())
    }

    private func selectAllText() {
        setSelectedRange(NSRange(location: 0, length: (string as NSString).length))
    }

    @objc private func copyFromMenu() {
        copySelectedPlainText()
    }

    @objc private func cutFromMenu() {
        cutSelectedPlainText()
    }

    @objc private func pasteFromMenu() {
        pastePlainTextFromPasteboard()
    }

    @objc private func selectAllFromMenu() {
        selectAllText()
    }

    func setDisplayFontSize(_ pointSize: CGFloat) {
        let currentSize = font?.pointSize ?? baseStickerFontSize
        guard abs(currentSize - pointSize) > 0.1 else {
            return
        }

        font = .systemFont(ofSize: pointSize)
        refreshParagraphLayoutPreservingSelection()
    }

    func refreshParagraphLayoutPreservingSelection() {
        guard !isRefreshingParagraphLayout, let textStorage else {
            return
        }

        isRefreshingParagraphLayout = true
        defer { isRefreshingParagraphLayout = false }

        let currentSelection = selectedRange()
        let currentTypingAttributes = typingAttributes
        let nsText = string as NSString
        let fullLength = nsText.length
        let tableBlocks = markdownTableBlocks(in: nsText)

        if fullLength == 0 {
            typingAttributes = currentTypingAttributes.merging([.paragraphStyle: defaultParagraphStyle()]) { _, new in new }
            return
        }

        textStorage.beginEditing()
        let fullRange = NSRange(location: 0, length: fullLength)
        textStorage.addAttribute(.font, value: font ?? NSFont.systemFont(ofSize: baseStickerFontSize), range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: textColor ?? NSColor.labelColor, range: fullRange)
        textStorage.removeAttribute(.backgroundColor, range: fullRange)

        var location = 0
        while location < fullLength {
            let paragraphRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let line = MarkdownParagraphLayout.contentLine(in: nsText, paragraphRange: paragraphRange)
            let paragraphStyle = paragraphStyle(for: line)
            textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraphRange)
            location = paragraphRange.location + paragraphRange.length
        }

        applyMarkdownTableAttributes(tableBlocks, in: textStorage)
        textStorage.endEditing()

        setSelectedRange(NSRange(
            location: min(currentSelection.location, (string as NSString).length),
            length: min(currentSelection.length, max(0, (string as NSString).length - min(currentSelection.location, (string as NSString).length)))
        ))
        typingAttributes = currentTypingAttributes.merging([.paragraphStyle: paragraphStyleForCurrentLine()]) { _, new in new }
    }

    private func paragraphStyleForCurrentLine() -> NSParagraphStyle {
        let nsText = string as NSString
        guard nsText.length > 0 else {
            return defaultParagraphStyle()
        }

        let location = min(selectedRange().location, nsText.length)
        let paragraphRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        return paragraphStyle(for: MarkdownParagraphLayout.contentLine(in: nsText, paragraphRange: paragraphRange))
    }

    private func paragraphStyle(for line: String) -> NSParagraphStyle {
        MarkdownParagraphLayout.paragraphStyle(
            for: line,
            font: displayFont,
            maxContinuationIndent: maxContinuationIndent()
        )
    }

    private func defaultParagraphStyle() -> NSParagraphStyle {
        MarkdownParagraphLayout.defaultParagraphStyle(font: displayFont)
    }

    private func maxContinuationIndent() -> CGFloat {
        let containerWidth = textContainer?.containerSize.width ?? bounds.width
        guard containerWidth.isFinite, containerWidth > 0 else {
            return CGFloat.greatestFiniteMagnitude
        }

        return max(0, containerWidth - 48)
    }

    func preferredDocumentWidth(forVisibleWidth visibleWidth: CGFloat) -> CGFloat {
        let nsText = string as NSString
        let tableBlocks = markdownTableBlocks(in: nsText)
        guard !tableBlocks.isEmpty else {
            return visibleWidth
        }

        let maxTableWidth = tableBlocks
            .flatMap(\.rowRanges)
            .map { rowRange -> CGFloat in
                let line = MarkdownParagraphLayout.contentLine(in: nsText, paragraphRange: rowRange)
                return measuredTableWidth(of: line)
            }
            .max() ?? visibleWidth

        return max(visibleWidth, min(maxTableWidth + 18, 2400))
    }

    private func applyMarkdownTableAttributes(_ tableBlocks: [MarkdownTableBlock], in textStorage: NSTextStorage) {
        let tableForeground = NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.18, alpha: 1.0)
        let separatorForeground = NSColor(calibratedRed: 0.45, green: 0.46, blue: 0.42, alpha: 0.95)

        for block in tableBlocks {
            textStorage.addAttribute(.font, value: tableFont, range: block.range)
            textStorage.addAttribute(.foregroundColor, value: tableForeground, range: block.range)
            textStorage.removeAttribute(.backgroundColor, range: block.range)

            if let headerRange = block.rowRanges.first {
                textStorage.addAttribute(.font, value: tableHeaderFont, range: headerRange)
            }

            let separatorRange = block.rowRanges[block.separatorRowIndex]
            textStorage.addAttribute(.foregroundColor, value: separatorForeground, range: separatorRange)
        }
    }

    private func markdownTableBlocks(in text: NSString) -> [MarkdownTableBlock] {
        let lines = lineRecords(in: text)
        guard lines.count >= 2 else {
            return []
        }

        var blocks: [MarkdownTableBlock] = []
        var index = 0

        while index < lines.count - 1 {
            guard MarkdownPipeTableParser.isTableRow(lines[index].content),
                  MarkdownPipeTableParser.isSeparatorLine(lines[index + 1].content) else {
                index += 1
                continue
            }

            let startIndex = index
            var endIndex = index + 1
            while endIndex + 1 < lines.count && MarkdownPipeTableParser.isTableRow(lines[endIndex + 1].content) {
                endIndex += 1
            }

            let start = lines[startIndex].range.location
            let end = lines[endIndex].range.location + lines[endIndex].range.length
            blocks.append(MarkdownTableBlock(
                range: NSRange(location: start, length: end - start),
                rowRanges: lines[startIndex...endIndex].map(\.range),
                separatorRowIndex: 1
            ))
            index = endIndex + 1
        }

        return blocks
    }

    private func lineRecords(in text: NSString) -> [(range: NSRange, content: String)] {
        let fullLength = text.length
        guard fullLength > 0 else {
            return []
        }

        var records: [(range: NSRange, content: String)] = []
        var location = 0

        while location < fullLength {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            records.append((range: lineRange, content: MarkdownParagraphLayout.contentLine(in: text, paragraphRange: lineRange)))
            location = lineRange.location + lineRange.length
        }

        return records
    }

    private func measuredTableWidth(of line: String) -> CGFloat {
        (line as NSString).size(withAttributes: [.font: tableFont]).width
    }

    func renumberOrderedListsPreservingSelection() {
        guard !isRenumberingOrderedLists else {
            return
        }

        isRenumberingOrderedLists = true
        defer { isRenumberingOrderedLists = false }

        let original = string
        let rewritten = renumberedOrderedListText(from: original)
        guard rewritten != original else {
            refreshParagraphLayoutPreservingSelection()
            return
        }

        let currentSelection = selectedRange()
        let caretAnchor = currentSelection.length == 0 ? caretAnchor(in: original, location: currentSelection.location) : nil
        let fullRange = NSRange(location: 0, length: (original as NSString).length)
        guard shouldChangeText(in: fullRange, replacementString: rewritten) else {
            return
        }

        textStorage?.replaceCharacters(in: fullRange, with: rewritten)
        didChangeText()

        if let caretAnchor {
            setSelectedRange(NSRange(location: location(for: caretAnchor, in: rewritten), length: 0))
            refreshParagraphLayoutPreservingSelection()
            return
        }

        let rewrittenLength = (rewritten as NSString).length
        let location = min(currentSelection.location, rewrittenLength)
        let length = min(currentSelection.length, max(0, rewrittenLength - location))
        setSelectedRange(NSRange(location: location, length: length))
        refreshParagraphLayoutPreservingSelection()
    }

    private func transformSelectedLines(_ transform: (String) -> String) {
        let nsString = string as NSString
        guard nsString.length > 0 else {
            insertText("    ", replacementRange: selectedRange())
            return
        }

        let selected = selectedRange()
        let caretAnchor = selected.length == 0 ? caretAnchor(in: string, location: selected.location) : nil
        var effectiveLength = selected.length
        if effectiveLength > 0,
           selected.location + effectiveLength <= nsString.length,
           nsString.substring(with: NSRange(location: selected.location + effectiveLength - 1, length: 1)) == "\n" {
            effectiveLength -= 1
        }

        let safeLocation = min(selected.location, nsString.length)
        let lineRange = nsString.lineRange(for: NSRange(location: safeLocation, length: effectiveLength))
        let block = nsString.substring(with: lineRange)
        let parts = block.components(separatedBy: "\n")
        let hasTrailingNewline = block.hasSuffix("\n")

        var transformedParts: [String] = []
        transformedParts.reserveCapacity(parts.count)

        for index in parts.indices {
            let isTrailingEmptyLine = hasTrailingNewline && index == parts.count - 1
            transformedParts.append(isTrailingEmptyLine ? parts[index] : transform(parts[index]))
        }

        let replacement = transformedParts.joined(separator: "\n")
        guard shouldChangeText(in: lineRange, replacementString: replacement) else {
            return
        }

        textStorage?.replaceCharacters(in: lineRange, with: replacement)
        didChangeText()

        if let caretAnchor {
            setSelectedRange(NSRange(location: location(for: caretAnchor, in: string), length: 0))
        } else {
            setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
        }

        renumberOrderedListsPreservingSelection()
    }

    private func renumberedOrderedListText(from text: String) -> String {
        var countersByIndentWidth: [Int: Int] = [:]
        var didChange = false
        let lines = text.components(separatedBy: "\n")
        let rewrittenLines = lines.map { line -> String in
            guard let match = MarkdownParagraphLayout.orderedListMatch(in: line) else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    countersByIndentWidth.removeAll()
                } else {
                    let lineIndentWidth = MarkdownParagraphLayout.indentationWidth(for: MarkdownParagraphLayout.leadingWhitespace(in: line))
                    for key in Array(countersByIndentWidth.keys) where key >= lineIndentWidth {
                        countersByIndentWidth.removeValue(forKey: key)
                    }
                }
                return line
            }

            let indentWidth = MarkdownParagraphLayout.indentationWidth(for: match.indent)

            for key in Array(countersByIndentWidth.keys) where key > indentWidth {
                countersByIndentWidth.removeValue(forKey: key)
            }

            let nextNumber = (countersByIndentWidth[indentWidth] ?? 0) + 1
            countersByIndentWidth[indentWidth] = nextNumber

            if match.numberText != "\(nextNumber)" {
                didChange = true
            }

            return "\(match.indent)\(nextNumber)\(match.separator)\(match.spacing)\(match.body)"
        }

        return didChange ? rewrittenLines.joined(separator: "\n") : text
    }

    private func caretAnchor(in text: String, location: Int) -> CaretAnchor {
        let nsText = text as NSString
        let safeLocation = min(max(0, location), nsText.length)
        var lineIndex = 0
        var index = 0

        while index < safeLocation {
            if nsText.substring(with: NSRange(location: index, length: 1)) == "\n" {
                lineIndex += 1
            }
            index += 1
        }

        let lineEnd = contentLineEnd(in: nsText, around: safeLocation)
        return CaretAnchor(lineIndex: lineIndex, distanceFromLineEnd: max(0, lineEnd - safeLocation))
    }

    private func location(for anchor: CaretAnchor, in text: String) -> Int {
        let nsText = text as NSString
        var currentLineIndex = 0
        var lineStart = 0
        var index = 0

        while index < nsText.length && currentLineIndex < anchor.lineIndex {
            if nsText.substring(with: NSRange(location: index, length: 1)) == "\n" {
                currentLineIndex += 1
                lineStart = index + 1
            }
            index += 1
        }

        guard currentLineIndex == anchor.lineIndex else {
            return nsText.length
        }

        let lineEnd = contentLineEnd(in: nsText, around: lineStart)
        return max(lineStart, lineEnd - anchor.distanceFromLineEnd)
    }

    private func contentLineEnd(in text: NSString, around location: Int) -> Int {
        let safeLocation = min(max(0, location), text.length)
        let lineRange = text.lineRange(for: NSRange(location: safeLocation, length: 0))
        var lineEnd = lineRange.location + lineRange.length

        if lineEnd > lineRange.location,
           lineEnd <= text.length,
           text.substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n" {
            lineEnd -= 1
        }

        return lineEnd
    }
}

private enum ResizeHandleType: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

final class ResizeHandleView: NSView {
    private let handleType: ResizeHandleType
    private var dragStartMouseLocation = NSPoint.zero
    private var dragStartFrame = NSRect.zero

    fileprivate init(frame frameRect: NSRect, handleType: ResizeHandleType) {
        self.handleType = handleType
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }

        let currentMouseLocation = NSEvent.mouseLocation
        let deltaX = currentMouseLocation.x - dragStartMouseLocation.x
        let deltaY = currentMouseLocation.y - dragStartMouseLocation.y
        let resizedFrame = frameResized(from: dragStartFrame, deltaX: deltaX, deltaY: deltaY)
        window.setFrame(resizedFrame, display: true)
    }

    private func frameResized(from frame: NSRect, deltaX: CGFloat, deltaY: CGFloat) -> NSRect {
        var resizedFrame = frame

        switch handleType {
        case .topLeft:
            resizeLeftEdge(&resizedFrame, deltaX: deltaX, originalFrame: frame)
            resizeTopEdge(&resizedFrame, deltaY: deltaY, originalFrame: frame)
        case .top:
            resizeTopEdge(&resizedFrame, deltaY: deltaY, originalFrame: frame)
        case .topRight:
            resizeRightEdge(&resizedFrame, deltaX: deltaX, originalFrame: frame)
            resizeTopEdge(&resizedFrame, deltaY: deltaY, originalFrame: frame)
        case .right:
            resizeRightEdge(&resizedFrame, deltaX: deltaX, originalFrame: frame)
        case .bottomRight:
            resizeRightEdge(&resizedFrame, deltaX: deltaX, originalFrame: frame)
            resizeBottomEdge(&resizedFrame, deltaY: deltaY, originalFrame: frame)
        case .bottom:
            resizeBottomEdge(&resizedFrame, deltaY: deltaY, originalFrame: frame)
        case .bottomLeft:
            resizeLeftEdge(&resizedFrame, deltaX: deltaX, originalFrame: frame)
            resizeBottomEdge(&resizedFrame, deltaY: deltaY, originalFrame: frame)
        case .left:
            resizeLeftEdge(&resizedFrame, deltaX: deltaX, originalFrame: frame)
        }

        return resizedFrame
    }

    private func resizeLeftEdge(_ frame: inout NSRect, deltaX: CGFloat, originalFrame: NSRect) {
        let proposedWidth = originalFrame.width - deltaX
        if proposedWidth >= minimumStickerSize.width {
            frame.origin.x = originalFrame.origin.x + deltaX
            frame.size.width = proposedWidth
        } else {
            frame.origin.x = originalFrame.maxX - minimumStickerSize.width
            frame.size.width = minimumStickerSize.width
        }
    }

    private func resizeRightEdge(_ frame: inout NSRect, deltaX: CGFloat, originalFrame: NSRect) {
        frame.size.width = max(minimumStickerSize.width, originalFrame.width + deltaX)
    }

    private func resizeTopEdge(_ frame: inout NSRect, deltaY: CGFloat, originalFrame: NSRect) {
        frame.size.height = max(minimumStickerSize.height, originalFrame.height + deltaY)
    }

    private func resizeBottomEdge(_ frame: inout NSRect, deltaY: CGFloat, originalFrame: NSRect) {
        let proposedHeight = originalFrame.height - deltaY
        if proposedHeight >= minimumStickerSize.height {
            frame.origin.y = originalFrame.origin.y + deltaY
            frame.size.height = proposedHeight
        } else {
            frame.origin.y = originalFrame.maxY - minimumStickerSize.height
            frame.size.height = minimumStickerSize.height
        }
    }
}

final class DragHeaderView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
