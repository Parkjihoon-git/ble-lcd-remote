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
    private static let chunkSize = 20
    private static let scanSeconds: TimeInterval = 15
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
        let name = peripheral?.name ?? ""
        js("window.__bleSetConnected && window.__bleSetConnected(\(isConnected));" +
           "window.bleOnState && window.bleOnState(\(quote(state)),\(quote(name)),\(quote(msg)))")
    }

    // MARK: - 연결 시작 (검색 → 장치 선택)

    func connect() {
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
            showPicker()
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
        guard let central = central, let presenter = presenter else { return }
        stopScan()

        let vc = ScanViewController()
        vc.onSelect = { [weak self] p in
            self?.stopScan()
            self?.scanVC = nil
            self?.connectTo(p)
        }
        vc.onCancel = { [weak self] in
            self?.stopScan()
            self?.scanVC = nil
            self?.emitState("cancelled")
        }
        scanVC = vc
        let nav = UINavigationController(rootViewController: vc)
        nav.presentationController?.delegate = vc
        presenter.present(nav, animated: true)

        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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

    private func connectTo(_ p: CBPeripheral) {
        guard let central = central else { return }
        if let old = peripheral, old.identifier != p.identifier {
            manualDisconnect = true
            central.cancelPeripheralConnection(old)
        }
        resetLink()
        peripheral = p
        p.delegate = self
        manualDisconnect = false
        emitState("connecting")
        central.connect(p, options: nil)

        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: Self.connectTimeout, repeats: false) { [weak self] _ in
            guard let self = self, !self.isConnected, let p = self.peripheral else { return }
            self.manualDisconnect = true          // 시간 초과는 자동 재연결하지 않음
            self.central?.cancelPeripheralConnection(p)
            self.emitState("error", "연결 시간이 초과됐어요")
        }
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
        guard let n = name, !n.isEmpty else { return }   // 이름 없는 장치는 목록에서 뺌
        scanVC?.update(peripheral, name: n, rssi: RSSI.intValue)
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
