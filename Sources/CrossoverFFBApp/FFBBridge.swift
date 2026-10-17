import Foundation
import IOKit.hid
import WheelCore

/// Owns the wheel while running: forwards HID input into shared memory for the game and
/// plays the game's force-feedback effects on the motor at ~500 Hz. Runs on its own thread.
final class FFBBridge: @unchecked Sendable {
    struct Status: Equatable {
        var running = false
        var wheelConnected = false
        var gameProcessID: UInt32 = 0
        var gameActive = false
        var effectsPlaying = 0
        var output = 0.0
        var input = BridgeInput()
        /// Wheel position before the sensitivity curve, 0…65535.
        var rawSteering: UInt32 = 32768
        var leds: UInt8 = 0
        var message = "Stopped."
        var trueForce = "TrueForce off."
        var telemetry = false
        var tfStreaming = false
    }
    struct TrueForceSettings: Equatable, Sendable {
        var enabled = true
        var strength = 0.6, engine = 0.5, road = 0.6, slip = 0.6
    }
    private static let supportedProducts = [0xc266, 0xc24f] // G923 PlayStation/PC, G29

    private let lock = NSLock()
    private var _status = Status()
    private var _strength = 0.8
    private var _reverse = false
    private var _motorSign = 1.0
    private var _tfMotorSign = 1.0
    private var _tf = TrueForceSettings()
    private var _wheel = WheelSettings()
    private var _calibrationRequest = false
    private var keepRunning = false
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    /// Reports the learned sign and whether it was measured through the TrueForce stream.
    var onCalibrated: (@Sendable (Double?, Bool) -> Void)?

    var status: Status { lock.withLock { _status } }
    var strength: Double { get { lock.withLock { _strength } } set { lock.withLock { _strength = max(0, min(1, newValue)) } } }
    var reverseDirectional: Bool { get { lock.withLock { _reverse } } set { lock.withLock { _reverse = newValue } } }
    var motorSign: Double { get { lock.withLock { _motorSign } } set { lock.withLock { _motorSign = newValue < 0 ? -1 : 1 } } }
    var tfMotorSign: Double { get { lock.withLock { _tfMotorSign } } set { lock.withLock { _tfMotorSign = newValue < 0 ? -1 : 1 } } }
    var trueForce: TrueForceSettings { get { lock.withLock { _tf } } set { lock.withLock { _tf = newValue } } }
    var wheel: WheelSettings { get { lock.withLock { _wheel } } set { lock.withLock { _wheel = newValue } } }
    func requestCalibration() { lock.withLock { _calibrationRequest = true } }

    func start() {
        let alreadyRunning = lock.withLock { () -> Bool in
            if keepRunning { return true }
            keepRunning = true
            return false
        }
        guard !alreadyRunning else { return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "crossover-ffb bridge"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops the motor and releases the wheel; waits for the worker (bounded).
    func stop() {
        let wasRunning = lock.withLock { () -> Bool in
            let was = keepRunning
            keepRunning = false
            return was
        }
        if wasRunning { _ = finished.wait(timeout: .now() + 2) }
        thread = nil
    }

    // MARK: worker thread state
    private var shared: SharedBridge?
    private var device: IOHIDDevice?
    private var outputLength = 7
    private var input = BridgeInput() // raw from the wheel; games get `published`
    private var published = BridgeInput()
    private var appliedWheel = WheelSettings()
    private var appliedRange = 0
    private var revLights = RevLights()
    private var lastLEDs: UInt8 = 0, lastLEDSend = 0.0
    private var engine = EffectEngine()
    private var position = 0.0, velocity = 0.0, acceleration = 0.0, lastPosition = 0.0, lastTick = 0.0
    private var lastCode: [UInt8] = []
    private var lastSend = 0.0
    private var nextScan = 0.0
    // TrueForce: second HID interface of the same wheel, fed a 4 kHz haptic stream.
    private var tfDevice: IOHIDDevice?
    private var tfStreaming = false
    private var tfStreamer = TrueForceStreamer()
    private var tfLastPacket = 0.0, tfSampleDebt = 0.0, tfInactiveSince = 0.0
    private let synth = HapticSynth()

    private func update(_ change: (inout Status) -> Void) { lock.withLock { change(&_status) } }

    private func run() {
        defer { finished.signal() }
        do { shared = try SharedBridge() } catch {
            update { $0.message = "Cannot create shared memory: \(error)"; $0.running = false }
            lock.withLock { keepRunning = false }
            return
        }
        update { $0.running = true; $0.message = "Looking for the wheel…" }
        while lock.withLock({ keepRunning }) {
            let now = ProcessInfo.processInfo.systemUptime
            if device == nil, now >= nextScan { nextScan = now + 1; openWheel() }
            // Deliver HID input callbacks. With no wheel there is no source and the call returns at
            // once, so sleep instead of spinning.
            if CFRunLoopRunInMode(.defaultMode, 0.002, false) == .finished { usleep(2000) }
            tick(now: ProcessInfo.processInfo.systemUptime)
        }
        closeWheel(message: "Stopped.")
        update { $0.running = false }
    }

    private func openWheel() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, Self.supportedProducts.map {
            [kIOHIDVendorIDKey: 0x046d, kIOHIDProductIDKey: $0, kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 4] as CFDictionary
        } as CFArray)
        guard let candidate = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else {
            update { $0.wheelConnected = false; $0.message = "Waiting for a Logitech G923 (PlayStation/PC) or G29 over USB…" }
            return
        }
        let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            update { $0.message = String(format: "Could not open the wheel (0x%08x). Allow Input Monitoring for crossover-ffb in System Settings › Privacy & Security.", UInt32(bitPattern: result)) }
            return
        }
        device = candidate
        outputLength = max(7, (IOHIDDeviceGetProperty(candidate, kIOHIDMaxOutputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 7)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(candidate, { context, _, _, value in
            guard let context else { return }
            Unmanaged<FFBBridge>.fromOpaque(context).takeUnretainedValue().receive(value)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(candidate, { context, _, _ in
            guard let context else { return }
            Unmanaged<FFBBridge>.fromOpaque(context).takeUnretainedValue().closeWheel(message: "Wheel disconnected.")
        }, context)
        IOHIDDeviceScheduleWithRunLoop(candidate, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        input = BridgeInput()
        input.connected = true
        // Seed with current positions; HID only reports changes afterwards.
        for element in IOHIDDeviceCopyMatchingElements(candidate, nil, 0) as? [IOHIDElement] ?? [] {
            let type = IOHIDElementGetType(element)
            guard type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Axis || type == kIOHIDElementTypeInput_Button else { continue }
            var value = Unmanaged<IOHIDValue>.passUnretained(IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0))
            if IOHIDDeviceGetValue(candidate, element, &value) == kIOReturnSuccess { receive(value.takeUnretainedValue()) }
        }
        engine.reset()
        lastCode = []
        send(LogitechWheelCommand.stopAll(length: outputLength))
        send(LogitechWheelCommand.autocenterOff(length: outputLength))
        appliedRange = 0 // range is sent by the first tick
        lastLEDs = 0
        send(LogitechWheelCommand.leds(0, length: outputLength))
        openTrueForce(manager: manager, product: IOHIDDeviceGetProperty(candidate, kIOHIDProductIDKey as CFString) as? Int ?? 0)
        update { $0.wheelConnected = true; $0.message = "Wheel ready. Start the game." }
    }

    private func openTrueForce(manager: IOHIDManager, product: Int) {
        tfDevice = nil
        tfStreaming = false
        guard product == 0xc266 || product == 0xc26d || product == 0xc26e else {
            update { $0.trueForce = "TrueForce: this wheel has none (G923 only)." }
            return
        }
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046d, kIOHIDProductIDKey: product,
                                                kIOHIDPrimaryUsagePageKey: 0xfffd, kIOHIDPrimaryUsageKey: 0xfd01] as CFDictionary)
        guard let candidate = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first,
              IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            update { $0.trueForce = "TrueForce interface not available; using classic force feedback." }
            return
        }
        tfDevice = candidate
        update { $0.trueForce = "TrueForce ready (starts with the game)." }
    }

    /// Two bring-up passes, then the stream owns the motor until `stopTrueForce`.
    private func startTrueForce(now: Double) -> Bool {
        guard let tfDevice else { return false }
        for _ in 0..<2 {
            for packet in TrueForceProtocol.initPass() {
                guard sendTF(packet, to: tfDevice) else {
                    update { $0.trueForce = "TrueForce start failed; using classic force feedback." }
                    self.tfDevice = nil
                    return false
                }
            }
        }
        tfStreamer = TrueForceStreamer(sequence: 68)
        tfStreaming = true
        tfLastPacket = now
        tfSampleDebt = 0
        lastCode = []
        update { $0.trueForce = "TrueForce streaming." }
        return true
    }

    private func stopTrueForce() {
        guard tfStreaming else { return }
        tfStreaming = false
        if let tfDevice { _ = sendTF(TrueForceProtocol.stop(sequence: tfStreamer.nextSequence()), to: tfDevice) }
        lastCode = []
        update { $0.trueForce = tfDevice == nil ? "TrueForce off." : "TrueForce ready (starts with the game)." }
    }

    private func sendTF(_ packet: [UInt8], to device: IOHIDDevice) -> Bool {
        packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(TrueForceProtocol.reportID), $0.baseAddress!, $0.count)
        } == kIOReturnSuccess
    }

    private func closeWheel(message: String) {
        stopTrueForce()
        if let tfDevice { IOHIDDeviceClose(tfDevice, IOOptionBits(kIOHIDOptionsTypeNone)) }
        tfDevice = nil
        if let device {
            send(LogitechWheelCommand.stopAll(length: outputLength))
            send(LogitechWheelCommand.leds(0, length: outputLength))
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        input = BridgeInput()
        published = input
        shared?.publish(input)
        revLights.reset()
        update { $0.wheelConnected = false; $0.output = 0; $0.input = BridgeInput(); $0.message = message }
    }

    private func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDValueGetLength(value) <= 8 else { return }
        let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
        let raw = IOHIDValueGetIntegerValue(value)
        let minimum = IOHIDElementGetLogicalMin(element), maximum = IOHIDElementGetLogicalMax(element)
        if page == 1, usage == 0x39 {
            let direction = HatDirection.decode(raw: raw, minimum: minimum, maximum: maximum, hasNullState: IOHIDElementHasNullState(element))
            let order: [HatDirection] = [.north, .northEast, .east, .southEast, .south, .southWest, .west, .northWest]
            input.hat = order.firstIndex(of: direction).map(UInt32.init) ?? 8
        } else if page == 1, maximum > minimum {
            let clamped = Double(max(minimum, min(maximum, raw)))
            let fraction: Double = (clamped - Double(minimum)) / Double(maximum - minimum)
            let scaled = UInt32((fraction * 65535).rounded())
            // G29/G923 PlayStation report: X wheel, Y clutch, Z accelerator, Rz brake.
            switch usage {
            case 0x30: input.steering = scaled
            case 0x31: input.clutch = scaled
            case 0x32: input.throttle = scaled
            case 0x35: input.brake = scaled
            default: return
            }
        } else if page == 9, (1...25).contains(usage) {
            let bit: UInt32 = 1 << (usage - 1)
            if raw != 0 { input.buttons |= bit } else { input.buttons &= ~bit }
        } else { return }
        published = appliedWheel.apply(to: input)
        shared?.publish(published) // immediately: lowest input latency for the game
    }

    private func tick(now: Double) {
        guard let shared else { return }
        let wheel = lock.withLock { _wheel }
        if wheel != appliedWheel { appliedWheel = wheel; published = wheel.apply(to: input) }
        shared.publish(device == nil ? input : published)
        guard device != nil else { return }
        if appliedRange != wheel.range {
            appliedRange = wheel.range
            send(LogitechWheelCommand.range(wheel.range, length: outputLength))
        }
        let dt = max(0.0005, now - lastTick)
        lastTick = now
        let p = Double(input.steering) / 32767.5 - 1
        let rawVelocity = (p - lastPosition) / dt
        lastPosition = p
        let newVelocity = velocity + 0.2 * (rawVelocity - velocity)
        acceleration += 0.1 * ((newVelocity - velocity) / dt - acceleration)
        velocity = newVelocity
        position = p

        let (strength, reverse, sign, tfSign, tf, calibrate) = lock.withLock { () -> (Double, Bool, Double, Double, TrueForceSettings, Bool) in
            let request = _calibrationRequest
            _calibrationRequest = false
            return (_strength, _reverse, _motorSign, _tfMotorSign, _tf, request)
        }
        if calibrate { calibrateDirection(); return }

        let state = shared.readForce() ?? BridgeForceState()
        let age = Int64(SharedBridge.nowMilliseconds()) - Int64(state.heartbeatMilliseconds)
        let gameActive = state.processID != 0 && age >= -2000 && age < 500 && state.acquired
        var level = 0.0
        if gameActive && !state.paused && !state.actuatorsOff {
            engine.reverseDirectional = reverse
            level = engine.force(state, wheel: WheelKinematics(position: position, velocity: velocity, acceleration: acceleration), now: now) * strength
        } else { engine.reset() }
        if !gameActive { revLights.reset() } // a new session may be a different car
        let playing = gameActive ? state.effects.filter(\.playing).count : 0
        if gameActive && !state.paused && wheel.centeringSpring && (playing == 0 || wheel.springInFFBGames) {
            level = max(-1, min(1, level + wheel.centeringForce(position: position, velocity: velocity)))
        }
        // TrueForce follows the game session; a short grace period rides out heartbeat jitter.
        if gameActive { tfInactiveSince = now }
        let wantTF = tf.enabled && tfDevice != nil && now - tfInactiveSince < 2
        if wantTF && !tfStreaming { _ = startTrueForce(now: ProcessInfo.processInfo.systemUptime) }
        if !wantTF && tfStreaming { stopTrueForce() }

        var telemetry: GameTelemetry?
        var maxRpm = 0.0
        if let page = shared.readTelemetry(), page.source == 1 || page.source == 2,
           Int64(SharedBridge.nowMilliseconds()) - Int64(page.unixMilliseconds) < 1000 {
            telemetry = GameTelemetry.acPhysics(page.bytes, evo: page.source == 2)
            maxRpm = Double(page.maxRpm)
        }
        updateRevLights(telemetry: gameActive && wheel.revLights ? telemetry : nil, maxRpm: maxRpm, now: now)
        if tfStreaming, let tfDevice {
            synth.engineGain = tf.engine; synth.roadGain = tf.road; synth.slipGain = tf.slip
            synth.update(gameActive && !state.paused ? telemetry : nil, now: now)
            tfSampleDebt += (now - tfLastPacket) * TrueForceProtocol.sampleRate
            tfLastPacket = now
            let count = max(1, min(TrueForceProtocol.maxNewSamples, Int(tfSampleDebt)))
            tfSampleDebt = max(0, min(Double(TrueForceProtocol.maxNewSamples), tfSampleDebt - Double(count)))
            let samples = synth.render(count: count).map { $0 * tf.strength }
            if !sendTF(tfStreamer.packet(torque: level * tfSign, samples: samples), to: tfDevice) {
                tfStreaming = false
                self.tfDevice = nil
                update { $0.trueForce = "TrueForce stream lost; using classic force feedback." }
            }
        } else {
            let code = LogitechWheelCommand.constant(level * sign, length: outputLength)
            if code != lastCode || now - lastSend > 0.1 {
                send(code)
                lastCode = code
                lastSend = now
            }
        }
        update {
            $0.gameProcessID = state.processID
            $0.gameActive = gameActive
            $0.effectsPlaying = playing
            $0.output = level
            $0.input = published
            $0.rawSteering = input.steering
            $0.leds = lastLEDs
            $0.telemetry = telemetry != nil
            $0.tfStreaming = tfStreaming
            $0.message = gameActive ? "Game connected — force feedback active." : state.processID != 0 && age < 5000 ? "Game seen; waiting for it to acquire the wheel." : "Wheel ready. Start the game."
        }
    }

    /// Short gentle push to learn which motor code turns the wheel toward +X.
    private func calibrateDirection() {
        update { $0.message = "Detecting motor direction — let go of the wheel…" }
        let start = input.steering
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        let viaTF = tfStreaming
        func push(_ level: Double) {
            if viaTF, let tfDevice { _ = sendTF(tfStreamer.packet(torque: level, samples: [Double](repeating: 0, count: 4)), to: tfDevice) }
            else { send(LogitechWheelCommand.constant(level, length: outputLength)) }
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            push(0.25) // the stream needs continuous packets; classic just repeats harmlessly
            CFRunLoopRunInMode(.defaultMode, 0.002, false)
        }
        push(0)
        lastCode = []
        let delta = Int(input.steering) - Int(start)
        if abs(delta) < 150 {
            update { $0.message = "Direction test: the wheel did not move. Let go of it and try again." }
            onCalibrated?(nil, viaTF)
        } else {
            let sign: Double = delta > 0 ? 1 : -1
            lock.withLock { if viaTF { _tfMotorSign = sign } else { _motorSign = sign } }
            update { $0.message = viaTF ? "TrueForce motor direction detected." : "Motor direction detected." }
            onCalibrated?(sign, viaTF)
        }
    }

    /// Rev LEDs from telemetry, sent on change (at most every 30 ms); dark without a game.
    private func updateRevLights(telemetry: GameTelemetry?, maxRpm: Double, now: Double) {
        var mask: UInt8 = 0
        if let telemetry, telemetry.engineRunning { mask = revLights.mask(rpm: telemetry.rpm, maxRpm: maxRpm, now: now) }
        guard mask != lastLEDs, now - lastLEDSend > 0.03 else { return }
        send(LogitechWheelCommand.leds(mask, length: outputLength))
        lastLEDs = mask
        lastLEDSend = now
    }

    private func send(_ bytes: [UInt8]) {
        guard let device else { return }
        _ = bytes.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count) }
    }
}
