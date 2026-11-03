import UIKit
import CoreBluetooth

/// 근처 BLE 장치 목록 (검색되는 대로 추가됨)
final class ScanViewController: UITableViewController, UIAdaptivePresentationControllerDelegate {

    var onSelect: ((CBPeripheral) -> Void)?
    var onCancel: (() -> Void)?

    private struct Item {
        let peripheral: CBPeripheral   // 연결하려면 장치 객체를 붙잡고 있어야 함
        var name: String
        var rssi: Int
    }
    private var items: [Item] = []
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "장치 찾는 중…"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                           target: self,
                                                           action: #selector(cancelTapped))
        navigationController?.presentationController?.delegate = self
    }

    func update(_ peripheral: CBPeripheral, name: String, rssi: Int) {
        if let i = items.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            items[i].name = name
            items[i].rssi = rssi
        } else {
            items.append(Item(peripheral: peripheral, name: name, rssi: rssi))
        }
        if isViewLoaded {
            title = finished ? "장치 선택" : "장치 선택 (찾는 중…)"
            tableView.reloadData()
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
        cell.textLabel?.text = item.name
        cell.detailTextLabel?.text = "\(item.rssi) dBm"
        cell.detailTextLabel?.textColor = .secondaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let peripheral = items[indexPath.row].peripheral
        dismiss(animated: true)
        onSelect?(peripheral)
    }
}
