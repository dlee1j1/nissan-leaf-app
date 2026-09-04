package com.example.nissan_leaf_app

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Manifest-declared receiver that starts the foreground service when the phone
 * connects to a recognised Bluetooth device on car power-on — the Leaf head unit
 * ("MY LEAF") or the OBD dongle. See issues #3 and #13.
 *
 * Start only. There is no disconnect handler: `BluetoothDeviceManager` drops the
 * dongle link after every collection cycle, so `ACL_DISCONNECTED` is noise. The
 * service stops itself after N failed cycles.
 *
 * This class is only the adapter - it pulls values out of the framework, hands
 * them to [ObdConnectionPolicy.decide], and carries out the result. The decision
 * logic lives in that pure class so it can be unit-tested without Android.
 *
 * Starting the service headless reuses flutter_foreground_task's own restart
 * path: write the service-status pref, then startForegroundService(). That
 * requires the app to have called FlutterForegroundTask.startService() at least
 * once before (done in main.dart) so the notification options and the Dart
 * callback handle are already persisted. The constants below mirror the pinned
 * plugin (flutter_foreground_task 8.17.0); they are strings on purpose to avoid
 * a compile dependency on plugin internals.
 */
class ObdConnectionReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "ObdConnectionReceiver"

        // flutter_foreground_task 8.17.0 internals - see PreferencesKey.kt and
        // models/ForegroundServiceAction.kt in the plugin source.
        private const val FGS_STATUS_PREFS =
            "com.pravera.flutter_foreground_task.prefs.FOREGROUND_SERVICE_STATUS"
        private const val FGS_ACTION_KEY = "foregroundServiceAction"
        private const val FGS_ACTION_REBOOT =
            "com.pravera.flutter_foreground_task.action.reboot"
        private const val FGS_SERVICE_CLASS =
            "com.pravera.flutter_foreground_task.service.ForegroundService"

        // The shared_preferences plugin stores Dart keys in this file, each
        // prefixed with "flutter.". obd_device_id is written by
        // BluetoothDeviceManager when it connects to a dongle.
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val SAVED_DEVICE_ID_KEY = "flutter.obd_device_id"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != BluetoothDevice.ACTION_ACL_CONNECTED) return

        val device = deviceFrom(intent)
        val decision = ObdConnectionPolicy.decide(
            action = intent.action,
            connectAction = BluetoothDevice.ACTION_ACL_CONNECTED,
            hasBluetoothPermission = hasBluetoothConnectPermission(context),
            deviceName = device?.let(::deviceName),
            deviceAddress = device?.address,
            savedDeviceId = savedDeviceId(context),
        )

        when (decision) {
            ObdAction.START -> {
                Log.i(TAG, "recognised device connected; starting foreground service")
                setServiceStatus(context, FGS_ACTION_REBOOT)
                startForegroundService(context)
            }
            ObdAction.IGNORE -> Unit
        }
    }

    private fun deviceFrom(intent: Intent): BluetoothDevice? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }

    private fun deviceName(device: BluetoothDevice): String? =
        try {
            device.name
        } catch (e: SecurityException) {
            null
        }

    private fun savedDeviceId(context: Context): String? =
        context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
            .getString(SAVED_DEVICE_ID_KEY, null)

    private fun hasBluetoothConnectPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return ContextCompat.checkSelfPermission(
            context, Manifest.permission.BLUETOOTH_CONNECT
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun setServiceStatus(context: Context, action: String) {
        // commit(), not apply() - the service reads this in another process
        // immediately after startForegroundService() below.
        context.getSharedPreferences(FGS_STATUS_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(FGS_ACTION_KEY, action)
            .commit()
    }

    private fun startForegroundService(context: Context) {
        val intent = Intent().setClassName(context.packageName, FGS_SERVICE_CLASS)
        try {
            ContextCompat.startForegroundService(context, intent)
        } catch (e: Exception) {
            // e.g. ForegroundServiceStartNotAllowedException if the OS denies a
            // background FGS start. Nothing sensible to do here but log it; the
            // heartbeat log will show the missed drive.
            Log.e(TAG, "Failed to start foreground service", e)
        }
    }
}
