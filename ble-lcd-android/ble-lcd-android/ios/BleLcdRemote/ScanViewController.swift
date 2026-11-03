import UIKit
import CoreBluetooth

/// 근처 BLE 장치 목록 (검색되는 대로 추가됨)
final class ScanViewController: UITableViewController, UIAdaptivePresentationControllerDelegate {

    var onSelect: ((CBPeripheral, String?) -> Void)?
    var onCancel: (() -> Void)?
    var onRescan: (() -> Void)?
    var savedId: UUID?

    private struct Item {
        let peripheral: CBPeripheral   // 연결하려면 장치 객체를 붙잡고 있어야 함
        var name: String?
        var rssi: Int
        let connected: Bool
    }
    private var items: [Item] = []
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "장치 찾는 중…"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                           target: self,
                                                           action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "다시 찾기", style: .plain,
                                                            target: self,
                                                            action: #selector(rescanTapped))
        navigationController?.presentationController?.delegate = self
    }

    /// 목록 비우고 다시 검색 시작할 때
    func reset() {
        items.removeAll()
        finished = false
        if isViewLoaded {
            title = "장치 찾는 중…"
            tableView.reloadData()
        }
    }

    func update(_ peripheral: CBPeripheral, name: String?, rssi: Int, connected: Bool = false) {
        if let i = items.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            if let n = name, !n.isEmpty { items[i].name = n }   // 이름은 나중에 오는 경우가 많음
            if !connected { items[i].rssi = rssi }
        } else {
            let n = (name?.isEmpty == false) ? name : nil
            items.append(Item(peripheral: peripheral, name: n, rssi: rssi, connected: connected))
        }
        sortItems()
        if isViewLoaded {
            title = finished ? "장치 선택" : "장치 선택 (찾는 중…)"
            tableView.reloadData()
        }
    }

    /// 이미 연결됨 → 저장된 장치 → 이름 있는 장치(신호 센 순) → 이름 없는 장치
    private func sortItems() {
        let saved = savedId
        items.sort { a, b in
            if a.connected != b.connected { return a.connected }
            let aSaved = a.peripheral.identifier == saved, bSaved = b.peripheral.identifier == saved
            if aSaved != bSaved { return aSaved }
            if (a.name != nil) != (b.name != nil) { return a.name != nil }
            return a.rssi > b.rssi
        }
    }

    func scanFinished() {
        finished = true
        if isViewLoaded { title = items.isEmpty ? "장치를 찾지 못했어요" : "장치 선택" }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
        onCancel?()
    }

    @objc private func rescanTapped() {
        onRescan?()
    }

    // 아래로 쓸어내려 닫은 경우
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onCancel?()
    }

    // MARK: - 표

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        let item = items[indexPath.row]
        cell.textLabel?.text = item.name ?? "(이름 없음)"
        cell.textLabel?.textColor = item.name == nil ? .secondaryLabel : .label
        var detail: [String] = []
        if item.connected { detail.append("이미 연결됨") }
        else { detail.append("\(item.rssi) dBm") }
        if item.peripheral.identifier == savedId { detail.append("저장된 장치") }
        detail.append(String(item.peripheral.identifier.uuidString.prefix(8)))
        cell.detailTextLabel?.text = detail.joined(separator: " · ")
        cell.detailTextLabel?.textColor = .secondaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items[indexPath.row]
        dismiss(animated: true)
        onSelect?(item.peripheral, item.name)
    }
}
