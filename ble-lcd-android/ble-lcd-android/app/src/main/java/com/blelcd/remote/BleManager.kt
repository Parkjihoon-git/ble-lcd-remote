package com.blelcd.remote

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.DialogInterface
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.widget.ArrayAdapter
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import java.util.UUID

/**
 * BLE 검색 · 연결 · 수신 · 송신.
 * 모든 블루투스 작업은 메인 스레드에서 한 번에 하나씩 순서대로 처리한다 (안드로이드 BLE는 동시 작업에 약함).
 *
 * 웹 화면으로 보내는 알림:
 *   window.bleOnState(state, name, msg)  state = scanning | connecting | reconnecting | connected | disconnected | cancelled | error
 *   window.bleOnReady(hasNotify, hasWrite)
 *   window.bleOnData(hex)
 */
@SuppressLint("MissingPermission")
class BleManager(
    private val activity: AppCompatActivity,
    private val js: (String) -> Unit
) {
    companion object {
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private val GENERIC_ATTRIBUTE: UUID = UUID.fromString("00001801-0000-1000-8000-00805f9b34fb")
        /** 키를 보낼 때 우선 쓰는 특성: HM-10/JDY 계열(FFE1), Nordic UART RX */
        private val PREFERRED_WRITE: Set<UUID> = setOf(
            UUID.fromString("0000ffe1-0000-1000-8000-00805f9b34fb"),
            UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
        )
        private const val CHUNK = 20
        private const val SCAN_MS = 20_000L
        private const val CONNECT_TIMEOUT_MS = 12_000L
        private const val MAX_RECONNECT = 6
    }

    private val main = Handler(Looper.getMainLooper())
    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    @Volatile var autoReconnect = true
    @Volatile var isConnected = false
        private set
    @Volatile private var writeChar: BluetoothGattCharacteristic? = null

    private var gatt: BluetoothGatt? = null
    private var device: BluetoothDevice? = null
    private var manualDisconnect = false
    private var reconnectAttempt = 0

    // =============== 마지막으로 연결한 장치 기억 ===============
    private val prefs = activity.getSharedPreferences("ble", Context.MODE_PRIVATE)
    /** 저장된 장치 이름. 저장된 장치가 없으면 빈 문자열 (이름을 모르면 "BLE 장치") */
    val savedName: String
        get() {
            if (prefs.getString("address", null) == null) return ""
            return prefs.getString("name", null)?.takeIf { it.isNotBlank() } ?: "BLE 장치"
        }
    private var pendingName: String? = null   // 목록에서 고른 장치의 이름 (검색 신호에서 읽은 이름)
    private val savedAddress: String? get() = prefs.getString("address", null)
    private var tryingSaved = false       // 저장된 장치로 바로 연결 시도 중
    private var everConnected = false     // 이번 연결 시도에서 한 번이라도 연결됐는지

    /** 저장된 장치로 바로 연결 실패 시 장치 선택 창을 띄워 달라고 화면에 요청 */
    var requestPicker: (() -> Unit)? = null

    /** 저장된 장치가 있으면 선택 창 없이 바로 연결. 저장된 장치가 없으면 false */
    fun connectSaved(): Boolean {
        val addr = savedAddress ?: return false
        val a = adapter ?: return false
        if (!BluetoothAdapter.checkBluetoothAddress(addr)) {
            forgetDevice()
            return false
        }
        val d = try { a.getRemoteDevice(addr) } catch (e: Exception) { return false }
        connectTo(d, fromSaved = true)
        return true
    }

    fun forgetDevice() {
        prefs.edit().clear().apply()
        emitSaved()
    }

    private fun saveDevice(d: BluetoothDevice) {
        val sameAsSaved = d.address == savedAddress
        val name = (try { d.name } catch (e: SecurityException) { null })?.takeIf { it.isNotBlank() }
            ?: pendingName?.takeIf { it.isNotBlank() }
            ?: (if (sameAsSaved) prefs.getString("name", null)?.takeIf { it.isNotBlank() } else null)
            ?: "BLE 장치"
        prefs.edit().putString("address", d.address).putString("name", name).apply()
        emitSaved()
    }

    fun emitSaved() {
        js("window.bleOnSaved && window.bleOnSaved(${q(savedName)})")
    }

    // =============== 알림 ===============
    fun emitState(state: String, name: String, msg: String) {
        js("window.bleOnState && window.bleOnState(${q(state)},${q(name)},${q(msg)})")
    }

    private fun q(s: String): String = JSONObject.quote(s)
    private fun deviceName(): String {
        val n = try { device?.name } catch (e: SecurityException) { null }
        if (!n.isNullOrBlank()) return n
        // 바로 연결한 장치는 이름을 아직 모를 수 있어서 저장된 이름을 씀
        return if (device != null && device?.address == savedAddress) savedName else (pendingName ?: "")
    }

    // =============== 검색 + 장치 선택 창 ===============
    private var scanning = false
    private var dialog: AlertDialog? = null
    private var listAdapter: ArrayAdapter<String>? = null

    private class Found(val device: BluetoothDevice, var name: String?, var rssi: Int, val connected: Boolean)
    private val found = LinkedHashMap<String, Found>()     // 주소 -> 장치
    private var shown: List<Found> = emptyList()           // 화면 목록 순서 (누른 항목 찾기용)

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { addResult(result) }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            main.post { results.forEach { addResult(it) } }
        }

        override fun onScanFailed(errorCode: Int) {
            main.post {
                stopScan()
                dialog?.dismiss()
                emitState("error", "", "장치 검색에 실패했어요 (코드 $errorCode)")
            }
        }
    }

    private val scanTimeout = Runnable {
        stopScan()
        dialog?.setTitle(if (found.isEmpty()) "장치를 찾지 못했어요" else "장치 선택")
    }

    fun startScanAndPick() {
        if (adapter?.bluetoothLeScanner == null) {
            emitState("error", "", "블루투스를 켜주세요")
            return
        }
        stopScan()
        found.clear()
        shown = emptyList()
        val list = ArrayAdapter(activity, android.R.layout.simple_list_item_1, ArrayList<String>())
        listAdapter = list

        dialog?.dismiss()
        val dlg = AlertDialog.Builder(activity)
            .setTitle("장치 찾는 중…")
            .setAdapter(list) { _, which ->
                val entry = shown.getOrNull(which) ?: return@setAdapter
                stopScan()
                pendingName = entry.name
                connectTo(entry.device, fromSaved = false)
            }
            .setNegativeButton("취소") { _, _ ->
                stopScan()
                emitState("cancelled", "", "")
            }
            .setNeutralButton("다시 찾기", null)
            .setOnCancelListener {
                stopScan()
                emitState("cancelled", "", "")
            }
            .create()
        // "다시 찾기"는 창을 닫지 않고 목록을 비운 뒤 다시 검색
        dlg.setOnShowListener {
            dlg.getButton(DialogInterface.BUTTON_NEUTRAL)?.setOnClickListener { restartScan() }
        }
        dialog = dlg
        dlg.show()
        restartScan()
    }

    private fun restartScan() {
        val scanner = adapter?.bluetoothLeScanner ?: return
        stopScan()
        found.clear()
        // 휴대폰이 이미 연결하고 있는 장치는 광고를 멈춰서 검색에 안 나옴 → 따로 목록에 넣음
        try {
            val bm = activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            for (d in bm.getConnectedDevices(BluetoothProfile.GATT)) {
                val n = try { d.name } catch (e: SecurityException) { null }
                found[d.address] = Found(d, n, 0, connected = true)
            }
        } catch (e: Exception) { }
        refreshList()

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        try {
            scanner.startScan(null, settings, scanCallback)
            scanning = true
            dialog?.setTitle("장치 찾는 중…")
            emitState("scanning", "", "")
            main.postDelayed(scanTimeout, SCAN_MS)
        } catch (e: Exception) {
            dialog?.dismiss()
            emitState("error", "", "장치 검색을 시작하지 못했어요: ${e.message}")
        }
    }

    private fun addResult(r: ScanResult) {
        val d = r.device
        val name = r.scanRecord?.deviceName?.takeIf { it.isNotBlank() }
            ?: (try { d.name } catch (e: SecurityException) { null })?.takeIf { it.isNotBlank() }
        val f = found[d.address]
        if (f == null) {
            found[d.address] = Found(d, name, r.rssi, connected = false)
        } else {
            if (name != null) f.name = name           // 이름은 나중 패킷(스캔 응답)에 올 때가 많음
            f.rssi = r.rssi
        }
        refreshList()
        if (scanning) dialog?.setTitle("장치 선택 (찾는 중…)")
    }

    /** 이미 연결됨 → 저장된 장치 → 이름 있는 장치(신호 센 순) → 이름 없는 장치 순으로 보여줌 */
    private fun refreshList() {
        val list = listAdapter ?: return
        val saved = savedAddress
        shown = found.values.sortedWith(
            compareByDescending<Found> { it.connected }
                .thenByDescending { it.device.address == saved }
                .thenByDescending { it.name != null }
                .thenByDescending { it.rssi }
        )
        list.clear()
        list.addAll(shown.map { f ->
            val title = f.name ?: "(이름 없음)"
            val tag = when {
                f.connected -> "   · 이미 연결됨"
                f.device.address == saved -> "   · 저장된 장치"
                else -> ""
            }
            val signal = if (f.connected) "" else "   ${f.rssi} dBm"
            "$title$tag\n${f.device.address}$signal"
        })
        list.notifyDataSetChanged()
    }

    private fun stopScan() {
        main.removeCallbacks(scanTimeout)
        if (scanning) {
            try { adapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (e: Exception) { }
            scanning = false
        }
    }

    // =============== 연결 ===============
    private fun connectTo(d: BluetoothDevice, fromSaved: Boolean) {
        main.removeCallbacks(reconnectRunnable)
        main.removeCallbacks(connectTimeout)
        closeGatt()
        // 이전 연결 상태 정리 (다른 장치로 바꿀 때)
        isConnected = false
        writeChar = null
        queue.clear()
        busy = false
        main.removeCallbacks(opTimeout)
        device = d
        tryingSaved = fromSaved
        everConnected = false
        manualDisconnect = false
        reconnectAttempt = 0
        emitState("connecting", deviceName(), "")
        openGatt()
    }

    private fun openGatt() {
        val d = device ?: return
        closeGatt()
        gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            d.connectGatt(activity, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            d.connectGatt(activity, false, gattCallback)
        }
        main.removeCallbacks(connectTimeout)
        main.postDelayed(connectTimeout, CONNECT_TIMEOUT_MS)
    }

    private val connectTimeout = Runnable {
        if (!isConnected) {
            closeGatt()
            handleDisconnect("연결 시간이 초과됐어요")
        }
    }

    private val reconnectRunnable = Runnable {
        if (!manualDisconnect && device != null) {
            emitState("reconnecting", deviceName(), "다시 연결 중… ($reconnectAttempt)")
            openGatt()
        }
    }

    fun disconnect() {
        manualDisconnect = true
        main.removeCallbacks(reconnectRunnable)
        main.removeCallbacks(connectTimeout)
        closeGatt()
        handleDisconnect("연결 안 됨")
    }

    fun close() {
        manualDisconnect = true
        main.removeCallbacks(reconnectRunnable)
        main.removeCallbacks(connectTimeout)
        stopScan()
        dialog?.dismiss()
        dialog = null
        closeGatt()
        isConnected = false
    }

    private fun closeGatt() {
        val g = gatt ?: return
        gatt = null
        try { g.disconnect() } catch (e: Exception) { }
        try { g.close() } catch (e: Exception) { }
    }

    private fun handleDisconnect(msg: String) {
        isConnected = false
        writeChar = null
        queue.clear()
        busy = false
        main.removeCallbacks(opTimeout)

        // 저장된 장치로 바로 연결했는데 한 번도 연결되지 않음 → 장치 선택 창으로
        if (tryingSaved && !everConnected && !manualDisconnect) {
            tryingSaved = false
            val name = savedName
            device = null
            emitState("error", "", "저장된 장치${if (name.isNotBlank()) "($name)" else ""}에 연결하지 못했어요. 장치를 선택하세요")
            requestPicker?.invoke()
            return
        }

        if (!manualDisconnect && autoReconnect && device != null && reconnectAttempt < MAX_RECONNECT) {
            reconnectAttempt++
            val delay = minOf(1000L shl (reconnectAttempt - 1), 8000L)
            emitState("reconnecting", deviceName(), "다시 연결 중… ($reconnectAttempt)")
            main.removeCallbacks(reconnectRunnable)
            main.postDelayed(reconnectRunnable, delay)
        } else {
            val text = when {
                manualDisconnect -> "연결 안 됨"
                reconnectAttempt >= MAX_RECONNECT -> "다시 연결하지 못했어요"
                else -> msg
            }
            emitState("disconnected", deviceName(), text)
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (g != gatt) {             // 이미 닫은 이전 연결
                    try { g.close() } catch (e: Exception) { }
                    return@post
                }
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    main.removeCallbacks(connectTimeout)
                    // 연결 직후 바로 서비스 검색하면 실패하는 기기가 있어 잠깐 기다림
                    main.postDelayed({
                        if (g == gatt && !g.discoverServices()) {
                            closeGatt()
                            handleDisconnect("서비스 검색을 시작하지 못했어요")
                        }
                    }, 300)
                } else {
                    main.removeCallbacks(connectTimeout)
                    closeGatt()
                    handleDisconnect(
                        if (status == BluetoothGatt.GATT_SUCCESS) "연결이 끊어졌어요"
                        else "연결이 끊어졌어요 (코드 $status)"
                    )
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            main.post {
                if (g != gatt) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    closeGatt()
                    handleDisconnect("서비스를 읽지 못했어요 (코드 $status)")
                    return@post
                }
                setupCharacteristics(g)
            }
        }

        // Android 13 이상
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            onReceive(value)
        }

        // Android 12 이하
        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                @Suppress("DEPRECATION")
                val v = characteristic.value
                if (v != null) onReceive(v.copyOf())
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            main.post { if (g == gatt) opDone() }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            main.post { if (g == gatt) opDone() }
        }
    }

    private fun setupCharacteristics(g: BluetoothGatt) {
        var preferred: BluetoothGattCharacteristic? = null
        var firstWritable: BluetoothGattCharacteristic? = null
        var notifyCount = 0

        for (service in g.services) {
            if (service.uuid == GENERIC_ATTRIBUTE) continue
            for (c in service.characteristics) {
                val p = c.properties
                val canWrite = (p and (BluetoothGattCharacteristic.PROPERTY_WRITE or
                        BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE)) != 0
                if (canWrite) {
                    if (firstWritable == null) firstWritable = c
                    if (c.uuid in PREFERRED_WRITE) preferred = c
                }
                val canNotify = (p and BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0
                val canIndicate = (p and BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0
                if (canNotify || canIndicate) {
                    g.setCharacteristicNotification(c, true)
                    val cccd = c.getDescriptor(CCCD)
                    if (cccd != null) {
                        val v = if (canNotify) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                                else BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                        enqueue(Op.Descriptor(cccd, v))
                    }
                    notifyCount++
                }
            }
        }

        writeChar = preferred ?: firstWritable
        isConnected = true
        reconnectAttempt = 0
        everConnected = true
        tryingSaved = false
        saveDevice(g.device)        // 다음에는 선택 없이 바로 연결
        emitState("connected", deviceName(), "")
        val hasNotify = notifyCount > 0
        val hasWrite = writeChar != null
        // 알림 설정이 모두 끝난 뒤 웹 화면에 준비 완료를 알림
        enqueue(Op.Callback { js("window.bleOnReady && window.bleOnReady($hasNotify,$hasWrite)") })
    }

    // =============== 수신 ===============
    private fun onReceive(value: ByteArray) {
        if (value.isEmpty()) return
        val sb = StringBuilder(value.size * 2)
        for (b in value) {
            val v = b.toInt() and 0xFF
            sb.append(HEX[v ushr 4]).append(HEX[v and 0x0F])
        }
        js("window.bleOnData && window.bleOnData('$sb')")
    }

    private val HEX = "0123456789ABCDEF".toCharArray()

    // =============== 송신 (순서대로 하나씩) ===============
    fun write(data: ByteArray): Boolean {
        if (!isConnected || writeChar == null || data.isEmpty()) return false
        main.post {
            var i = 0
            while (i < data.size) {
                enqueue(Op.Write(data.copyOfRange(i, minOf(i + CHUNK, data.size))))
                i += CHUNK
            }
        }
        return true
    }

    private sealed class Op {
        class Write(val data: ByteArray) : Op()
        class Descriptor(val descriptor: BluetoothGattDescriptor, val value: ByteArray) : Op()
        class Callback(val fn: () -> Unit) : Op()
    }

    private val queue = ArrayDeque<Op>()
    private var busy = false
    private val opTimeout = Runnable { opDone() }    // 응답이 안 오면 다음 작업으로 넘어감

    private fun enqueue(op: Op) {
        queue.addLast(op)
        if (!busy) next()
    }

    private fun opDone() {
        main.removeCallbacks(opTimeout)
        busy = false
        next()
    }

    private fun next() {
        if (busy) return
        while (true) {
            val op = queue.removeFirstOrNull() ?: return
            val g = gatt
            when (op) {
                is Op.Callback -> op.fn()
                is Op.Descriptor -> {
                    if (g != null && writeDescriptor(g, op.descriptor, op.value)) {
                        busy = true
                        main.postDelayed(opTimeout, 1500)
                        return
                    }
                }
                is Op.Write -> {
                    val c = writeChar
                    if (g != null && c != null && writeCharacteristic(g, c, op.data)) {
                        busy = true
                        main.postDelayed(opTimeout, 1000)
                        return
                    }
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun writeCharacteristic(g: BluetoothGatt, c: BluetoothGattCharacteristic, data: ByteArray): Boolean {
        val p = c.properties
        val type = if ((p and BluetoothGattCharacteristic.PROPERTY_WRITE) == 0 &&
            (p and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
        ) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(c, data, type) == BluetoothStatusCodes.SUCCESS
        } else {
            c.writeType = type
            c.value = data
            g.writeCharacteristic(c)
        }
    }

    @Suppress("DEPRECATION")
    private fun writeDescriptor(g: BluetoothGatt, d: BluetoothGattDescriptor, value: ByteArray): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(d, value) == BluetoothStatusCodes.SUCCESS
        } else {
            d.value = value
            g.writeDescriptor(d)
        }
    }
}
