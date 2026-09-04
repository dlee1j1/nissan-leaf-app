package com.example.nissan_leaf_app

/**
 * The decision logic behind [ObdConnectionReceiver], kept free of any `android.*`
 * imports so it can be unit-tested directly. (A JUnit test source set is not set
 * up in this project yet - see issue #3.) The receiver is the dumb adapter: it
 * pulls the values below out of the framework, calls [decide], and acts on the
 * result.
 */
enum class ObdAction { START, STOP, IGNORE }

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
     * Decide what to do with a Bluetooth ACL connect/disconnect broadcast.
     *
     * @param action the received intent action
     * @param connectAction the ACL "connected" action string
     * @param disconnectAction the ACL "disconnected" action string
     * @param hasBluetoothPermission whether BLUETOOTH_CONNECT is granted (needed
     *   to trust the device name; without it, ignore)
     * @param deviceName the device's name, or null if unavailable
     * @param deviceAddress the device's MAC address, or null if unavailable
     * @param savedDeviceId the dongle MAC the app last connected to, or null
     */
    fun decide(
        action: String?,
        connectAction: String,
        disconnectAction: String,
        hasBluetoothPermission: Boolean,
        deviceName: String?,
        deviceAddress: String?,
        savedDeviceId: String?,
    ): ObdAction {
        if (!hasBluetoothPermission) return ObdAction.IGNORE
        if (!isDriveTrigger(deviceName, deviceAddress, savedDeviceId)) return ObdAction.IGNORE
        return when (action) {
            connectAction -> ObdAction.START
            disconnectAction -> ObdAction.STOP
            else -> ObdAction.IGNORE
        }
    }

    /** True when the device is the saved dongle (by address) or a known drive-start name. */
    fun isDriveTrigger(name: String?, address: String?, savedDeviceId: String?): Boolean {
        if (savedDeviceId != null && savedDeviceId.equals(address, ignoreCase = true)) {
            return true
        }
        val upper = name?.uppercase() ?: return false
        return NAME_HINTS.any { upper.contains(it) }
    }
}
