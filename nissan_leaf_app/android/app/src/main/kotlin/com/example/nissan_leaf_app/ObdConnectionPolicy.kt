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
     * Name fragments that identify an OBD dongle - matches BluetoothDeviceManager.
     *
     * The name check is only the *fallback*. The reliable path is the saved MAC
     * (`savedDeviceId`), which BluetoothDeviceManager writes after the first
     * successful in-app connect. Until that happens - i.e. on a fresh install,
     * before the user has ever connected from the app - matching is name-only.
     *
     * So if a dongle advertises some name that isn't "OBD"/"ELM" (cheap clones
     * vary), the very first drive won't auto-start the service; the user has to
     * open the app and connect once, after which the saved MAC takes over. If
     * that turns out to bite with real hardware, add the offending name fragment
     * here (uppercase).
     */
    private val NAME_HINTS = listOf("OBD", "ELM")

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
        if (!isObdDongle(deviceName, deviceAddress, savedDeviceId)) return ObdAction.IGNORE
        return when (action) {
            connectAction -> ObdAction.START
            disconnectAction -> ObdAction.STOP
            else -> ObdAction.IGNORE
        }
    }

    /** True when the device is the saved dongle (by address) or looks like one (by name). */
    fun isObdDongle(name: String?, address: String?, savedDeviceId: String?): Boolean {
        if (savedDeviceId != null && savedDeviceId.equals(address, ignoreCase = true)) {
            return true
        }
        val upper = name?.uppercase() ?: return false
        return NAME_HINTS.any { upper.contains(it) }
    }
}
