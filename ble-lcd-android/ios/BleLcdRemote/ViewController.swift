import UIKit
import WebKit

/// 화면은 안드로이드 앱과 같은 assets/index.html 을 그대로 쓰고,
/// 블루투스는 BleManager(CoreBluetooth)로 처리한다.
/// 웹 화면에는 안드로이드와 같은 이름의 window.AndroidBle 객체를 만들어 넣어서 HTML을 고치지 않고 함께 쓴다.
final class ViewController: UIViewController, WKScriptMessageHandler {

    private var webView: WKWebView!
    private var ble: BleManager!

    /// 웹 화면에 넣는 연결 코드 (페이지가 시작되기 전에 실행됨)
    private static let bridgeScript = """
    (function(){
      var post = function(cmd, extra){
        var m = extra || {}; m.cmd = cmd;
        window.webkit.messageHandlers.ble.postMessage(m);
      };
      var connected = false;
      window.__bleSetConnected = function(v){ connected = !!v; };
      window.AndroidBle = {
        connect: function(){ post('connect'); },
        disconnect: function(){ post('disconnect'); },
        write: function(hex){ if(!connected) return false; post('write', {hex: String(hex)}); return true; },
        setAutoReconnect: function(on){ post('autoReconnect', {on: !!on}); },
        setKeepScreenOn: function(on){ post('keepScreenOn', {on: !!on}); },
        vibrate: function(ms){ post('vibrate', {ms: ms|0}); },
        isConnected: function(){ return connected; }
      };
    })();
    """

    override func loadView() {
        let contents = WKUserContentController()
        contents.addUserScript(WKUserScript(source: Self.bridgeScript,
                                            injectionTime: .atDocumentStart,
                                            forMainFrameOnly: true))
        contents.add(WeakMessageHandler(self), name: "ble")

        let config = WKWebViewConfiguration()
        config.userContentController = contents

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0x0F / 255, green: 0x11 / 255, blue: 0x15 / 255, alpha: 1)
                : UIColor(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255, alpha: 1)
        }
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never   // 안전 영역은 HTML(env(safe-area-inset-*))이 처리
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ble = BleManager(presenter: self) { [weak self] script in
            self?.webView.evaluateJavaScript(script, completionHandler: nil)
        }
        if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets") {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
    }

    // MARK: - 웹 화면에서 온 요청

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "connect":
            ble.connect()
        case "disconnect":
            ble.disconnect()
        case "write":
            if let hex = body["hex"] as? String { ble.write(hex: hex) }
        case "autoReconnect":
            ble.autoReconnect = (body["on"] as? Bool) ?? true
        case "keepScreenOn":
            UIApplication.shared.isIdleTimerDisabled = (body["on"] as? Bool) ?? false
        case "vibrate":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        default:
            break
        }
    }
}

/// WKUserContentController가 화면을 붙잡아 메모리가 새지 않도록 약한 참조로 전달
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
