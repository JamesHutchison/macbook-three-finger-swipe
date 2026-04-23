import AppKit
import Darwin

private let debugLogging = false

private enum NavigationDirection {
    case back
    case forward
}

private struct MTVector {
    var x: Float
    var y: Float
}

private struct MTReadout {
    var position: MTVector
    var velocity: MTVector
}

private struct MTContact {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTReadout
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mm: MTReadout
    var zero2A: Int32
    var zero2B: Int32
    var density: Float
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (
    MTDeviceRef,
    UnsafeMutableRawPointer,
    Int32,
    Double,
    Int32
) -> Int32

@_silgen_name("MTDeviceCreateList")
private func MTDeviceCreateList() -> Unmanaged<CFArray>

@_silgen_name("MTRegisterContactFrameCallback")
private func MTRegisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTContactCallback)

@_silgen_name("MTDeviceStart")
@discardableResult
private func MTDeviceStart(_ device: MTDeviceRef, _ mode: Int32) -> Int32

private let rawTouchCallback: MTContactCallback = { _, contacts, contactCount, timestamp, frame in
    AppDelegate.shared?.handleRawTouchFrame(
        contacts: contacts,
        contactCount: Int(contactCount),
        timestamp: timestamp,
        frame: frame
    )
    return 0
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private var swipeMonitor: Any?
    private var gestureBoundaryMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var eventProbeMonitor: Any?
    private var multitouchDeviceList: NSArray?
    private var multitouchDevices: [MTDeviceRef] = []
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let targetBundleID = "com.microsoft.VSCode"
    private let targetBundleIDInsiders = "com.microsoft.VSCodeInsiders"
    private var lastSwipeAt: TimeInterval = 0
    private var lastScrollLogAt: TimeInterval = 0
    private var lastEventProbeLogAt: TimeInterval = 0
    private var lastRawTouchLogAt: TimeInterval = 0
    private var accumulatedHorizontalScroll: CGFloat = 0
    private var rawGestureStartCentroid: CGPoint?
    private var rawGestureLastCentroid: CGPoint?
    private var rawGestureFingerCount = 0
    private let swipeDebounce: TimeInterval = 0.3
    private let scrollLogInterval: TimeInterval = 0.15
    private let eventProbeLogInterval: TimeInterval = 0.2
    private let rawTouchLogInterval: TimeInterval = 0.15
    private let horizontalScrollThreshold: CGFloat = 35
    private let rawSwipeThreshold: CGFloat = 0.12
    private var didStart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        AppDelegate.shared = self
        debugLog("Launching VS Code swipe monitor")
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        ensureAccessibility()
        startMonitoring()
        startRawMultitouchMonitoring()
    }

    private func ensureAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        if !isTrusted {
            log("Accessibility is not trusted. Enable this runner in System Settings > Privacy & Security > Accessibility, then restart.")
        } else {
            debugLog("Accessibility trusted")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
        }

        if let gestureBoundaryMonitor {
            NSEvent.removeMonitor(gestureBoundaryMonitor)
        }

        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor)
        }

        if let eventProbeMonitor {
            NSEvent.removeMonitor(eventProbeMonitor)
        }

        multitouchDevices.removeAll()
        multitouchDeviceList = nil
    }

    private func setupMenuBar() {
        if let button = statusItem.button {
            button.title = "⇆"
            button.toolTip = "VS Code Swipe Back/Forward"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About SwipeToVSCode", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func startMonitoring() {
        swipeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.swipe]) { [weak self] event in
            self?.handleSwipe(event)
        }

        if debugLogging {
            gestureBoundaryMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.beginGesture, .endGesture]) { [weak self] event in
                self?.handleGestureBoundary(event)
            }

            scrollWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                self?.handleScrollWheel(event)
            }

            eventProbeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .any) { [weak self] event in
                self?.handleEventProbe(event)
            }
        }

        debugLog("Global swipe monitor installed")
    }

    private func startRawMultitouchMonitoring() {
        let devicesArray = MTDeviceCreateList().takeRetainedValue() as NSArray
        multitouchDeviceList = devicesArray
        multitouchDevices = devicesArray.compactMap { device in
            guard CFGetTypeID(device as CFTypeRef) > 0 else { return nil }
            return Unmanaged.passUnretained(device as AnyObject).toOpaque()
        }

        guard !multitouchDevices.isEmpty else {
            log("Raw multitouch: no devices found")
            return
        }

        for device in multitouchDevices {
            MTRegisterContactFrameCallback(device, rawTouchCallback)
            let result = MTDeviceStart(device, 0)
            if result == 0 {
                debugLog("Raw multitouch: started device \(device) with result \(result)")
            } else {
                log("Raw multitouch: failed to start device \(device) with result \(result)")
            }
        }
    }

    fileprivate func handleRawTouchFrame(
        contacts: UnsafeMutableRawPointer,
        contactCount: Int,
        timestamp: Double,
        frame: Int32
    ) {
        let typedContacts = contacts.bindMemory(to: MTContact.self, capacity: contactCount)
        let activeContacts = (0..<contactCount).map { typedContacts[$0] }.filter(isPlausibleContact)
        let now = ProcessInfo.processInfo.systemUptime

        if debugLogging && now - lastRawTouchLogAt >= rawTouchLogInterval {
            lastRawTouchLogAt = now
            let summary = activeContacts
                .prefix(5)
                .map { contact in
                    "id=\(contact.identifier) finger=\(contact.fingerID) x=\(String(format: "%.3f", contact.normalized.position.x)) y=\(String(format: "%.3f", contact.normalized.position.y)) vx=\(String(format: "%.3f", contact.normalized.velocity.x)) vy=\(String(format: "%.3f", contact.normalized.velocity.y)) size=\(String(format: "%.3f", contact.size))"
                }
                .joined(separator: "; ")
            log("Raw touch frame: frame=\(frame), timestamp=\(timestamp), contacts=\(activeContacts.count), \(summary)")
        }

        handleRawTouchNavigation(activeContacts)
    }

    private func handleRawTouchNavigation(_ contacts: [MTContact]) {
        guard isVSCodeFrontmost() else {
            resetRawGesture()
            return
        }

        guard contacts.count == 3 else {
            if rawGestureFingerCount == 3 {
                finishRawGesture()
            }
            resetRawGesture()
            return
        }

        let centroid = centroid(for: contacts)
        rawGestureFingerCount = 3

        if rawGestureStartCentroid == nil {
            rawGestureStartCentroid = centroid
            debugLog("Raw three-finger gesture began at x=\(String(format: "%.3f", centroid.x)), y=\(String(format: "%.3f", centroid.y))")
        }

        rawGestureLastCentroid = centroid
    }

    private func finishRawGesture() {
        guard let start = rawGestureStartCentroid, let end = rawGestureLastCentroid else { return }

        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        debugLog("Raw three-finger gesture ended: deltaX=\(String(format: "%.3f", deltaX)), deltaY=\(String(format: "%.3f", deltaY))")

        guard abs(deltaX) >= rawSwipeThreshold else {
            debugLog("Ignoring raw three-finger gesture: horizontal delta \(String(format: "%.3f", abs(deltaX))) is below threshold \(String(format: "%.3f", rawSwipeThreshold))")
            return
        }

        guard abs(deltaX) > abs(deltaY) * 1.5 else {
            debugLog("Ignoring raw three-finger gesture: movement is not horizontal enough")
            return
        }

        triggerNavigation(deltaX > 0 ? .forward : .back, source: "raw three-finger swipe")
    }

    private func resetRawGesture() {
        rawGestureStartCentroid = nil
        rawGestureLastCentroid = nil
        rawGestureFingerCount = 0
    }

    private func centroid(for contacts: [MTContact]) -> CGPoint {
        let total = contacts.reduce(CGPoint.zero) { partial, contact in
            CGPoint(
                x: partial.x + CGFloat(contact.normalized.position.x),
                y: partial.y + CGFloat(contact.normalized.position.y)
            )
        }

        return CGPoint(x: total.x / CGFloat(contacts.count), y: total.y / CGFloat(contacts.count))
    }

    private func isPlausibleContact(_ contact: MTContact) -> Bool {
        let x = contact.normalized.position.x
        let y = contact.normalized.position.y

        return x >= 0 && x <= 1 &&
            y >= 0 && y <= 1 &&
            contact.size > 0.01 &&
            contact.size < 20
    }

    private func isVSCodeFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }

        return bundleID == targetBundleID || bundleID == targetBundleIDInsiders
    }

    private func handleGestureBoundary(_ event: NSEvent) {
        let eventName: String
        switch event.type {
        case .beginGesture:
            eventName = "touch/gesture began"
        case .endGesture:
            eventName = "touch/gesture ended"
        default:
            eventName = "gesture boundary"
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appName = frontmostApp?.localizedName ?? "Unknown"
        let bundleID = frontmostApp?.bundleIdentifier ?? "no-bundle-id"
        debugLog("\(eventName): frontmost=\(appName) (\(bundleID)), phase=\(event.phase.rawValue), momentumPhase=\(event.momentumPhase.rawValue)")
    }

    private func handleScrollWheel(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let hasPhaseBoundary = event.phase.contains(.began) || event.phase.contains(.ended) || event.phase.contains(.cancelled)
        handleHorizontalScrollNavigation(event)

        guard hasPhaseBoundary || now - lastScrollLogAt >= scrollLogInterval else { return }
        lastScrollLogAt = now

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appName = frontmostApp?.localizedName ?? "Unknown"
        let bundleID = frontmostApp?.bundleIdentifier ?? "no-bundle-id"
        debugLog(
            "Scroll wheel event: frontmost=\(appName) (\(bundleID)), " +
            "deltaX=\(event.deltaX), deltaY=\(event.deltaY), " +
            "scrollingDeltaX=\(event.scrollingDeltaX), scrollingDeltaY=\(event.scrollingDeltaY), " +
            "phase=\(phaseDescription(event.phase)), momentumPhase=\(phaseDescription(event.momentumPhase)), " +
            "precise=\(event.hasPreciseScrollingDeltas), inverted=\(event.isDirectionInvertedFromDevice)"
        )
    }

    private func handleHorizontalScrollNavigation(_ event: NSEvent) {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            debugLog("Ignoring horizontal scroll: could not determine frontmost app")
            return
        }

        let appName = frontmostApp.localizedName ?? "Unknown"
        let bundleID = frontmostApp.bundleIdentifier ?? ""
        guard bundleID == targetBundleID || bundleID == targetBundleIDInsiders else {
            return
        }

        let horizontalDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX
        let verticalDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY

        if event.phase.contains(.began) {
            accumulatedHorizontalScroll = 0
        }

        guard abs(horizontalDelta) > abs(verticalDelta) * 1.5 else {
            if abs(horizontalDelta) > 0 {
                debugLog("Ignoring horizontal scroll candidate: vertical movement dominates for \(appName)")
            }
            return
        }

        accumulatedHorizontalScroll += horizontalDelta
        debugLog("Horizontal scroll candidate for VS Code: deltaX=\(horizontalDelta), accumulated=\(accumulatedHorizontalScroll), threshold=\(horizontalScrollThreshold)")

        guard abs(accumulatedHorizontalScroll) >= horizontalScrollThreshold else { return }

        let direction = accumulatedHorizontalScroll > 0 ? NavigationDirection.forward : .back
        accumulatedHorizontalScroll = 0
        triggerNavigation(direction, source: "horizontal scroll")
    }

    private func handleEventProbe(_ event: NSEvent) {
        guard shouldLogProbeEvent(event) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastEventProbeLogAt >= eventProbeLogInterval else { return }
        lastEventProbeLogAt = now

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appName = frontmostApp?.localizedName ?? "Unknown"
        let bundleID = frontmostApp?.bundleIdentifier ?? "no-bundle-id"
        debugLog(
            "Event probe: type=\(eventTypeDescription(event.type)), frontmost=\(appName) (\(bundleID)), " +
            "deltaX=\(event.deltaX), deltaY=\(event.deltaY), " +
            "phase=\(phaseDescription(event.phase)), momentumPhase=\(phaseDescription(event.momentumPhase))"
        )
    }

    private func handleSwipe(_ event: NSEvent) {
        debugLog("Swipe detected: deltaX=\(event.deltaX), deltaY=\(event.deltaY), phase=\(event.phase.rawValue), momentumPhase=\(event.momentumPhase.rawValue)")

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            debugLog("Ignoring swipe: could not determine frontmost app")
            return
        }

        let appName = frontmostApp.localizedName ?? "Unknown"
        let bundleID = frontmostApp.bundleIdentifier ?? ""
        guard bundleID == targetBundleID || bundleID == targetBundleIDInsiders else {
            debugLog("Ignoring swipe: frontmost app is \(appName) (\(bundleID)), not VS Code")
            return
        }

        if event.deltaX > 0 {
            triggerNavigation(.forward, source: "swipe right")
        } else if event.deltaX < 0 {
            triggerNavigation(.back, source: "swipe left")
        } else {
            debugLog("Ignoring swipe: deltaX is zero")
        }
    }

    private func triggerNavigation(_ direction: NavigationDirection, source: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let secondsSinceLastSwipe = now - lastSwipeAt
        guard secondsSinceLastSwipe >= swipeDebounce else {
            debugLog("Ignoring \(source): debounced after \(String(format: "%.3f", secondsSinceLastSwipe))s")
            return
        }

        lastSwipeAt = now

        switch direction {
        case .back:
            debugLog("VS Code \(source) detected. Sending Ctrl+- (Back)")
            updateStatus("Back")
            sendShortcut(key: 27, modifiers: [.maskControl]) // Ctrl+- => Back
        case .forward:
            debugLog("VS Code \(source) detected. Sending Ctrl+Shift+- (Forward)")
            updateStatus("Forward")
            sendShortcut(key: 27, modifiers: [.maskControl, .maskShift]) // Ctrl+Shift+- => Forward
        }
    }

    private func sendShortcut(key: CGKeyCode, modifiers: CGEventFlags) {
        guard AXIsProcessTrusted() else {
            log("Not sending shortcut: Accessibility permission is not trusted")
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)

        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = modifiers
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = modifiers

        debugLog("Posting keyboard event: key=\(key), modifiers=\(modifiers.rawValue)")
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func updateStatus(_ direction: String) {
        statusItem.button?.toolTip = "Last VS Code swipe: \(direction)"
    }

    private func phaseDescription(_ phase: NSEvent.Phase) -> String {
        var names: [String] = []

        if phase.contains(.began) {
            names.append("began")
        }

        if phase.contains(.stationary) {
            names.append("stationary")
        }

        if phase.contains(.changed) {
            names.append("changed")
        }

        if phase.contains(.ended) {
            names.append("ended")
        }

        if phase.contains(.cancelled) {
            names.append("cancelled")
        }

        if phase.contains(.mayBegin) {
            names.append("mayBegin")
        }

        return names.isEmpty ? "none(\(phase.rawValue))" : names.joined(separator: "|")
    }

    private func shouldLogProbeEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .scrollWheel, .swipe, .beginGesture, .endGesture:
            return false
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return false
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return false
        case .keyDown, .keyUp, .flagsChanged:
            return false
        default:
            return true
        }
    }

    private func eventTypeDescription(_ type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown:
            return "leftMouseDown"
        case .leftMouseUp:
            return "leftMouseUp"
        case .rightMouseDown:
            return "rightMouseDown"
        case .rightMouseUp:
            return "rightMouseUp"
        case .mouseMoved:
            return "mouseMoved"
        case .leftMouseDragged:
            return "leftMouseDragged"
        case .rightMouseDragged:
            return "rightMouseDragged"
        case .mouseEntered:
            return "mouseEntered"
        case .mouseExited:
            return "mouseExited"
        case .mouseCancelled:
            return "mouseCancelled"
        case .keyDown:
            return "keyDown"
        case .keyUp:
            return "keyUp"
        case .flagsChanged:
            return "flagsChanged"
        case .appKitDefined:
            return "appKitDefined"
        case .systemDefined:
            return "systemDefined"
        case .applicationDefined:
            return "applicationDefined"
        case .periodic:
            return "periodic"
        case .cursorUpdate:
            return "cursorUpdate"
        case .scrollWheel:
            return "scrollWheel"
        case .tabletPoint:
            return "tabletPoint"
        case .tabletProximity:
            return "tabletProximity"
        case .otherMouseDown:
            return "otherMouseDown"
        case .otherMouseUp:
            return "otherMouseUp"
        case .otherMouseDragged:
            return "otherMouseDragged"
        case .gesture:
            return "gesture"
        case .magnify:
            return "magnify"
        case .swipe:
            return "swipe"
        case .rotate:
            return "rotate"
        case .beginGesture:
            return "beginGesture"
        case .endGesture:
            return "endGesture"
        case .smartMagnify:
            return "smartMagnify"
        case .quickLook:
            return "quickLook"
        case .pressure:
            return "pressure"
        case .directTouch:
            return "directTouch"
        case .changeMode:
            return "changeMode"
        @unknown default:
            return "unknown(\(type.rawValue))"
        }
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] \(message)")
        fflush(stdout)
    }

    private func debugLog(_ message: String) {
        guard debugLogging else { return }
        log(message)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "About SwipeToVSCode"
        alert.informativeText = """
        Three-finger swipe back/forward for VS Code on macOS.

        Written by Codex.
        Directed by James Hutchison.

        Licensed under the MIT License.

        Want to configure it? Have AI go change the code.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        debugLog("Quitting VS Code swipe monitor")
        NSApp.terminate(nil)
    }
}

if debugLogging {
    print("Starting SwipeToVSCode main")
    fflush(stdout)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
delegate.start()
app.run()
