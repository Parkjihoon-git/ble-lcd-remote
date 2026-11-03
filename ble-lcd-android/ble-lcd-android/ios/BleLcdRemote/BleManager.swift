import UIKit
import CoreBluetooth

/// BLE 검색 · 연결 · 수신 · 송신 (CoreBluetooth, 메인 스레드에서 동작)
///
/// 웹 화면으로 보내는 알림 (안드로이드 앱과 같음):
///   window.bleOnState(state, name, msg)  state = scanning | connecting | reconnecting | connected | disconnected | cancelled | error
///   window.bleOnReady(hasNotify, hasWrite)
///   window.bleOnData(hex)
final class BleManager: NSObject {

    /// 키를 보낼 때 우선 쓰는 특성: HM-10/JDY 계열(FFE1), Nordic UART RX
    private static let preferredWrite: Set<CBUUID> = [
        CBUUID(string: "FFE1"),
        CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"),
    ]
    /// 이미 연결된 장치를 찾을 때 쓰는 서비스: HM-10/JDY(FFE0), Nordic UART, ESP32 예제, FFF0
    private static let knownServices: [CBUUID] = [
        CBUUID(string: "FFE0"),
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
        CBUUID(string: "4FAFC201-1FB5-459E-8FCC-C5C9C331914B"),
        CBUUID(string: "FFF0"),
    ]
    private static let chunkSize = 20
    private static let scanSeconds: TimeInterval = 20
    private static let connectTimeout: TimeInterval = 12

    private let js: (String) -> Void
    private weak var presenter: UIViewController?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var pendingServices = 0

    private var wantScan = false
    private var scanVC: ScanViewController?
    private var scanTimer: Timer?
    private var connectTimer: Timer?

    private var manualDisconnect = false
    var autoReconnect = true
    private(set) var isConnected = false

    private var writeQueue: [Data] = []
    private var waitingWriteResponse = false

    // 마지막으로 연결한 장치 기억 (다음에는 선택 없이 바로 연결)
    private let defaults = UserDefaults.standard
    private var wantChoose = false        // true: 저장된 장치가 있어도 선택 창
    private var tryingSaved = false
    /// 저장된 장치 이름. 저장된 장치가 없으면 빈 문자열 (이름을 모르면 "BLE 장치")
    var savedName: String {
        guard savedId != nil else { return "" }
        let n = defaults.string(forKey: "ble.savedName") ?? ""
        return n.isEmpty ? "BLE 장치" : n
    }
    private var pendingName: String?          // 목록에서 고른 장치의 이름 (검색 신호에서 읽은 이름)
    private var savedId: UUID? { defaults.string(forKey: "ble.savedId").flatMap(UUID.init(uuidString:)) }

    /// 저장된 장치 이름이 바뀌면 알려줌 (화면에 넣는 연결 코드에 반영)
    var onSavedChange: ((String) -> Void)?

    init(presenter: UIViewController, js: @escaping (String) -> Void) {
        self.presenter = presenter
        self.js = js
        super.init()
    }

    // MARK: - 웹 화면으로 알림

    private func quote(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s]),
           var text = String(data: data, encoding: .utf8), text.count >= 2 {
            text.removeFirst()   // [
            text.removeLast()    // ]
            return text
        }
        return "\"\""
    }

    private func emitState(_ state: String, _ msg: String = "") {
        var name = peripheral?.name ?? ""
        if name.isEmpty, let p = peripheral {
            name = p.identifier == savedId ? savedName : (pendingName ?? "")
        }
        js("window.__bleSetConnected && window.__bleSetConnected(\(isConnected));" +
           "window.bleOnState && window.bleOnState(\(quote(state)),\(quote(name)),\(quote(msg)))")
    }

    // MARK: - 연결 시작 (검색 → 장치 선택)

    func connect(choose: Bool = false) {
        wantChoose = choose
        if central == nil {
            // 처음 만들 때 블루투스 권한을 물어봄. 상태가 정해지면 검색 시작
            wantScan = true
            central = CBCentralManager(delegate: self, queue: nil)
            return
        }
        wantScan = true
        startScanIfReady()
    }

    private func startScanIfReady() {
        guard wantScan, let central = central else { return }
        switch central.state {
        case .poweredOn:
            wantScan = false
            if !wantChoose, let id = savedId,
               let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                connectTo(p, fromSaved: true)      // 저장된 장치로 바로 연결
            } else {
                showPicker()
            }
            wantChoose = false
        case .unknown, .resetting:
            break   // 상태가 정해지면 다시 호출됨
        case .poweredOff:
            wantScan = false
            emitState("error", "블루투스를 켜주세요 (제어 센터 또는 설정)")
        case .unauthorized:
            wantScan = false
            emitState("error", "설정 → BLE LCD 리모컨 → 블루투스를 허용해 주세요")
        case .unsupported:
            wantScan = false
            emitState("error", "이 기기는 블루투스 LE를 지원하지 않아요")
        @unknown default:
            wantScan = false
            emitState("error", "블루투스를 사용할 수 없어요")
        }
    }

    private func showPicker() {
        guard central != nil, let presenter = presenter else { return }
        stopScan()

        let vc = ScanViewController()
        vc.onSelect = { [weak self] p, name in
            self?.stopScan()
            self?.scanVC = nil
            self?.pendingName = name
            self?.connectTo(p, fromSaved: false)
        }
        vc.onCancel = { [weak self] in
            self?.stopScan()
            self?.scanVC = nil
            self?.emitState("cancelled")
        }
        vc.onRescan = { [weak self] in self?.startScan() }
        vc.savedId = savedId
        scanVC = vc
        let nav = UINavigationController(rootViewController: vc)
        nav.presentationController?.delegate = vc
        presenter.present(nav, animated: true)
        startScan()
    }

    /// 목록을 비우고 검색 (처음 / "다시 찾기")
    private func startScan() {
        guard let central = central, central.state == .poweredOn else { return }
        stopScan()
        scanVC?.reset()
        // 휴대폰이 이미 연결하고 있는 장치는 광고를 멈춰서 검색에 안 나옴 → 따로 목록에 넣음
        for p in central.retrieveConnectedPeripherals(withServices: Self.knownServices) {
            scanVC?.update(p, name: p.name, rssi: 0, connected: true)
        }
        // 중복 허용: 이름(스캔 응답)이 나중에 오는 장치도 이름이 채워지도록
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        emitState("scanning")
        scanTimer = Timer.scheduledTimer(withTimeInterval: Self.scanSeconds, repeats: false) { [weak self] _ in
            self?.stopScan()
            self?.scanVC?.scanFinished()
        }
    }

    private func stopScan() {
        scanTimer?.invalidate()
        scanTimer = nil
        if let central = central, central.isScanning { central.stopScan() }
    }

    private func connectTo(_ p: CBPeripheral, fromSaved: Bool) {
        guard let central = central else { return }
        if let old = peripheral, old.identifier != p.identifier {
            manualDisconnect = true
            central.cancelPeripheralConnection(old)
        }
        resetLink()
        peripheral = p
        p.delegate = self
        manualDisconnect = false
        tryingSaved = fromSaved
        emitState("connecting")
        central.connect(p, options: nil)

        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: Self.connectTimeout, repeats: false) { [weak self] _ in
            guard let self = self, !self.isConnected, let p = self.peripheral else { return }
            self.manualDisconnect = true          // 시간 초과는 자동 재연결하지 않음
            self.central?.cancelPeripheralConnection(p)
            if self.tryingSaved {
                self.savedFailed()
            } else {
                self.emitState("error", "연결 시간이 초과됐어요")
            }
        }
    }

    /// 저장된 장치로 바로 연결이 안 되면 장치 선택 창으로
    private func savedFailed() {
        tryingSaved = false
        let name = savedName
        emitState("error", "저장된 장치\(name.isEmpty ? "" : "(\(name))")에 연결하지 못했어요. 장치를 선택하세요")
        showPicker()
    }

    func forgetDevice() {
        defaults.removeObject(forKey: "ble.savedId")
        defaults.removeObject(forKey: "ble.savedName")
        emitSaved()
    }

    private func saveDevice(_ p: CBPeripheral) {
        let sameAsSaved = p.identifier == savedId
        let stored = defaults.string(forKey: "ble.savedName") ?? ""
        let name: String
        if let n = p.name, !n.isEmpty { name = n }
        else if let n = pendingName, !n.isEmpty { name = n }
        else if sameAsSaved, !stored.isEmpty { name = stored }
        else { name = "BLE 장치" }
        defaults.set(p.identifier.uuidString, forKey: "ble.savedId")
        defaults.set(name, forKey: "ble.savedName")
        emitSaved()
    }

    private func emitSaved() {
        let n = savedName
        onSavedChange?(n)
        js("window.__bleSetSaved && window.__bleSetSaved(\(quote(n)));" +
           "window.bleOnSaved && window.bleOnSaved(\(quote(n)))")
    }

    func disconnect() {
        manualDisconnect = true
        connectTimer?.invalidate()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        resetLink()
        emitState("disconnected", "연결 안 됨")
    }

    private func resetLink() {
        isConnected = false
        writeChar = nil
        pendingServices = 0
        writeQueue.removeAll()
        waitingWriteResponse = false
    }

    // MARK: - 연결 후 설정

    private func finishSetup(_ p: CBPeripheral) {
        var preferred: CBCharacteristic?
        var firstWritable: CBCharacteristic?
        var notifyCount = 0

        for service in p.services ?? [] {
            for c in service.characteristics ?? [] {
                let props = c.properties
                if props.contains(.write) || props.contains(.writeWithoutResponse) {
                    if firstWritable == nil { firstWritable = c }
                    if Self.preferredWrite.contains(c.uuid) { preferred = c }
                }
                if props.contains(.notify) || props.contains(.indicate) {
                    p.setNotifyValue(true, for: c)
                    notifyCount += 1
                }
            }
        }

        writeChar = preferred ?? firstWritable
        isConnected = true
        tryingSaved = false
        saveDevice(p)
        emitState("connected")
        js("window.bleOnReady && window.bleOnReady(\(notifyCount > 0),\(writeChar != nil))")
    }

    // MARK: - 송신 (20바이트씩 순서대로)

    func write(hex: String) {
        guard isConnected, writeChar != nil, let data = Data(hexString: hex), !data.isEmpty else { return }
        var i = 0
        while i < data.count {
            writeQueue.append(data.subdata(in: i..<min(i + Self.chunkSize, data.count)))
            i += Self.chunkSize
        }
        pump()
    }

    private func pump() {
        guard let p = peripheral, let c = writeChar else {
            writeQueue.removeAll()
            return
        }
        let withResponse = c.properties.contains(.write)
        while !writeQueue.isEmpty {
            if withResponse {
                if waitingWriteResponse { return }
                p.writeValue(writeQueue.removeFirst(), for: c, type: .withResponse)
                waitingWriteResponse = true
                return
            } else {
                if !p.canSendWriteWithoutResponse { return }   // 준비되면 peripheralIsReady에서 다시 보냄
                p.writeValue(writeQueue.removeFirst(), for: c, type: .withoutResponse)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if wantScan {
                startScanIfReady()
            } else if let p = peripheral, !isConnected, !manualDisconnect, autoReconnect {
                // 블루투스를 껐다 켠 경우 다시 연결
                emitState("reconnecting", "다시 연결 중…")
                central.connect(p, options: nil)
            }
        } else {
            if isConnected {
                resetLink()
                emitState("disconnected", "블루투스가 꺼졌어요")
            }
            startScanIfReady()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let rssi = RSSI.intValue
        guard rssi != 127 else { return }               // 127 = 신호 세기 알 수 없음
        scanVC?.update(peripheral, name: name, rssi: rssi)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        connectTimer?.invalidate()
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        connectTimer?.invalidate()
        resetLink()
        if tryingSaved {
            savedFailed()
            return
        }
        emitState("error", "연결하지 못했어요" + (error.map { ": \($0.localizedDescription)" } ?? ""))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        resetLink()
        if !manualDisconnect && autoReconnect {
            // iOS는 장치가 다시 보이면 알아서 연결해 줌 (시간 제한 없음)
            emitState("reconnecting", "다시 연결 중…")
            central.connect(peripheral, options: nil)
        } else {
            emitState("disconnected", manualDisconnect ? "연결 안 됨" : "연결이 끊어졌어요")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BleManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        if error != nil || services.isEmpty {
            finishSetup(peripheral)
            return
        }
        pendingServices = services.count
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServices -= 1
        if pendingServices == 0 { finishSetup(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
        js("window.bleOnData && window.bleOnData('\(value.hexString)')")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        waitingWriteResponse = false
        pump()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump()
    }
}

// MARK: - HEX 변환

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.filter { !$0.isWhitespace })
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
