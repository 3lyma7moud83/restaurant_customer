package com.deliverymat3mk.customer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "restaurant_customer/android_notifications",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> result.success(notificationStatus())
                "openSettings" -> result.success(openNotificationSettings())
                else -> result.notImplemented()
            }
        }
    }

    private fun notificationStatus(): Map<String, Any> {
        val sdkInt = Build.VERSION.SDK_INT
        val postNotificationsGranted = sdkInt < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED

        return mapOf(
            "sdkInt" to sdkInt,
            "notificationsEnabled" to NotificationManagerCompat.from(this).areNotificationsEnabled(),
            "postNotificationsGranted" to postNotificationsGranted,
            "shouldShowPostNotificationsRationale" to (
                sdkInt >= Build.VERSION_CODES.TIRAMISU &&
                    shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
                ),
        )
    }

    private fun openNotificationSettings(): Boolean = try {
        startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            },
        )
        true
    } catch (_: Exception) {
        false
    }
}
