package com.example.nissan_leaf_app

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.io.File
import java.time.LocalDateTime

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

        // Diagnostic instrumentation for issue #3 - the receiver ran when the app
        // manually worked, so the open question is whether/what this fires with
        // no live process. Durable so it survives a drive with no laptop
        // attached: pull with `adb exec-out run-as com.example.nissan_leaf_app
        // cat files/receiver_debug.log`.
        private const val DEBUG_LOG_FILE = "receiver_debug.log"
        private const val DEBUG_NOTIFICATION_CHANNEL = "obd_connection_debug"
        private const val DEBUG_NOTIFICATION_ID = 9001
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != BluetoothDevice.ACTION_ACL_CONNECTED) return

        val device = deviceFrom(intent)
        val name = device?.let(::deviceName)
        val address = device?.address
        val hasPermission = hasBluetoothConnectPermission(context)
        val decision = ObdConnectionPolicy.decide(
            action = intent.action,
            connectAction = BluetoothDevice.ACTION_ACL_CONNECTED,
            hasBluetoothPermission = hasPermission,
            deviceName = name,
            deviceAddress = address,
            savedDeviceId = savedDeviceId(context),
        )

        val startResult = when (decision) {
            ObdAction.START -> {
                if (isServiceRunning(context)) {
                    // Most START connects during a drive are OBDBLE's own
                    // per-cycle disconnect/reconnect (BluetoothDeviceManager
                    // drops the dongle link after every collection cycle by
                    // design - see #13), not a new drive. REBOOT
                    // unconditionally restarts the Dart isolate, so honouring
                    // it here killed an in-flight collection roughly every
                    // minute, all drive long - the receiver_debug.log/
                    // heartbeat correlation that diagnosed "worked once, then
                    // didn't" (#3). The service is already alive and runs its
                    // own timer/self-stop; nothing to do.
                    Log.i(TAG, "recognised device connected but service already running; ignoring")
                    "skipped: already running"
                } else {
                    Log.i(TAG, "recognised device connected; starting foreground service")
                    setServiceStatus(context, FGS_ACTION_REBOOT)
                    val result = startForegroundService(context)
                    notifyTriggered(context, name ?: address ?: "unknown device")
                    result
                }
            }
            ObdAction.IGNORE -> null
        }
        appendDebugLog(context, name, address, hasPermission, decision, startResult)
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

    /**
     * As of Android O, [ActivityManager.getRunningServices] only reports the
     * caller's own services (per its docs) - that's exactly what's needed here
     * and holds on every version this app targets, unlike its use for
     * inspecting other apps' services.
     */
    private fun isServiceRunning(context: Context): Boolean {
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        return activityManager.getRunningServices(Int.MAX_VALUE)
            .any { it.service.className == FGS_SERVICE_CLASS }
    }

    private fun setServiceStatus(context: Context, action: String) {
        // commit(), not apply() - the service reads this in another process
        // immediately after startForegroundService() below.
        context.getSharedPreferences(FGS_STATUS_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(FGS_ACTION_KEY, action)
            .commit()
    }

    /** @return "ok", or "failed: &lt;exception&gt;" for the debug log. */
    private fun startForegroundService(context: Context): String {
        val intent = Intent().setClassName(context.packageName, FGS_SERVICE_CLASS)
        return try {
            ContextCompat.startForegroundService(context, intent)
            "ok"
        } catch (e: Exception) {
            // e.g. ForegroundServiceStartNotAllowedException if the OS denies a
            // background FGS start. Nothing sensible to do here but log/record
            // it; the debug log will show the missed drive.
            Log.e(TAG, "Failed to start foreground service", e)
            "failed: ${e.javaClass.simpleName}: ${e.message}"
        }
    }

    /** Unconditional, durable record of every ACL_CONNECTED this receiver sees. */
    private fun appendDebugLog(
        context: Context,
        deviceName: String?,
        deviceAddress: String?,
        hasPermission: Boolean,
        decision: ObdAction,
        startResult: String?,
    ) {
        try {
            val line = ObdConnectionPolicy.formatDebugLine(
                timestamp = LocalDateTime.now().toString(),
                deviceName = deviceName,
                deviceAddress = deviceAddress,
                hasBluetoothPermission = hasPermission,
                decision = decision,
                startResult = startResult,
            )
            File(context.filesDir, DEBUG_LOG_FILE).appendText("$line\n")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to append receiver debug log", e)
        }
    }

    /**
     * Visible, at-a-glance confirmation for a recognised trigger only (not every
     * device - that would fire for earbuds, a watch, etc.). An ordinary
     * notification, not a foreground-service one, so it has none of the
     * background-start restrictions that startForegroundService above is
     * subject to; it firing is proof the broadcast reached the app at all.
     */
    private fun notifyTriggered(context: Context, deviceLabel: String) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        DEBUG_NOTIFICATION_CHANNEL,
                        "Drive trigger detected",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    )
                )
            }
            val notification = NotificationCompat.Builder(context, DEBUG_NOTIFICATION_CHANNEL)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle("Leaf BT trigger fired")
                .setContentText("$deviceLabel connected; starting drive logging")
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .build()
            manager.notify(DEBUG_NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to post debug notification", e)
        }
    }
}
