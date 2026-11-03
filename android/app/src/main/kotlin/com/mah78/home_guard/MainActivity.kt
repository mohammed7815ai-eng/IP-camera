package com.mah78.home_guard

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity is required for the biometric app lock (local_auth).
class MainActivity : FlutterFragmentActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android drops multicast packets unless an app holds a MulticastLock.
        // The camera finder holds it only while it is searching.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "home_guard/net").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticast" -> {
                    try {
                        if (multicastLock == null) {
                            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            multicastLock = wifi.createMulticastLock("HomeGuardDiscovery").apply { setReferenceCounted(false) }
                        }
                        multicastLock?.acquire()
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "releaseMulticast" -> {
                    try { multicastLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        try { multicastLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        super.onDestroy()
    }
}
