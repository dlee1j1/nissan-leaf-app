package com.example.nissan_leaf_app

/**
 * The decision logic behind [ObdConnectionReceiver], kept free of any `android.*`
 * imports so it can be unit-tested directly. (A JUnit test source set is not set
 * up in this project yet - see issue #5.) The receiver is the dumb adapter: it
 * pulls the values below out of the framework, calls [decide], and acts on the
 * result.
 */
enum class ObdAction {
    /** Cold-start the service: a recognised device connected and it isn't running. */
    START,

    /**
     * A recognised device connected, but the service is already running - most
     * often OBDBLE's own per-cycle disconnect/reconnect (BluetoothDeviceManager
     * drops the dongle link after every collection cycle by design, see #13),
     * not a new drive. `startForegroundService`'s REBOOT action unconditionally
     * restarts the Dart isolate, so honouring this killed an in-flight
     * collection roughly every minute, all drive long - the bug #3 turned out
     * to be. No-op: the service is alive and runs its own timer/self-stop.
     */
    ALREADY_RUNNING,

    /** Not a recognised device, or a precondition (permission) wasn't met. */
    IGNORE,
}

object ObdConnectionPolicy {
    /**
     * Device-name fragments that mean "a drive is starting":
     *
     * - `OBD` / `ELM` — the OBD dongle itself (cheap clones vary). This is only a
     *   *fallback*; the reliable dongle match is the saved MAC (`savedDeviceId`),
     *   which BluetoothDeviceManager writes after the first in-app connect.
     * - `LEAF` — the car's own Bluetooth. The Leaf head unit defaults to
     *   "MY LEAF", and phone<->head-unit is classic Bluetooth, which Android
     *   auto-reconnects on ignition — so this is the match that actually fires
     *   with no app running. Name-only by design: no pairing, no saved MAC, zero
     *   config. The app is Leaf-only, so hardcoding "LEAF" costs no generality; a
     *   renamed head unit just falls back to the dongle match.
     *
     * If real hardware advertises something else, add the fragment here
     * (uppercase).
     */
    private val NAME_HINTS = listOf("OBD", "ELM", "LEAF")

    /**
     * Start the service when a recognised device connects and it isn't already
     * running. Disconnects are *not* a stop signal: `BluetoothDeviceManager`
     * drops the dongle link after every collection cycle by design, so
     * `ACL_DISCONNECTED` is noise. The service stops itself after N failed
     * cycles instead (see BackgroundService, #13).
     *
     * `isServiceRunning` is an explicit parameter, not a check the receiver
     * makes on the side, specifically so this truth table is what gets tested
     * once #5 lands, rather than living as an inline `if` nobody wrote a case
     * for - that gap (an unmodelled precondition, not a wrong answer to a
     * modelled one) is what let the #3 restart-storm bug ship in the first
     * place.
     *
     * @param action the received intent action
     * @param connectAction the ACL "connected" action string
     * @param hasBluetoothPermission whether BLUETOOTH_CONNECT is granted (needed
     *   to trust the device name; without it, ignore)
     * @param deviceName the device's name, or null if unavailable
     * @param deviceAddress the device's MAC address, or null if unavailable
     * @param savedDeviceId the dongle MAC the app last connected to, or null
     * @param isServiceRunning whether the foreground service is currently alive
     *   (from the caller's own process only - see
     *   [ObdConnectionReceiver.isServiceRunning])
     */
    fun decide(
        action: String?,
        connectAction: String,
        hasBluetoothPermission: Boolean,
        deviceName: String?,
        deviceAddress: String?,
        savedDeviceId: String?,
        isServiceRunning: Boolean,
    ): ObdAction {
        if (action != connectAction) return ObdAction.IGNORE
        if (!hasBluetoothPermission) return ObdAction.IGNORE
        if (!isDriveTrigger(deviceName, deviceAddress, savedDeviceId)) return ObdAction.IGNORE
        return if (isServiceRunning) ObdAction.ALREADY_RUNNING else ObdAction.START
    }

    /**
     * True when the device is the saved dongle (by address) or a known
     * drive-start name.
     *
     * Untested assumption: the address match assumes `savedDeviceId` (what
     * `BluetoothDeviceManager` writes to `flutter.obd_device_id`, sourced from
     * flutter_blue_plus's `remoteId.str`) and native `BluetoothDevice.address`
     * are byte-for-byte comparable modulo case - same separators, same
     * digit grouping. Nothing asserts that across the Dart/native boundary; it
     * has held up so far, but a flutter_blue_plus upgrade that changes its
     * address string format would break this match silently. Same category of
     * risk as `NAME_HINTS` below - an assumption about the world, not
     * something a unit test here can verify.
     */
    fun isDriveTrigger(name: String?, address: String?, savedDeviceId: String?): Boolean {
        if (savedDeviceId != null && savedDeviceId.equals(address, ignoreCase = true)) {
            return true
        }
        val upper = name?.uppercase() ?: return false
        return NAME_HINTS.any { upper.contains(it) }
    }

    /**
     * Formats one line of [ObdConnectionReceiver]'s durable debug log. Pure text
     * formatting, no I/O - the receiver does the actual file write. Kept here,
     * next to the decision it describes, so it's testable once #5 sets up a JVM
     * test lane for this file.
     *
     * This log is unconditional - every ACL_CONNECTED the receiver sees gets a
     * line, IGNORE included, so a name/match bug (e.g. "MY LEAF" not actually
     * matching) is visible as `decision=IGNORE` rather than looking identical to
     * "the broadcast never arrived" (see issue #3).
     */
    fun formatDebugLine(
        timestamp: String,
        deviceName: String?,
        deviceAddress: String?,
        hasBluetoothPermission: Boolean,
        decision: ObdAction,
        startResult: String? = null,
    ): String {
        val device = deviceName ?: deviceAddress ?: "unknown"
        val base = "$timestamp connected device=\"$device\" btPermission=$hasBluetoothPermission " +
            "decision=$decision"
        return if (startResult != null) "$base startResult=$startResult" else base
    }
}
