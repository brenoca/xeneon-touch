// xeneon-touch: make the CORSAIR XENEON EDGE touch panel behave like a touchscreen on macOS.
//
// macOS has no touchscreen support, so the panel's touches drive the cursor as if it were a
// trackpad/mouse spanning the whole desktop. This agent seizes the touch controller (WCH 27C0:0859)
// so macOS stops interpreting it, maps each touch to the Edge's own screen bounds, and posts real
// mouse events: tap = click, double tap = double click, drag = drag, hold = press, two fingers = scroll.
//
// Needs: Input Monitoring (to seize the HID device) and Accessibility (to post events).
// Usage: xeneon-touch [--debug]

import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

let vendorID = 0x27C0
let productID = 0x0859
let displayName = "XENEON EDGE"

// Logical maxima from the controller's report descriptor (same for the digitizer and mouse reports).
let maxX = 0x3FFF
let maxY = 0x257F

let debug = CommandLine.arguments.contains("--debug")
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Display mapping

func edgeDisplay() -> CGDirectDisplayID? {
    for screen in NSScreen.screens where screen.localizedName.uppercased().contains(displayName) {
        return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
    return nil
}

var cachedDisplay: CGDirectDisplayID?

/// Normalized panel coords (0...1, panel-native orientation) -> global screen point on the Edge.
func screenPoint(nx: Double, ny: Double) -> CGPoint? {
    guard let id = cachedDisplay ?? edgeDisplay() else { return nil }
    cachedDisplay = id
    let b = CGDisplayBounds(id)
    var (u, v) = (nx, ny)
    switch Int(CGDisplayRotation(id)) {
    case 90: (u, v) = (1 - ny, nx)
    case 180: (u, v) = (1 - nx, 1 - ny)
    case 270: (u, v) = (ny, 1 - nx)
    default: break
    }
    let x = b.minX + min(max(u, 0), 1) * (b.width - 1)
    let y = b.minY + min(max(v, 0), 1) * (b.height - 1)
    return CGPoint(x: x, y: y)
}

// MARK: - Event posting

let source = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
}

func postScroll(dx: Double, dy: Double) {
    guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                          wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
    e.post(tap: .cghidEventTap)
}

// MARK: - Gesture state machine
//
// A touch doesn't press the button right away, so a scroll never starts with a stray click:
//   lift before moving         -> click (double click if quick and close to the previous one)
//   move > slop or hold > 300ms -> button down, then drag
//   second finger              -> scroll by the centroid's movement, no click

let slop: Double = 10          // px before a touch becomes a drag
let holdDelay: Double = 0.3    // s before a still touch becomes a press
let doubleTime: Double = 0.4
let doubleDist: Double = 20

enum Phase { case idle, pending, pressed, scrolling }
var phase = Phase.idle
var start = CGPoint.zero, last = CGPoint.zero
var startTime = 0.0
var lastClickTime = 0.0, lastClickPoint = CGPoint.zero, clickCount: Int64 = 1
var holdTimer: Timer?

func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

func press() {
    holdTimer?.invalidate()
    let now = ProcessInfo.processInfo.systemUptime
    clickCount = (now - lastClickTime < doubleTime && dist(start, lastClickPoint) < doubleDist) ? clickCount + 1 : 1
    post(.leftMouseDown, start, clicks: clickCount)
    if last != start { post(.leftMouseDragged, last, clicks: clickCount) }
    phase = .pressed
}

/// Feed the current set of touching points (screen coords). Empty = all fingers lifted.
func update(_ points: [CGPoint]) {
    let now = ProcessInfo.processInfo.systemUptime
    switch (phase, points.count) {
    case (.idle, 0): return
    case (.idle, 1):
        start = points[0]; last = start; startTime = now; phase = .pending
        post(.mouseMoved, start)
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { _ in
            if phase == .pending { press() }
        }
    case (.idle, _), (.pending, 2...):
        holdTimer?.invalidate()
        last = centroid(points); phase = .scrolling
    case (.pending, 1):
        last = points[0]
        if dist(start, last) > slop { press() }
    case (.pending, 0):
        press()
        post(.leftMouseUp, last, clicks: clickCount)
        lastClickTime = now; lastClickPoint = start
        phase = .idle
    case (.pressed, 1...):
        let p = points[0]
        if p != last { last = p; post(.leftMouseDragged, p, clicks: clickCount) }
    case (.pressed, 0):
        post(.leftMouseUp, last, clicks: clickCount)
        lastClickTime = now; lastClickPoint = start
        phase = .idle
    case (.scrolling, 2...):
        let c = centroid(points)
        postScroll(dx: c.x - last.x, dy: c.y - last.y)
        last = c
    case (.scrolling, 1): break  // lifting one finger of two: keep scrolling state until all are up
    case (.scrolling, 0): phase = .idle
    default: break
    }
}

func centroid(_ ps: [CGPoint]) -> CGPoint {
    CGPoint(x: ps.map(\.x).reduce(0, +) / Double(ps.count), y: ps.map(\.y).reduce(0, +) / Double(ps.count))
}

// MARK: - HID report parsing

func u16(_ r: UnsafePointer<UInt8>, _ i: Int) -> Int { Int(r[i]) | Int(r[i + 1]) << 8 }

func handleReport(_ r: UnsafePointer<UInt8>, _ len: Int) {
    if debug { log((0..<len).map { String(format: "%02x", r[$0]) }.joined(separator: " ")) }
    guard len > 0 else { return }
    var points: [CGPoint] = []
    switch r[0] {
    case 0x0D:  // digitizer: 6-byte finger slots [tip|id<<4, x16, y16]
        let slots = min(10, (len - 1 - 3) / 6)  // trailing scan time (2) + contact count (1)
        for s in 0..<max(slots, 0) {
            let i = 1 + s * 6
            if r[i] & 0x01 != 0,
               let p = screenPoint(nx: Double(u16(r, i + 1)) / Double(maxX), ny: Double(u16(r, i + 3)) / Double(maxY)) {
                points.append(p)
            }
        }
    case 0x07:  // absolute mouse fallback: [buttons, x16, y16, wheel]
        guard len >= 6 else { return }
        if r[1] & 0x01 != 0,
           let p = screenPoint(nx: Double(u16(r, 2)) / Double(maxX), ny: Double(u16(r, 4)) / Double(maxY)) {
            points.append(p)
        }
    default:
        return
    }
    update(points)
}

// MARK: - Device setup

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)

var buffers: [UnsafeMutablePointer<UInt8>] = []

let matched: IOHIDDeviceCallback = { _, _, _, device in
    let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
    let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
    // Only the digitizer (0x0D/0x04) and the mouse (0x01/0x02) interfaces; leave the vendor one alone.
    guard (page == 0x0D && usage == 0x04) || (page == 0x01 && usage == 0x02) else { return }
    let rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    guard rc == kIOReturnSuccess else {
        log("cannot seize interface \(page)/\(usage): 0x\(String(UInt32(bitPattern: rc), radix: 16)) — grant Input Monitoring")
        return
    }
    let size = 64
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    buffers.append(buf)
    IOHIDDeviceRegisterInputReportCallback(device, buf, size, { _, _, _, _, _, report, len in
        handleReport(UnsafePointer(report), len)
    }, nil)
    log("seized touch interface \(page)/\(usage)")
}

IOHIDManagerRegisterDeviceMatchingCallback(manager, matched, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, _ in log("touch interface removed") }, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                       object: nil, queue: .main) { _ in cachedDisplay = nil }

// Trigger the system permission prompts on first run (no-ops once granted).
if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { log("warning: Input Monitoring not granted") }
let axPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([axPrompt: true] as CFDictionary) {
    log("warning: Accessibility not granted — clicks will be dropped")
}
if edgeDisplay() == nil { log("warning: no display named \(displayName) found") }
log("xeneon-touch running")

_ = NSApplication.shared  // screen-change notifications need an app object
CFRunLoopRun()
