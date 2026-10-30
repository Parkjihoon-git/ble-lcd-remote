package com.blelcd.remote

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import androidx.webkit.WebViewAssetLoader

/**
 * 화면은 assets/index.html(웹 화면)을 그대로 쓰고,
 * 블루투스는 BleManager(안드로이드 기본 BLE)로 처리한다.
 * 웹 화면과는 "AndroidBle" 이름의 자바스크립트 브리지로 연결된다.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private lateinit var ble: BleManager

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            if (result.values.all { it }) ensureReadyThenScan()
            else ble.emitState("error", "", "블루투스(근처 기기) 권한을 허용해야 장치를 찾을 수 있어요")
        }

    private val enableBtLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            if (bluetoothAdapter()?.isEnabled == true) ensureReadyThenScan()
            else ble.emitState("error", "", "블루투스를 켜야 연결할 수 있어요")
        }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        webView = WebView(this)
        webView.setBackgroundColor(Color.parseColor("#0F1115"))
        setContentView(webView)

        ble = BleManager(this) { script ->
            runOnUiThread { if (!isDestroyed) webView.evaluateJavascript(script, null) }
        }

        // assets 폴더를 https 주소로 제공 (localStorage·폰트가 안정적으로 동작)
        val assetLoader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest
            ): WebResourceResponse? = assetLoader.shouldInterceptRequest(request.url)
        }

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
        }
        webView.isVerticalScrollBarEnabled = false
        webView.addJavascriptInterface(Bridge(), "AndroidBle")
        webView.loadUrl("https://appassets.androidplatform.net/assets/index.html")
    }

    override fun onDestroy() {
        ble.close()
        webView.removeJavascriptInterface("AndroidBle")
        webView.destroy()
        super.onDestroy()
    }

    // ---------------- 웹 화면에서 부르는 함수들 ----------------
    inner class Bridge {
        @JavascriptInterface
        fun connect() {
            runOnUiThread { startConnectFlow() }
        }

        @JavascriptInterface
        fun disconnect() {
            runOnUiThread { ble.disconnect() }
        }

        /** hex 문자열(예: "130201300703")을 장치로 보냄. 연결돼 있지 않으면 false */
        @JavascriptInterface
        fun write(hex: String): Boolean {
            val bytes = hexToBytes(hex) ?: return false
            return ble.write(bytes)
        }

        @JavascriptInterface
        fun setAutoReconnect(on: Boolean) {
            ble.autoReconnect = on
        }

        @JavascriptInterface
        fun setKeepScreenOn(on: Boolean) {
            runOnUiThread {
                if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }

        @JavascriptInterface
        fun vibrate(ms: Int) {
            vibrateOnce(ms.coerceIn(1, 200).toLong())
        }

        @JavascriptInterface
        fun isConnected(): Boolean = ble.isConnected
    }

    // ---------------- 권한 · 블루투스 켜기 ----------------
    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun startConnectFlow() {
        val missing = requiredPermissions().filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) permissionLauncher.launch(missing.toTypedArray())
        else ensureReadyThenScan()
    }

    private fun bluetoothAdapter(): BluetoothAdapter? =
        (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    @SuppressLint("MissingPermission")
    private fun ensureReadyThenScan() {
        val adapter = bluetoothAdapter()
        if (adapter == null) {
            ble.emitState("error", "", "이 휴대폰은 블루투스를 지원하지 않아요")
            return
        }
        if (!adapter.isEnabled) {
            enableBtLauncher.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
            return
        }
        // Android 11 이하는 위치(GPS)가 꺼져 있으면 BLE 검색 결과가 나오지 않음
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            if (!LocationManagerCompat.isLocationEnabled(lm)) {
                ble.emitState("error", "", "Android 11 이하에서는 위치(GPS)를 켜야 장치를 찾을 수 있어요")
                return
            }
        }
        ble.startScanAndPick()
    }

    // ---------------- 진동 ----------------
    @Suppress("DEPRECATION")
    private fun vibrateOnce(ms: Long) {
        val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        if (vibrator != null && vibrator.hasVibrator()) {
            vibrator.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
        }
    }

    private fun hexToBytes(hex: String): ByteArray? {
        val clean = hex.filter { !it.isWhitespace() }
        if (clean.length % 2 != 0) return null
        return try {
            ByteArray(clean.length / 2) { i -> clean.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
        } catch (e: NumberFormatException) {
            null
        }
    }
}
