import Foundation
import Darwin
import IOKit.hid
import WheelCore

func number(_ d: IOHIDDevice, _ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0 }
func string(_ d: IOHIDDevice, _ key: String) -> String { IOHIDDeviceGetProperty(d, key as CFString) as? String ?? "unknown" }
func hex(_ n: Int) -> String { String(format: "0x%04x", n) }
func elements(_ d: IOHIDDevice) -> [IOHIDElement] { IOHIDDeviceCopyMatchingElements(d, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? [] }
func isInput(_ e: IOHIDElement) -> Bool { let t = IOHIDElementGetType(e); return t == kIOHIDElementTypeInput_Misc || t == kIOHIDElementTypeInput_Button || t == kIOHIDElementTypeInput_Axis }
func describe(_ e: IOHIDElement) -> String {
    "cookie=\(IOHIDElementGetCookie(e)) type=\(IOHIDElementGetType(e).rawValue) page=\(hex(Int(IOHIDElementGetUsagePage(e)))) usage=\(hex(Int(IOHIDElementGetUsage(e)))) report=\(IOHIDElementGetReportID(e)) bits=\(IOHIDElementGetReportSize(e)) count=\(IOHIDElementGetReportCount(e)) range=\(IOHIDElementGetLogicalMin(e))...\(IOHIDElementGetLogicalMax(e))"
}
final class Capture {
    var count = 0
    var seen: [UInt32: Int] = [:]
    var ranges: [UInt32: ClosedRange<Int>] = [:]
    var reports: [UInt32: ReportSummary] = [:]
    var bufferCapacity = 0
    var errors = 0
    var skipped = 0
    func report(id: UInt32, bytes: [UInt8]) {
        if reports[id] == nil { reports[id] = ReportSummary() }
        reports[id]!.record(bytes)
    }
    func cachedStates(_ device: IOHIDDevice, phase: String) {
        for e in elements(device).filter(isInput) {
            let storage = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            defer { storage.deallocate() }
            // SDK kIOHIDDeviceGetValueWithoutUpdate: cached only, never request a report.
            let result = IOHIDDeviceGetValueWithOptions(device, e, storage, 0x00040000)
            let value = result == kIOReturnSuccess ? storage.pointee.takeUnretainedValue() : nil
            if let value, IOHIDValueGetLength(value) <= MemoryLayout<Int>.size {
                print("CACHE \(phase) \(describe(e)) raw=\(IOHIDValueGetIntegerValue(value)) timestamp=\(IOHIDValueGetTimeStamp(value)) (cached, may be stale)")
            } else { print("CACHE \(phase) \(describe(e)) unavailable status=\(hex(Int(result)))") }
        }
    }
    func summary(_ device: IOHIDDevice) {
        for e in elements(device).filter(isInput) {
            let cookie = IOHIDElementGetCookie(e)
            print("ELEMENT \(describe(e)) observed=\(seen[cookie].map(String.init) ?? "none") range=\(ranges[cookie].map { "\($0.lowerBound)...\($0.upperBound)" } ?? "none")")
        }
        for id in reports.keys.sorted() {
            let r = reports[id]!
            print("REPORT id=\(id) count=\(r.count) lengths=\(r.lengths.sorted()) changedByteOffsets=\(r.changedOffsets.sorted())")
            print("  first=\(r.first.map { String(format: "%02x", $0) }.joined(separator: " "))")
            print("  last=\(r.last.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
        print("Finished: \(count) scalar input callbacks, \(seen.count) observed elements, \(reports.values.reduce(0) { $0 + $1.count }) raw input reports; callbackErrors=\(errors) skippedValues=\(skipped). Unobserved does not mean zero.")
    }
    func receive(_ value: IOHIDValue) {
        let e = IOHIDValueGetElement(value)
        guard isInput(e), IOHIDValueGetLength(value) <= MemoryLayout<Int>.size else { skipped += 1; return }
        let raw = IOHIDValueGetIntegerValue(value), cookie = IOHIDElementGetCookie(e)
        count += 1
        let previous = ranges[cookie] ?? raw...raw
        ranges[cookie] = min(previous.lowerBound, raw)...max(previous.upperBound, raw)
        guard seen[cookie] != raw else { return }
        seen[cookie] = raw
        let s = InputSample(page: IOHIDElementGetUsagePage(e), usage: IOHIDElementGetUsage(e), raw: raw, minimum: IOHIDElementGetLogicalMin(e), maximum: IOHIDElementGetLogicalMax(e))
        print("t=\(IOHIDValueGetTimeStamp(value)) cookie=\(cookie) \(s.label) raw=\(raw) normalized=\(s.normalized.map { String(format: "%.4f", $0) } ?? "n/a")")
    }
}
setbuf(stdout, nil) // Readiness must be visible immediately, including redirected logs.
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "list"
if command == "--help" || command == "help" {
    print("crossover-ffb list | inspect | watch [seconds 1...300]\nRead-only Logitech G923 PS (046d:c266). list enumerates all Logitech HID metadata. inspect lists G923 elements. watch waits for Enter in a terminal, then counts down 3 seconds. It opens only the joystick collection, non-exclusively; no output/feature reports. Axis names are HID usages, physical pedal mapping requires manual observation.")
    exit(0)
}
if command == "bridge-probe" {
    // Without touching the wheel: publish fake centred input and print what the game requests.
    let seconds = args.count == 2 ? Double(args[1]) ?? 10 : 10
    do {
        let bridge = try SharedBridge()
        var input = BridgeInput(); input.connected = true; input.steering = 40000
        let end = Date().addingTimeInterval(seconds)
        var last = ""
        while Date() < end {
            bridge.publish(input)
            if let s = bridge.readForce() {
                let line = "pid=\(s.processID) acquired=\(s.acquired) gain=\(s.deviceGain) effects=" + s.effects.map { "\($0.kind)\($0.playing ? "▶" : "■")\($0.params[0])" }.joined(separator: ",")
                if line != last { print(line); last = line }
            }
            usleep(2000)
        }
    } catch { fputs("bridge-probe: \(error)\n", stderr); exit(1) }
    exit(0)
}
if command == "games" {
    // What the app's Games tab would show, without changing anything.
    let library = GameLibrary()
    let installer = BridgeInstaller(payload: (try? Data(contentsOf: URL(fileURLWithPath: "bridge/build/dinput8.dll"))) ?? Data())
    for game in library.discover() {
        print("\(game.name) [\(game.source)] \(installer.status(game))\n  exe: \(game.executable.path)\n  prefix: \(game.prefix.url.path)")
    }
    print("Prefixes:"); for p in library.prefixes() { print("  \(p.label): \(p.url.path)") }
    exit(0)
}
if command == "install" || command == "uninstall", args.count == 2 {
    // Same installer as the app's Games tab; the argument matches a discovered game's name.
    let installer = BridgeInstaller(payload: (try? Data(contentsOf: URL(fileURLWithPath: "bridge/build/dinput8.dll"))) ?? Data())
    let matches = GameLibrary().discover().filter { $0.name.localizedCaseInsensitiveContains(args[1]) }
    guard matches.count == 1, let game = matches.first else { fputs("Need exactly one game matching \(args[1]); found \(matches.map(\.name))\n", stderr); exit(2) }
    do { try command == "install" ? installer.install(game) : installer.uninstall(game) }
    catch { fputs("\(game.name): \(error.localizedDescription)\n", stderr); exit(1) }
    print("\(game.name): \(installer.status(game))")
    exit(0)
}
if command == "trueforce-probe" {
    // Bring up the G923 TrueForce stream, hold it silent (zero torque, no vibration) for
    // the given seconds, optionally with a faint 40 Hz buzz, then stop. Reports write results.
    let seconds = args.count >= 2 ? Double(args[1]) ?? 2 : 2
    let buzz = args.contains("--buzz")
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046d, kIOHIDProductIDKey: 0xc266,
                                            kIOHIDPrimaryUsagePageKey: 0xfffd, kIOHIDPrimaryUsageKey: 0xfd01] as CFDictionary)
    guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else { fputs("No G923 TrueForce interface found\n", stderr); exit(1) }
    let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard opened == kIOReturnSuccess else { fputs(String(format: "Open failed 0x%08x\n", UInt32(bitPattern: opened)), stderr); exit(1) }
    var failures = 0, sent = 0
    func send(_ p: [UInt8]) {
        let r = p.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, $0.baseAddress!, $0.count) }
        sent += 1
        if r != kIOReturnSuccess { failures += 1; if failures <= 3 { print(String(format: "write type 0x%02x failed 0x%08x", p[4], UInt32(bitPattern: r))) } }
    }
    let t0 = ProcessInfo.processInfo.systemUptime
    for _ in 0..<2 { TrueForceProtocol.initPass().forEach(send) }
    print(String(format: "init: %d packets in %.0f ms, %d failed", sent, (ProcessInfo.processInfo.systemUptime - t0) * 1000, failures))
    var streamer = TrueForceStreamer(sequence: 68)
    var phase = 0.0, packets = 0
    let start = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - start < seconds {
        let samples = (0..<4).map { _ -> Double in phase += 40 / 4000; return buzz ? 0.12 * sin(2 * .pi * phase) : 0 }
        send(streamer.packet(torque: 0, samples: samples))
        packets += 1
        usleep(1000)
    }
    send(TrueForceProtocol.stop(sequence: streamer.nextSequence()))
    print(String(format: "stream: %d packets over %.1f s (%.0f/s), %d writes failed in total", packets, seconds, Double(packets) / seconds, failures))
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    exit(failures == 0 ? 0 : 1)
}
guard ["list", "inspect", "watch"].contains(command), args.count <= (command == "watch" ? 2 : 1) else { fputs("Invalid arguments; use --help\n", stderr); exit(2) }
let seconds = args.count == 2 ? Double(args[1]) ?? .nan : 15
guard seconds.isFinite, seconds >= 1, seconds <= 300 else { fputs("Duration must be 1...300 seconds\n", stderr); exit(2) }
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, (command == "list" ? [kIOHIDVendorIDKey: 0x046d] : [kIOHIDVendorIDKey: 0x046d, kIOHIDProductIDKey: 0xc266]) as CFDictionary)
// Enumeration does not open the manager or any device.
let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).sorted {
    (number($0, kIOHIDProductIDKey), number($0, kIOHIDPrimaryUsagePageKey), number($0, kIOHIDPrimaryUsageKey)) < (number($1, kIOHIDProductIDKey), number($1, kIOHIDPrimaryUsagePageKey), number($1, kIOHIDPrimaryUsageKey))
}
let wheels = devices.filter { number($0, kIOHIDProductIDKey) == 0xc266 }
for d in command == "list" ? devices : wheels {
    print("\(string(d, kIOHIDProductKey)) vid=\(hex(number(d, kIOHIDVendorIDKey))) pid=\(hex(number(d, kIOHIDProductIDKey))) transport=\(string(d, kIOHIDTransportKey)) page=\(hex(number(d, kIOHIDPrimaryUsagePageKey))) usage=\(hex(number(d, kIOHIDPrimaryUsageKey))) location=\(hex(number(d, kIOHIDLocationIDKey)))")
    if command == "inspect" {
        let found = elements(d)
        if found.isEmpty { print("  Elements unavailable or empty; sandbox/access restrictions may prevent inspection.") }
        for e in found { print("  \(describe(e))") }
    }
}
if wheels.isEmpty { print("No 046d:c266 G923 PS HID device found. Other variants/modes are not assumed compatible."); if command != "list" { exit(3) } }
if command == "watch" {
    let joysticks = wheels.filter { number($0, kIOHIDPrimaryUsagePageKey) == 1 && number($0, kIOHIDPrimaryUsageKey) == 4 }
    guard joysticks.count == 1, let device = joysticks.first else { fputs("Expected exactly one G923 joystick collection. No device opened.\n", stderr); exit(3) }
    if isatty(STDIN_FILENO) != 0 {
        print("Ready for input-only capture. Press Return when beside the wheel (Ctrl-C cancels).")
        guard readLine() != nil else { exit(2) }
    }
    for n in stride(from: 3, through: 1, by: -1) { print("Starting in \(n)…"); Thread.sleep(forTimeInterval: 1) }
    let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard status == kIOReturnSuccess else { fputs("Non-exclusive open failed: \(hex(Int(status))). No permissions changed.\n", stderr); exit(4) }
    let capture = Capture()
    let bufferSize = number(device, kIOHIDMaxInputReportSizeKey)
    guard bufferSize > 0, bufferSize <= 65536 else {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        fputs("Invalid maximum input report size; refusing capture.\n", stderr); exit(4)
    }
    capture.bufferCapacity = bufferSize
    let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { reportBuffer.deallocate() }
    IOHIDDeviceSetInputValueMatching(device, nil)
    IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, bufferSize, { context, result, _, type, id, bytes, length in
        guard let context else { return }
        let c = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
        guard result == kIOReturnSuccess, type == kIOHIDReportTypeInput, length >= 0, length <= c.bufferCapacity else { c.errors += 1; return }
        c.report(id: id, bytes: Array(UnsafeBufferPointer(start: bytes, count: length)))
    }, Unmanaged.passUnretained(capture).toOpaque())
    capture.cachedStates(device, phase: "before")
    IOHIDDeviceRegisterInputValueCallback(device, { context, result, _, value in
        guard let context else { return }
        let c = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
        guard result == kIOReturnSuccess else { c.errors += 1; return }
        c.receive(value)
    }, Unmanaged.passUnretained(capture).toOpaque())
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    print("CAPTURE ACTIVE: Listening non-exclusively for \(seconds)s; Ctrl-C exits. Only changed values printed. No motor commands.")
    CFRunLoopRunInMode(.defaultMode, seconds, false)
    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
    IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, bufferSize, nil, nil)
    capture.cachedStates(device, phase: "after")
    capture.summary(device)
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

}
