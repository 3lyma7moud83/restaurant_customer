package com.example.restaurant_customer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
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
                "getStatus" -> result.success(getNotificationStatus())
                "openSettings" -> {
                    openNotificationSettings()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun getNotificationStatus(): Map<String, Any> {
        val sdkInt = Build.VERSION.SDK_INT
        val notificationsEnabled = NotificationManagerCompat.from(this).areNotificationsEnabled()
        val postNotificationsGranted = if (sdkInt >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        val shouldShowPostNotificationsRationale = if (sdkInt >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.shouldShowRequestPermissionRationale(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            )
        } else {
            false
        }

        return hashMapOf(
            "sdkInt" to sdkInt,
            "notificationsEnabled" to notificationsEnabled,
            "postNotificationsGranted" to postNotificationsGranted,
            "shouldShowPostNotificationsRationale" to shouldShowPostNotificationsRationale,
        )
    }

    private fun openNotificationSettings() {
        val intent =
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                putExtra("app_package", packageName)
                putExtra("app_uid", applicationInfo.uid)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        startActivity(intent)
    }
}
