package dev.herdr.herdr_mobile

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs the Flutter engine with the process instead of the activity, so the Dart side keeps its bridge
 * connection, and keeps raising alerts, after the activity is closed. [StatusService] keeps the process
 * alive while Dart reports a status; Dart drives everything here through the "herdr/android" channel.
 */
class HerdrApp : Application() {
    lateinit var channel: MethodChannel
    var activity: Activity? = null
    var askPending = false
    var serviceRunning = false
    private var status: Pair<String, String>? = null
    private var dartReady = false
    private var pendingOpen: Map<String, String>? = null
    private val nm get() = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannels(listOf(
                NotificationChannel(STATUS, "Connection", NotificationManager.IMPORTANCE_MIN),
                NotificationChannel(BLOCKED, "Agent needs you", NotificationManager.IMPORTANCE_HIGH),
                NotificationChannel(FINISHED, "Agent finished", NotificationManager.IMPORTANCE_DEFAULT),
            ))
        }
        val engine = FlutterEngine(this)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "herdr/android")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> { dartReady = true; flushOpen() }
                "status" -> setStatus(call.argument<String>("title")?.let { it to call.argument<String>("text")!! })
                "alert" -> alert(
                    call.argument<String>("key")!!, call.argument<String>("title")!!, call.argument<String>("text")!!,
                    call.argument<String>("machine")!!, call.argument<String>("pane")!!, call.argument<Boolean>("urgent")!!,
                )
                "cancel" -> nm.cancel(call.argument<String>("key").hashCode())
                "askPermissions" -> askPermissions()
            }
            result.success(null)
        }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE, engine)
    }

    /** Shows [status] (title, text) in the ongoing notification, starting the service; null stops it. */
    private fun setStatus(status: Pair<String, String>?) {
        if (status == this.status) return
        this.status = status
        val service = Intent(this, StatusService::class.java)
        if (status == null) {
            stopService(service)
        } else if (serviceRunning) {
            nm.notify(STATUS_ID, statusNotification())
        } else {
            // Not allowed from the background on Android 12+; the next status retries.
            try {
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
            } catch (e: Exception) {
                this.status = null
            }
        }
    }

    fun statusNotification(): Notification = builder(STATUS)
        .setContentTitle(status?.first ?: "Herdr Mobile")
        .setContentText(status?.second)
        .setOngoing(true)
        .setContentIntent(openIntent(STATUS_ID, null, null))
        .build()

    /** One alert per [key] (machine/pane): a newer one replaces it. Tapping opens that pane. */
    private fun alert(key: String, title: String, text: String, machine: String, pane: String, urgent: Boolean) {
        val id = key.hashCode()
        nm.notify(id, builder(if (urgent) BLOCKED else FINISHED)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(openIntent(id, machine, pane))
            .build())
    }

    @Suppress("DEPRECATION")
    private fun builder(channel: String): Notification.Builder =
        (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this)
            .setPriority(if (channel == BLOCKED) Notification.PRIORITY_HIGH else Notification.PRIORITY_DEFAULT))
            .setSmallIcon(R.drawable.ic_notification)

    private fun openIntent(code: Int, machine: String?, pane: String?): PendingIntent {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (machine != null) intent.putExtra("machine", machine).putExtra("pane", pane)
        val immutable = if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        return PendingIntent.getActivity(this, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or immutable)
    }

    /** Hands a tapped alert's pane to Dart, holding it until Dart has started listening. */
    fun open(machine: String, pane: String) {
        pendingOpen = mapOf("machine" to machine, "pane" to pane)
        flushOpen()
    }

    private fun flushOpen() {
        val open = pendingOpen ?: return
        if (!dartReady) return
        pendingOpen = null
        channel.invokeMethod("open", open)
    }

    /** Asks for the notification permission, then (from MainActivity) for leave to run in the background. */
    fun askPermissions() {
        val activity = activity ?: run { askPending = true; return }
        askPending = false
        if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
        } else {
            askBattery()
        }
    }

    /** Without this exemption Doze cuts the bridge connection while the phone sleeps. */
    fun askBattery() {
        if (Build.VERSION.SDK_INT < 23) return
        if (getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(packageName) == true) return
        activity?.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
    }

    companion object {
        const val ENGINE = "main"
        const val STATUS_ID = 1
        const val STATUS = "status"
        const val BLOCKED = "blocked"
        const val FINISHED = "finished"
    }
}

/** Exists only to keep the process, and with it the Dart connection, alive in the background. */
class StatusService : Service() {
    private val app get() = application as HerdrApp

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val notification = app.statusNotification()
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(HerdrApp.STATUS_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            } else {
                startForeground(HerdrApp.STATUS_ID, notification)
            }
            app.serviceRunning = true
        } catch (e: Exception) {
            // A sticky restart from the background can be refused; Dart restarts it from the foreground.
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        app.serviceRunning = false
        super.onDestroy()
    }
}
