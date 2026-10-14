import Foundation
@preconcurrency import CoreBluetooth
import IOBluetooth
import OSLog

@MainActor
public protocol BudsClient: AnyObject {
    var events: AsyncStream<BudsEvent> { get }

    func start()
    func stop()

    /// Enable/disable live updates (notifications/telemetry).
    /// Disabling reduces earbud BLE traffic and battery impact.
    func setLiveUpdatesEnabled(_ enabled: Bool)

    /// Reconnect to the earbuds. If disconnected or paired to another device (e.g. phone),
    /// initiates Bluetooth Classic baseband paging to snatch the connection to Mac, followed
    /// by BLE GATT service discovery and authentication handshake.
    func reconnectNow()

    /// Disconnect from the earbuds. Terminates BLE GATT and closes the Bluetooth Classic ACL
    /// link, allowing the earbuds to fall back and automatically reconnect to the user's phone.
    func disconnectNow()
    func refreshAllNow(source: UpdateSource)

    func setANC(_ mode: ANCMode)
    func setEQPreset(_ preset: Int)
    func queryANC(source: UpdateSource)
    func queryBattery(source: UpdateSource)
    func queryDeviceInfo(source: UpdateSource)
    func queryEQ(source: UpdateSource)

    // Optional discovery tool (read-only). Not used by default UI.
    func scanEQCommands()
}

@MainActor
public final class BudsClientImpl: NSObject, BudsClient {

    public var events: AsyncStream<BudsEvent> { eventStream }

    private static let peripheralUUIDKey = "buds.lastPeripheralUUID"

    private let eventStream: AsyncStream<BudsEvent>
    private let eventCont: AsyncStream<BudsEvent>.Continuation

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    private var write079A: CBCharacteristic?
    private var notify079A: CBCharacteristic?
    private var notifyChars: [CBCharacteristic] = []
    private var liveUpdatesEnabled: Bool = false
    private var liveRxStartedAt: Date?
    private var liveRxPackets: Int = 0
    private var liveRxBytes: Int = 0

    private var connectionState: ConnectionState = .idle {
        didSet { emit(.connection(connectionState)) }
    }

    private var ancMode: ANCMode? {
        didSet {
            if let m = ancMode { emit(.anc(m, source: .device)) }
        }
    }

    private var battery: BatteryStatus? {
        didSet {
            if let b = battery { emit(.battery(b, source: .device)) }
        }
    }

    private var deviceInfo: DeviceInfo? {
        didSet {
            if let i = deviceInfo { emit(.deviceInfo(i)) }
        }
    }

    private var eqStatus: EQStatus? {
        didSet {
            if let e = eqStatus { emit(.eq(e)) }
        }
    }

    private var authState: AuthState = .notAuthenticated
    private var lastAuthAt: Date?

    // ANC state is push-driven (no periodic polling).

    private enum AuthState {
        case notAuthenticated
        case authenticating
        case authenticated
    }

    private var opQueue: [QueuedOperation] = []
    private var opRunning = false
    private var currentOpId: UUID?
    private var currentOpKind: OperationKind?
    private var currentDrainTask: Task<Void, Never>?
    private var currentOpWorkTask: Task<Void, Error>?

    private struct QueuedOperation {
        var kind: OperationKind
        var maxRetries: Int
        var timeout: Duration
        var run: @MainActor () async throws -> Void
    }

    private var reconnectTask: Task<Void, Never>?
    private var serviceDiscoveryTimeoutTask: Task<Void, Never>?
    private var scanWatchdogTask: Task<Void, Never>?

    private var didInitialRefreshAfterConnect = false
    private var sessionReadyTriggered = false
    private var ioBluetoothNotification: IOBluetoothUserNotification?
    private var ioBluetoothBridge: IOBluetoothBridge?

    // Some devices send responses or telemetry unsolicited. We track a monotonically
    // increasing sequence for each model; query operations wait for the next update.
    private var batterySeq: UInt64 = 0
    private var deviceInfoSeq: UInt64 = 0
    private var eqSeq: UInt64 = 0
    private var ancSeq: UInt64 = 0

    private let debugEnabled = ProcessInfo.processInfo.environment["BUDS_DEBUG"] == "1"
    private let logger = Logger(subsystem: "local.nordbuds", category: "BudsClient")

    public override init() {
        var cont: AsyncStream<BudsEvent>.Continuation!
        self.eventStream = AsyncStream<BudsEvent> { c in
            cont = c
        }
        self.eventCont = cont

        super.init()
    }

    public func start() {
        guard central == nil else { return }
        connectionState = .idle
        central = CBCentralManager(delegate: self, queue: .main)

        // Listen for system-level Classic Bluetooth audio connection (e.g. lid open auto-connect)
        let bridge = IOBluetoothBridge(client: self)
        ioBluetoothBridge = bridge
        ioBluetoothNotification = IOBluetoothDevice.register(
            forConnectNotifications: bridge,
            selector: #selector(IOBluetoothBridge.handleConnect(_:device:))
        )
    }

    public func stop() {
        ioBluetoothNotification?.unregister()
        ioBluetoothNotification = nil
        ioBluetoothBridge = nil
        reconnectTask?.cancel(); reconnectTask = nil
        serviceDiscoveryTimeoutTask?.cancel(); serviceDiscoveryTimeoutTask = nil
        if let p = peripheral {
            // Best-effort: turn off notifications before disconnecting.
            for ch in notifyChars { p.setNotifyValue(false, for: ch) }
        }

        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
        peripheral = nil
        write079A = nil
        notify079A = nil
        notifyChars = []
        authState = .notAuthenticated
        central = nil
        ancMode = nil
        battery = nil
        deviceInfo = nil
        eqStatus = nil
        connectionState = .idle
    }

    public func setLiveUpdatesEnabled(_ enabled: Bool) {
        if debugEnabled { print("[LIVE] setLiveUpdatesEnabled(\(enabled ? "on" : "off"))") }
        if liveUpdatesEnabled != enabled {
            if enabled {
                liveRxStartedAt = Date()
                liveRxPackets = 0
                liveRxBytes = 0
                logger.info("LiveUpdates: on")
            } else if let start = liveRxStartedAt {
                let dt = max(0.001, Date().timeIntervalSince(start))
                let pps = Double(liveRxPackets) / dt
                let bps = Double(liveRxBytes) / dt
                logger.info("LiveUpdates: off after \(dt, privacy: .public)s (\(self.liveRxPackets, privacy: .public) pkts, \(self.liveRxBytes, privacy: .public) bytes, \(pps, privacy: .public) pkt/s, \(bps, privacy: .public) B/s)")
                liveRxStartedAt = nil
            }
        }
        liveUpdatesEnabled = enabled
        guard let p = peripheral else { return }
        for ch in notifyChars {
            p.setNotifyValue(enabled, for: ch)
        }

        // Some firmwares only start emitting vendor status/telemetry after the HELLO/REGISTER
        // handshake. Do this only on-demand (popover open), not as a periodic poll.
        if enabled, case .connected = connectionState {
            enqueue(kind: .authenticate, timeout: .seconds(8), maxRetries: 0) { [weak self] in
                guard let self else { return }
                try await self.ensureAuthenticated()
            }
        }
    }

    public func reconnectNow() {
        if let central, central.state != .poweredOn {
            switch central.state {
            case .poweredOff:
                connectionState = .bluetoothOff
            case .unauthorized:
                connectionState = .bluetoothUnauthorized
            case .unsupported:
                connectionState = .bluetoothUnsupported
            case .resetting:
                connectionState = .bluetoothResetting
            default:
                break
            }
            return
        }

        enqueue(kind: .reconnect, timeout: .seconds(15), maxRetries: 1) { [weak self] in
            guard let self else { return }
            guard let c = self.central, c.state == .poweredOn else {
                if let c = self.central {
                    self.centralManagerDidUpdateState(c)
                }
                return
            }
            self.serviceDiscoveryTimeoutTask?.cancel()
            self.serviceDiscoveryTimeoutTask = nil
            self.scanWatchdogTask?.cancel()
            self.scanWatchdogTask = nil
            self.connectionState = .reconnecting(name: self.peripheral?.name)
            self.authState = .notAuthenticated
            self.sessionReadyTriggered = false
            if let p = self.peripheral {
                self.central?.cancelPeripheralConnection(p)
            }
            self.peripheral = nil
            self.write079A = nil
            self.notify079A = nil
            self.notifyChars = []
            self.ancMode = nil

            // Attempt Classic takeover (snatch from phone to Mac if not connected)
            self.snatchClassicConnection()

            self.startScanOrRetrieve()
        }
    }

    public func disconnectNow() {
        log("Disconnect requested: releasing connection back to paired device")
        reconnectTask?.cancel(); reconnectTask = nil
        serviceDiscoveryTimeoutTask?.cancel(); serviceDiscoveryTimeoutTask = nil
        scanWatchdogTask?.cancel(); scanWatchdogTask = nil
        central?.stopScan()

        if let p = peripheral {
            for ch in notifyChars { p.setNotifyValue(false, for: ch) }
            central?.cancelPeripheralConnection(p)
        }
        peripheral = nil
        write079A = nil
        notify079A = nil
        notifyChars = []
        authState = .notAuthenticated
        sessionReadyTriggered = false
        ancMode = nil

        // Drop Classic Bluetooth ACL connection so the buds release back to phone
        releaseClassicConnection()

        connectionState = .idle
    }

    public func refreshAllNow(source: UpdateSource) {
        enqueue(kind: .refreshAll, timeout: .seconds(20), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            // Keep protocol traffic serialized and predictable. ANC/device/EQ are intentionally
            // not queried by default (ANC is push-driven; device/EQ removed from app UI).
            try await self.queryBatteryInternal(source: source)
        }
    }

    public func setANC(_ mode: ANCMode) {
        // User interaction should preempt any background refresh/query work.
        prioritizeUserANCChange()
        enqueueHighPriority(kind: .setANC, timeout: .seconds(18), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()

            // Match the original script's timing: QUERY then wait, then SET.
            self.emitOpStep("Querying ANC (preflight)")
            try? self.write079A(OPOProtocol.ancQueryPacket(), label: "ANC_QUERY")

            self.emitOpStep("Sending ANC: \(mode.rawValue)")
            // Gap between query and set (script uses ~1.5s).
            try await Task.sleep(for: .milliseconds(1500))
            let modeByte = ANCWireMapping.toWire(mode)
            try self.write079A(OPOProtocol.ancSetPacket(modeByte: modeByte), label: "ANC_SET(\(String(format: "%02X", modeByte)))")

            // Optimistically update UI; we'll attempt to re-query in the background.
            self.ancMode = mode
            self.ancSeq &+= 1
            self.emit(.anc(mode, source: .user))
        }
    }

    public func setEQPreset(_ preset: Int) {
        // EQ changes should also preempt any background refresh/query work.
        prioritizeUserEQChange()
        enqueueHighPriority(kind: .setEQPreset, timeout: .seconds(12), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()

            self.emitOpStep("Setting EQ preset: \(preset)")
            let p = UInt8(clamping: preset)
            try self.write079A(OPOProtocol.eqSetPresetPacket(preset: p), label: "EQ_SET_PRESET(\(preset))")

            // Best-effort: mark the selected preset locally; some firmwares do not expose
            // an "active preset" query.
            if var e = self.eqStatus {
                e.currentPreset = preset
                e.lastUpdated = Date()
                self.eqStatus = e
                self.emit(.eq(e))
            } else {
                let e = EQStatus(modeByte: nil, presets: [], currentPreset: preset, lastUpdated: Date())
                self.eqStatus = e
                self.emit(.eq(e))
            }

            // Refresh table in the background so UI can show band values if supported.
            // Intentionally no background query: keep traffic user-driven.
        }
    }

    public func queryANC(source: UpdateSource) {
        enqueue(kind: .queryANC, timeout: .seconds(8), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            _ = try await self.queryANCInternal(source: source)
        }
    }

    public func queryBattery(source: UpdateSource) {
        enqueue(kind: .queryBattery, timeout: .seconds(8), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            _ = try await self.queryBatteryInternal(source: source)
        }
    }

    public func queryDeviceInfo(source: UpdateSource) {
        enqueue(kind: .queryDeviceInfo, timeout: .seconds(8), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            _ = try await self.queryDeviceInfoInternal(source: source)
        }
    }

    public func queryEQ(source: UpdateSource) {
        enqueue(kind: .queryEQ, timeout: .seconds(8), maxRetries: 1) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            _ = try await self.queryEQInternal(source: source)
        }
    }

    public func scanEQCommands() {
        enqueue(kind: .scanEQ, timeout: .seconds(25), maxRetries: 0) { [weak self] in
            guard let self else { return }
            try await self.ensureAuthenticated()
            self.emitOpStep("Scanning EQ cmds")

            // Read-only queries; keeps risk low.
            // We don't currently use these results automatically; this is for discovery/debug.
            for cmd in UInt8(0x20)...UInt8(0x3F) {
                if Task.isCancelled { return }
                try? self.write079A(OPOProtocol.eqQueryPacket(cmd: cmd), label: "EQ_QUERY(cmd=\(String(format: "%02X", cmd)))")
                try? await Task.sleep(for: .milliseconds(320))
            }
        }
    }

    // MARK: - Queue

    private func enqueue(kind: OperationKind, timeout: Duration, maxRetries: Int, _ run: @escaping @MainActor () async throws -> Void) {
        opQueue.append(QueuedOperation(kind: kind, maxRetries: maxRetries, timeout: timeout, run: run))
        drainQueueIfNeeded()
    }

    private func enqueueHighPriority(kind: OperationKind, timeout: Duration, maxRetries: Int, _ run: @escaping @MainActor () async throws -> Void) {
        // Insert at the front so it runs next.
        opQueue.insert(QueuedOperation(kind: kind, maxRetries: maxRetries, timeout: timeout, run: run), at: 0)
        drainQueueIfNeeded()
    }

    private func prioritizeUserANCChange() {
        // When the user taps an ANC mode in the popover, we don't want background refreshes
        // (ANC/battery/etc queries) to "block" the control action. Cancel the current query and
        // drop any queued refresh/query work.
        let dropKinds: Set<OperationKind> = [.refreshAll, .queryANC, .queryBattery, .queryDeviceInfo, .queryEQ]
        opQueue.removeAll { dropKinds.contains($0.kind) || $0.kind == .setANC }

        if let runningKind = currentOpKind, dropKinds.contains(runningKind) || runningKind == .setANC {
            currentOpWorkTask?.cancel()
            currentDrainTask?.cancel()
        }
    }

    private func prioritizeUserEQChange() {
        let dropKinds: Set<OperationKind> = [.refreshAll, .queryANC, .queryBattery, .queryDeviceInfo, .queryEQ, .scanEQ]
        opQueue.removeAll { dropKinds.contains($0.kind) || $0.kind == .setEQPreset }

        if let runningKind = currentOpKind, dropKinds.contains(runningKind) || runningKind == .setEQPreset {
            currentOpWorkTask?.cancel()
            currentDrainTask?.cancel()
        }
    }

    private func drainQueueIfNeeded() {
        guard !opRunning else { return }
        guard !opQueue.isEmpty else { return }

        opRunning = true
        let op = opQueue.removeFirst()

        currentDrainTask?.cancel()
        currentDrainTask = Task { @MainActor in
            defer {
                self.opRunning = false
                self.currentOpId = nil
                self.currentOpKind = nil
                self.currentDrainTask = nil
                self.currentOpWorkTask = nil
                self.drainQueueIfNeeded()
            }

            let opId = UUID()
            self.currentOpId = opId
            self.currentOpKind = op.kind
            self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .queued)))

            var attempt = 0
            while true {
                attempt += 1
                do {
                    let work = Task { @MainActor in
                        self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .running(step: "Starting"))))
                        try await op.run()
                    }
                    self.currentOpWorkTask = work
                    defer { self.currentOpWorkTask = nil }

                    try await withTaskCancellationHandler {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { try await work.value }
                            group.addTask {
                                try await Task.sleep(for: op.timeout)
                                throw UserFacingError("Timed out")
                            }
                            _ = try await group.next()!
                            group.cancelAll()
                        }
                    } onCancel: {
                        work.cancel()
                    }

                    self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .succeeded)))
                    return
                } catch {
                    if error is CancellationError {
                        // Cancellation is used for user-priority operations and during reconnect/stop.
                        // Don't surface it as a failure in the UI.
                        self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .succeeded)))
                        return
                    }
                    let msg = (error as? UserFacingError)?.message ?? String(describing: error)
                    if attempt <= op.maxRetries + 1 {
                        self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .running(step: "Retrying (\(attempt-1))"))))
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    self.emit(.operation(OperationEvent(id: opId, kind: op.kind, phase: .failed(message: msg))))
                    self.emit(.error(UserFacingError(msg)))
                    return
                }
            }
        }
    }

    private func log(_ msg: String) {
        logger.info("\(msg, privacy: .public)")
        emit(.log(msg))
        if debugEnabled { print("[Buds] \(msg)") }
    }

    private struct PairedBudRecord {
        let name: String
        let address: String
        let isConnected: Bool
    }

    private func getPairedBudsRecords() -> [PairedBudRecord] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { d in
            guard let rawName = d.nameOrAddress, BudsDeviceFilter.isAudioDeviceName(rawName) else {
                return nil
            }
            let addr = (d.addressString ?? "").lowercased().replacingOccurrences(of: ":", with: "-")
            return PairedBudRecord(name: rawName, address: addr, isConnected: d.isConnected())
        }
    }

    private func startScanOrRetrieve() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            centralManagerDidUpdateState(central)
            return
        }
        log("Checking Bluetooth (state=\(central.state.rawValue))...")
        scanWatchdogTask?.cancel()
        scanWatchdogTask = nil

        let pairedBuds = getPairedBudsRecords()
        guard !pairedBuds.isEmpty else {
            log("Security gate: No paired OnePlus audio devices in macOS Bluetooth. Scan aborted.")
            UserDefaults.standard.removeObject(forKey: Self.peripheralUUIDKey)
            UserDefaults.standard.removeObject(forKey: "buds.lastDeviceName")
            connectionState = .failed(message: "No buds paired to Mac")
            return
        }

        let pairedNames = Set(pairedBuds.map { $0.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        let savedName = UserDefaults.standard.string(forKey: "buds.lastDeviceName")

        // Sanitize saved device against paired list
        if let savedName, !pairedNames.contains(savedName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) {
            log("Security gate: Cached device '\(savedName)' not paired to Mac; clearing cache")
            UserDefaults.standard.removeObject(forKey: Self.peripheralUUIDKey)
            UserDefaults.standard.removeObject(forKey: "buds.lastDeviceName")
        }

        // 1. Check if already connected to macOS system Bluetooth with vendor audio services
        let targetServiceUUIDs = [
            CBUUID(string: OPOProtocol.service08A4),
            CBUUID(string: OPOProtocol.service079A),
            CBUUID(string: OPOProtocol.serviceFE2C)
        ]
        let retrieve = central.retrieveConnectedPeripherals(withServices: targetServiceUUIDs)
        if let first = retrieve.first(where: { p in
            guard let name = p.name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return pairedNames.contains(name)
        }) {
            log("Found system peripheral with audio service: \(first.name ?? "unnamed")")
            central.stopScan()
            peripheral = first
            first.delegate = self
            connectionState = .connecting(name: first.name ?? savedName)
            central.connect(first, options: nil)
            return
        }

        // 2. If known saved buds peripheral is retrieved by identifier AND matches paired list
        if let validSavedUUID = UserDefaults.standard.string(forKey: Self.peripheralUUIDKey),
           let uuid = UUID(uuidString: validSavedUUID) {
            let known = central.retrievePeripherals(withIdentifiers: [uuid])
            if let first = known.first {
                let name = (first.name ?? savedName ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if pairedNames.contains(name) {
                    if first.state == .connected {
                        log("Found known peripheral connected: \(first.name ?? savedName ?? "unnamed")")
                        central.stopScan()
                        peripheral = first
                        first.delegate = self
                        let dispName = first.name ?? savedName
                        connectionState = .connecting(name: dispName)
                        central.connect(first, options: nil)
                        return
                    } else if first.state == .connecting {
                        log("Peripheral already connecting, waiting...")
                        return
                    }
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.peripheralUUIDKey)
                }
            }
        }

        // 3. Keep existing connecting/connected peripheral; only clear if truly disconnected
        if let p = peripheral, p.state == .disconnected {
            peripheral = nil
        }

        log("Scanning for paired OnePlus Buds...")
        connectionState = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        // Duty-cycle: If not found after 10 seconds, pause 3s then repeat via scheduleReconnect
        scanWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if case .scanning = self.connectionState {
                self.central?.stopScan()
                self.connectionState = .idle
                self.scheduleReconnect()
            }
        }
    }

    private func rememberNotifyChar(_ ch: CBCharacteristic) {
        if notifyChars.contains(where: { $0.uuid == ch.uuid }) { return }
        notifyChars.append(ch)
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(3), .seconds(5)]
            var idx = 0

            while !Task.isCancelled {
                let wait = backoff[min(idx, backoff.count - 1)]
                idx += 1
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }

                if case .connected = self.connectionState {
                    return
                }

                self.startScanOrRetrieve()
            }
        }
    }

    private func write079APacket(_ bytes: [UInt8], label: String) async throws {
        try write079A(bytes, label: label)
    }

    private func write079A(_ bytes: [UInt8], label: String) throws {
        guard let p = peripheral, let ch = write079A else {
            throw UserFacingError("Not ready to send packets")
        }
        let data = Data(bytes)
        // Must be .withoutResponse per reverse-engineered behavior.
        p.writeValue(data, for: ch, type: .withoutResponse)
        let hex = OPOProtocol.hex(bytes)
        // Use info for important user-facing operations so it's easy to debug via `log stream`.
        let isInfo =
            label == "HELLO" ||
            label == "REGISTER" ||
            label == "BATTERY_QUERY" ||
            label == "INFO_QUERY" ||
            label == "EQ_QUERY" ||
            label.hasPrefix("EQ_SET_PRESET") ||
            label.hasPrefix("ANC_SET")

        if isInfo {
            logger.info("[TX] \(label, privacy: .public): \(hex, privacy: .public)")
        } else {
            logger.debug("[TX] \(label, privacy: .public): \(hex, privacy: .public)")
        }
        if debugEnabled { print("[TX] \(label): \(hex)") }
    }

    private func pokeReadNotify079A(reason: String) {
        guard peripheral != nil, notify079A != nil else { return }
        // NOTE: we no longer auto-poke reads because it adds traffic and some firmwares
        // return non-vendor bytes on read, which can confuse debugging and waste energy.
        // Kept as a manual/debug hook only.
        if debugEnabled {
            print("[BLE] (skipped) poke read 0200079A (\(reason))")
        }
    }

    private func ensureAuthenticated() async throws {
        guard case .connected = connectionState else {
            throw UserFacingError("Not connected")
        }
        switch authState {
        case .authenticated:
            return
        case .authenticating:
            // Wait briefly; operations are serialized anyway.
            try await Task.sleep(for: .milliseconds(250))
            if authState == .authenticated { return }
        case .notAuthenticated:
            break
        }

        let hadConnectedUI: Bool = {
            if case .connected = self.connectionState { return true }
            return false
        }()

        authState = .authenticating
        if !hadConnectedUI {
            connectionState = .authenticating(name: peripheral?.name)
        }

        emitOpStep("HELLO")
        try write079A(OPOProtocol.helloPacket(), label: "HELLO")
        try await Task.sleep(for: .seconds(2))

        emitOpStep("REGISTER")
        try write079A(OPOProtocol.registerPacket(), label: "REGISTER")
        try await Task.sleep(for: .milliseconds(1500))

        authState = .authenticated
        lastAuthAt = Date()
        connectionState = .connected(name: peripheral?.name)
    }

    private func awaitANCQuery(source: UpdateSource, timeout: Duration) async throws -> ANCMode {
        emitOpStep("Querying ANC")
        let startSeq = ancSeq
        try write079A(OPOProtocol.ancQueryPacket(), label: "ANC_QUERY")
        // Do not return a stale cached mode if the query doesn't trigger any updates.
        // If we don't see a new ANC update, treat status as unavailable.
        try await waitForSeqChangeWithPokes(
            current: { self.ancSeq },
            from: startSeq,
            timeout: timeout,
            reason: "ANC_QUERY"
        )
        if let m = ancMode { return m }
        throw UserFacingError("ANC status unavailable")
    }

    private func queryANCInternal(source: UpdateSource) async throws {
        do {
            let timeout: Duration = {
                switch source {
                case .device, .onOpen:
                    return .seconds(6)
                case .user:
                    return .seconds(3)
                }
            }()
            let m = try await awaitANCQuery(source: source, timeout: timeout)
            ancMode = m
            emit(.anc(m, source: source))
        } catch {
            // Don't fail the whole refresh flow if ANC status isn't queryable.
        }
    }

    private func queryBatteryInternal(source: UpdateSource) async throws {
        emitOpStep("Querying battery")
        let startSeq = batterySeq
        try write079A(OPOProtocol.batteryQueryPacket(), label: "BATTERY_QUERY")
        try await waitForSeqChangeWithPokes(
            current: { self.batterySeq },
            from: startSeq,
            timeout: .seconds(5),
            reason: "BATTERY_QUERY"
        )

        if var b = battery {
            b.lastUpdated = Date()
            battery = b
            emit(.battery(b, source: source))
            return
        }
        throw UserFacingError("Battery response missing")
    }

    private func queryDeviceInfoInternal(source: UpdateSource) async throws {
        emitOpStep("Querying device info")
        let startSeq = deviceInfoSeq
        try write079A(OPOProtocol.deviceInfoQueryPacket(), label: "INFO_QUERY")
        try await waitForSeqChangeWithPokes(
            current: { self.deviceInfoSeq },
            from: startSeq,
            timeout: .seconds(5),
            reason: "INFO_QUERY"
        )

        if var i = deviceInfo {
            i.lastUpdated = Date()
            deviceInfo = i
            emit(.deviceInfo(i))
            return
        }
        throw UserFacingError("Device info response missing")
    }

    private func queryEQInternal(source: UpdateSource) async throws {
        emitOpStep("Querying EQ")
        let startSeq = eqSeq
        try write079A(OPOProtocol.eqQueryPacket(), label: "EQ_QUERY")
        try await waitForSeqChangeWithPokes(
            current: { self.eqSeq },
            from: startSeq,
            timeout: .seconds(5),
            reason: "EQ_QUERY"
        )

        if var e = eqStatus {
            e.lastUpdated = Date()
            eqStatus = e
            emit(.eq(e))
            return
        }
        throw UserFacingError("EQ response missing")
    }

    private func emitOpStep(_ step: String) {
        let id = currentOpId ?? UUID()
        let kind = currentOpKind ?? .refreshAll
        emit(.operation(OperationEvent(id: id, kind: kind, phase: .running(step: step))))
    }

    private func emit(_ event: BudsEvent) {
        eventCont.yield(event)
    }

    // Note: we intentionally don't use a generic "withTimeout" helper because we need
    // explicit cancellation of the active work task when a user-priority operation arrives.

    private func waitForSeqChange(current: @escaping @MainActor () -> UInt64, from: UInt64, timeout: Duration) async throws {
        let deadline = Date().addingTimeInterval(timeout.timeInterval)
        while current() == from {
            if Date() >= deadline {
                throw UserFacingError("Timed out")
            }
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    private func waitForSeqChangeWithPokes(
        current: @escaping @MainActor () -> UInt64,
        from: UInt64,
        timeout: Duration,
        reason: String
    ) async throws {
        // Backwards-compatible wrapper; "pokes" disabled (no extra BLE reads).
        _ = reason
        try await waitForSeqChange(current: current, from: from, timeout: timeout)
    }

    /// System-level Classic Bluetooth audio connection listener handler.
    /// Fired when macOS establishes the A2DP/HFP audio connection (e.g. when the case lid is opened).
    ///
    /// Ignores non-buds audio devices, and avoids reconnect thrashing if a connection is already
    /// active or in-progress.
    /// - Parameter name: Name or MAC address of the connected Bluetooth device.
    @MainActor
    fileprivate func handleIOBluetoothDeviceConnected(name: String) {
        logger.info("IOBluetooth device connected: \(name, privacy: .public)")
        guard BudsDeviceFilter.isAudioDeviceName(name) else { return }
        let paired = getPairedBudsRecords()
        let pairedNames = Set(paired.map { $0.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        let nameNorm = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard pairedNames.contains(nameNorm) else {
            logger.info("Security gate: Connected device '\(name, privacy: .public)' is not a paired buds device; ignoring")
            return
        }
        log("System audio connected to \(name), initiating Buds sync...")
        switch connectionState {
        case .idle, .failed, .bluetoothOff, .bluetoothUnauthorized,
             .bluetoothUnsupported, .bluetoothResetting:
            reconnectNow()
        default:
            // Already connected or connection in progress (.connecting, .discovering, .authenticating)
            // Do not interrupt with reconnect thrash!
            return
        }
    }

    /// Asynchronously initiate Bluetooth Classic baseband paging (HCI Create Connection)
    /// to take over (snatch) the connection from a previously paired phone to this Mac.
    ///
    /// Checks paired devices matching known earbuds names, prioritizing the last known device,
    /// and issues `openConnection()` until a device connects.
    nonisolated private func snatchClassicConnection() {
        DispatchQueue.global(qos: .userInitiated).async { [logger] in
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let candidates = paired.filter { d in
                guard let name = d.nameOrAddress else { return false }
                return BudsDeviceFilter.isAudioDeviceName(name)
            }
            guard !candidates.isEmpty else {
                logger.info("Snatch: No paired buds found to connect")
                return
            }

            if let connected = candidates.first(where: { $0.isConnected() }) {
                logger.info("Snatch: Already connected to \(connected.nameOrAddress ?? "device", privacy: .public)")
                return
            }

            let savedName = UserDefaults.standard.string(forKey: "buds.lastDeviceName")
            let sortedCandidates = candidates.sorted { a, _ in
                if let savedName, a.nameOrAddress == savedName { return true }
                return false
            }

            for dev in sortedCandidates {
                logger.info("Snatch: Opening Classic ACL connection to \(dev.nameOrAddress ?? "device", privacy: .public)...")
                let res = dev.openConnection()
                logger.info("Snatch: openConnection(\(dev.nameOrAddress ?? "?", privacy: .public)) result: \(res)")
                if res == 0 {
                    break
                }
            }
        }
    }

    /// Asynchronously terminate the Bluetooth Classic ACL connection, allowing the earbuds
    /// to fall back and automatically reconnect to the user's phone.
    nonisolated private func releaseClassicConnection() {
        DispatchQueue.global(qos: .userInitiated).async { [logger] in
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            for dev in paired {
                guard let name = dev.nameOrAddress, BudsDeviceFilter.isAudioDeviceName(name) else { continue }
                if dev.isConnected() {
                    logger.info("Releasing Classic Bluetooth connection for \(name, privacy: .public)")
                    dev.closeConnection()
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate

// CoreBluetooth delegate protocols are not actor-isolated. We run the central
// manager on the main queue and treat this object as main-actor owned.
extension BudsClientImpl: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("centralManagerDidUpdateState: \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            startScanOrRetrieve()
        case .poweredOff:
            connectionState = .bluetoothOff
        case .unauthorized:
            connectionState = .bluetoothUnauthorized
        case .unsupported:
            connectionState = .bluetoothUnsupported
        case .resetting:
            connectionState = .bluetoothResetting
        case .unknown:
            connectionState = .failed(message: "Bluetooth state unknown")
        default:
            connectionState = .failed(message: "Bluetooth unavailable")
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let rawName = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let nameNorm = rawName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let paired = getPairedBudsRecords()
        guard !paired.isEmpty else {
            central.stopScan()
            connectionState = .failed(message: "No buds paired to Mac")
            return
        }

        let pairedNames = Set(paired.map { $0.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        let pairedAddresses = Set(paired.map { $0.address }.filter { !$0.isEmpty })

        // Security gate 1: Name MUST match a paired audio device in macOS
        guard let nameNorm, pairedNames.contains(nameNorm) else {
            // Unpaired device advertising nearby - drop!
            return
        }

        // Security gate 2: If advertisement contains MAC address, it MUST match a paired MAC
        if let advMac = BudsDeviceFilter.parseAdvertisementAddress(advertisementData) {
            guard pairedAddresses.contains(advMac) else {
                // Same model name, but different physical hardware (coworker/neighbor)! Drop!
                return
            }
        }

        let isKnown = (peripheral.identifier.uuidString == UserDefaults.standard.string(forKey: Self.peripheralUUIDKey))
        log("Discovered paired bud: \(rawName ?? "unnamed") (RSSI: \(RSSI), isKnown=\(isKnown))")
        guard isKnown || BudsDeviceFilter.matchesAdvertisement(peripheralName: rawName, advertisementData: advertisementData) else { return }

        // Opportunistically extract battery status from advertisement frame before GATT handshake finishes
        if let advBattery = BudsDeviceFilter.parseAdvertisementBattery(advertisementData) {
            self.battery = advBattery
            self.batterySeq &+= 1
            log("Extracted adv battery: L=\(advBattery.left ?? -1)% R=\(advBattery.right ?? -1)% Case=\(advBattery.case ?? -1)%")
        }

        scanWatchdogTask?.cancel()
        scanWatchdogTask = nil
        central.stopScan()
        if let p = self.peripheral, p.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(p)
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        let displayName = rawName ?? UserDefaults.standard.string(forKey: "buds.lastDeviceName")
        log("Connecting to \(displayName ?? "device")...")
        connectionState = .connecting(name: displayName)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        central.stopScan()
        scanWatchdogTask?.cancel()
        scanWatchdogTask = nil
        let displayName = peripheral.name ?? UserDefaults.standard.string(forKey: "buds.lastDeviceName")
        log("Connected: \(displayName ?? "device") -> discovering GATT services")
        connectionState = .discovering(name: displayName)
        authState = .notAuthenticated
        sessionReadyTriggered = false
        write079A = nil
        notify079A = nil
        notifyChars = []
        didInitialRefreshAfterConnect = false
        // New BLE session: drop stale cached state so UI doesn't show old modes as "current".
        ancMode = nil

        serviceDiscoveryTimeoutTask?.cancel()
        serviceDiscoveryTimeoutTask = Task { @MainActor [weak self, weak peripheral] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, let peripheral else { return }
            if case .discovering = self.connectionState {
                self.log("Service discovery timed out for \(peripheral.name ?? "device")")
                self.central?.cancelPeripheralConnection(peripheral)
                self.peripheral = nil
                self.connectionState = .failed(message: "Discovery timed out")
                self.scheduleReconnect()
            }
        }

        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        serviceDiscoveryTimeoutTask?.cancel()
        serviceDiscoveryTimeoutTask = nil
        self.peripheral = nil
        connectionState = .failed(message: "Failed to connect")
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected: \(peripheral.name ?? "device") (\(error?.localizedDescription ?? "clean"))")
        serviceDiscoveryTimeoutTask?.cancel()
        serviceDiscoveryTimeoutTask = nil
        scanWatchdogTask?.cancel()
        scanWatchdogTask = nil
        authState = .notAuthenticated
        sessionReadyTriggered = false
        write079A = nil
        notify079A = nil
        notifyChars = []
        didInitialRefreshAfterConnect = false
        lastAuthAt = nil
        ancMode = nil
        self.peripheral = nil

        let displayName = peripheral.name ?? UserDefaults.standard.string(forKey: "buds.lastDeviceName")
        connectionState = .reconnecting(name: displayName)
        startScanOrRetrieve()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            logger.error("Service discovery error: \(error.localizedDescription)")
            serviceDiscoveryTimeoutTask?.cancel()
            serviceDiscoveryTimeoutTask = nil
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            connectionState = .failed(message: "Failed to discover services")
            scheduleReconnect()
            return
        }

        let services = peripheral.services ?? []
        if services.isEmpty {
            serviceDiscoveryTimeoutTask?.cancel()
            serviceDiscoveryTimeoutTask = nil
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            connectionState = .failed(message: "No services found")
            scheduleReconnect()
            return
        }

        let hasBudsService = services.contains { s in
            let u = s.uuid.uuidString.uppercased()
            return u == OPOProtocol.service079A.uppercased() ||
                   u == OPOProtocol.service08A4.uppercased()
        }
        guard hasBudsService else {
            logger.info("Connected peripheral is not a OnePlus audio device (missing 079A/08A4 services), disconnecting")
            serviceDiscoveryTimeoutTask?.cancel()
            serviceDiscoveryTimeoutTask = nil
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            connectionState = .idle
            scheduleReconnect()
            return
        }

        // Security gate: re-verify connected peripheral is paired to macOS
        let paired = getPairedBudsRecords()
        let pairedNames = Set(paired.map { $0.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        let nameNorm = peripheral.name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard pairedNames.contains(nameNorm) else {
            logger.info("Security gate: Connected peripheral '\(peripheral.name ?? "unnamed", privacy: .public)' is not paired to Mac; disconnecting immediately")
            serviceDiscoveryTimeoutTask?.cancel()
            serviceDiscoveryTimeoutTask = nil
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            connectionState = .failed(message: "Not paired to Mac")
            return
        }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            logger.error("Characteristic discovery error for \(service.uuid.uuidString): \(error.localizedDescription)")
        }

        for ch in service.characteristics ?? [] {
            let uuid = ch.uuid.uuidString.uppercased()
            let props = ch.properties
            let serviceUUID = service.uuid.uuidString.uppercased()
            let is079C = serviceUUID == "0000079C-D102-11E1-9B23-00025B00A5A5"

            if uuid == OPOProtocol.write079A || uuid == OPOProtocol.write08A4 {
                write079A = ch
            } else if uuid == OPOProtocol.notify079A || uuid == OPOProtocol.notify08A4 {
                notify079A = ch
            }

            // We never do polling, so we rely on notifications for "live" updates.
            // Subscribe to all safe notify/indicate characteristics (excluding 079C, which can
            // require encryption and disconnect), but only enable them when live updates are on.
            if !is079C,
               (props.contains(.notify) || props.contains(.indicate)),
               !(props.contains(.notifyEncryptionRequired) || props.contains(.indicateEncryptionRequired)) {
                rememberNotifyChar(ch)
                peripheral.setNotifyValue(liveUpdatesEnabled, for: ch)
            }
        }

        // Only consider the session "ready" once we have both the write and notify paths.
        // If we start sending queries before 0200079A notifications are enabled, we can miss
        // the response and time out even though the buds replied.
        if write079A != nil, notify079A != nil, !sessionReadyTriggered {
            sessionReadyTriggered = true
            serviceDiscoveryTimeoutTask?.cancel()
            serviceDiscoveryTimeoutTask = nil

            let paired = getPairedBudsRecords()
            let pairedNames = Set(paired.map { $0.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
            let nameNorm = peripheral.name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pairedNames.contains(nameNorm) {
                UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.peripheralUUIDKey)
                if let name = peripheral.name {
                    UserDefaults.standard.set(name, forKey: "buds.lastDeviceName")
                }
            }

            log("Session ready: write and notify channels established")
            connectionState = .connected(name: peripheral.name)
            didInitialRefreshAfterConnect = true

            // Send handshake immediately to keep connection alive and receive live state.
            // Firmwares (like Buds Z2) choke and cleanly drop GATT if duplicate un-serialized HELLO/REGISTER
            // packets are transmitted simultaneously. We deduplicate with `sessionReadyTriggered` and serialize
            // the handshake via the operation queue to prevent race conditions.
            enqueue(kind: .authenticate, timeout: .seconds(8), maxRetries: 0) { [weak self] in
                guard let self else { return }
                try await self.ensureAuthenticated()
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if debugEnabled {
            if let error {
                print("[BLE] Notify state error (\(characteristic.uuid.uuidString)): \(error)")
            } else {
                print("[BLE] Notify state ok (\(characteristic.uuid.uuidString)): isNotifying=\(characteristic.isNotifying ? "y" : "n")")
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        if liveUpdatesEnabled {
            liveRxPackets &+= 1
            liveRxBytes &+= bytes.count
        }
        let hex = OPOProtocol.hex(bytes)
        logger.debug("[RX] \(characteristic.uuid.uuidString, privacy: .public): \(hex, privacy: .public)")
        if debugEnabled { print("[RX] \(characteristic.uuid.uuidString): \(hex)") }

        // Battery (strict: CAT=0x06 SUB=0x81 CMD=0x25)
        if bytes.count >= 11, bytes[safe: 4] == 0x06, bytes[safe: 5] == 0x81, bytes[safe: 6] == 0x25 {
            if let b = OPOParse.parseBattery(bytes) {
                battery = b
                batterySeq &+= 1
                logger.info("Battery parsed L=\(b.left ?? -1, privacy: .public) R=\(b.right ?? -1, privacy: .public) Case=\(b.case ?? -1, privacy: .public)")
            }
            return
        }

        // Battery (telemetry embedded; used to opportunistically learn case % without polling)
        if let b = OPOParse.parseBatteryTelemetry(bytes) {
            // Plausibility gate: never allow telemetry to clobber clearly-real values with garbage.
            // If we already have strong L/R values, ignore huge deltas.
            if let cur = battery {
                if let cl = cur.left, let nl = b.left, abs(cl - nl) > 30 { return }
                if let cr = cur.right, let nr = b.right, abs(cr - nr) > 30 { return }
                if let cc = cur.case, let nc = b.case, abs(cc - nc) > 40 { return }
            }

            battery = b
            batterySeq &+= 1
            logger.info("Battery telemetry L=\(b.left ?? -1, privacy: .public) R=\(b.right ?? -1, privacy: .public) Case=\(b.case ?? -1, privacy: .public)")
        }

        // Device info
        if bytes.count >= 8, bytes[safe: 4] == 0x03, bytes[safe: 5] == 0x81 {
            if let i = OPOParse.parseDeviceInfo(bytes) {
                deviceInfo = i
                deviceInfoSeq &+= 1
            }
            return
        }

        // EQ
        if bytes.count >= 7, bytes[safe: 4] == 0x05 {
            if let e = OPOParse.parseEQ(bytes) {
                // Preserve best-effort active preset across table refreshes; firmware often
                // doesn't include "current preset" in the EQ table response.
                var merged = e
                if merged.currentPreset == nil {
                    merged.currentPreset = eqStatus?.currentPreset
                }
                merged.lastUpdated = Date()
                eqStatus = merged
                eqSeq &+= 1
                if !merged.presets.isEmpty {
                    logger.info("EQ parsed presets=\(merged.presets.count, privacy: .public) current=\(merged.currentPreset ?? -1, privacy: .public)")
                }
            }
            return
        }

        // ANC (push frames)
        if let raw = OPOParse.parseANCModeByte(bytes) {
            let sub = bytes[safe: 5]

            // Query responses: wire bytes should map cleanly.
            if sub == 0x81, let m = ANCWireMapping.fromWire(raw) {
                if ancMode != m {
                    ancMode = m
                    ancSeq &+= 1
                }
                return
            }

            // 1) Push-status mapping (observed)
            if sub == 0x02 {
                let pushMode: ANCMode? = {
                    switch raw {
                    case 0x08, 0x04, 0x10: return .on
                    case 0x02: return .transparency
                    case 0x01: return .off
                    default: return nil
                    }
                }()
                if let m = pushMode {
                    if ancMode != m {
                        ancMode = m
                        ancSeq &+= 1
                        if debugEnabled {
                            print("[ANC] Push state \(String(format: "%02X", raw)) -> \(m.rawValue)")
                        }
                    }
                    return
                }
            }
        }

        // Registration ack (script checks bytes[2] == 0x81). Not used for flow currently.
    }

    // Note: we intentionally do not attempt to "resolve" unknown ANC push bytes by querying,
    // because constant/background polling is undesirable. If the buds send unknown status
    // bytes, the app will reflect the last known mode until a known push state arrives.
}

// MARK: - IOBluetoothBridge (Thread-safe un-isolated bridge)

/// Objective-C notification bridge for `IOBluetoothDevice` connection events.
///
/// `IOBluetoothDevice.register(forConnectNotifications:selector:)` requires an `@objc` target
/// with an Objective-C selector that will be invoked from IOBluetooth background queues.
/// Holding a weak reference to `BudsClientImpl`, this bridge isolates the un-isolated
/// Objective-C callback and safely dispatches to `@MainActor` to update client state.
private final class IOBluetoothBridge: NSObject {
    private weak var client: BudsClientImpl?

    init(client: BudsClientImpl) {
        self.client = client
        super.init()
    }

    /// Objective-C notification callback invoked by IOBluetooth when any Bluetooth device connects.
    ///
    /// - Parameters:
    ///   - notification: The notification token object.
    ///   - device: The `IOBluetoothDevice` instance that connected.
    @objc func handleConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.nameOrAddress ?? "unknown"
        Task { @MainActor [weak client] in
            client?.handleIOBluetoothDeviceConnected(name: name)
        }
    }
}

