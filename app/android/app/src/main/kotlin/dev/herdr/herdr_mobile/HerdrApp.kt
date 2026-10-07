package dev.herdr.herdr_mobile

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.Service
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.AudioAttributes
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
            // Remove legacy channels to ensure custom sounds and importance take effect
            for (legacy in listOf("blocked", "finished", "blocked_v2", "finished_v2")) {
                nm.deleteNotificationChannel(legacy)
            }

            val audioAttributes = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .build()

            val blockedSound = Uri.parse("${ContentResolver.SCHEME_ANDROID_RESOURCE}://$packageName/${R.raw.herdr_blocked}")
            val doneSound = Uri.parse("${ContentResolver.SCHEME_ANDROID_RESOURCE}://$packageName/${R.raw.herdr_done}")

            val blockedChannel = NotificationChannel(BLOCKED, "Agent needs you", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(blockedSound, audioAttributes)
                enableVibration(true)
            }
            val finishedChannel = NotificationChannel(FINISHED, "Agent finished", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(doneSound, audioAttributes)
                enableVibration(true)
            }

            nm.createNotificationChannels(listOf(
                NotificationChannel(STATUS, "Connection", NotificationManager.IMPORTANCE_MIN),
                blockedChannel,
                finishedChannel,
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
                    call.argument<ByteArray>("icon"),
                )
                "cancel" -> nm.cancel(call.argument<String>("key").hashCode())
                "askPermissions" -> askPermissions()
                "askBattery" -> askBattery()
                "openNotificationSettings" -> openNotificationSettings()
                "isIgnoringBatteryOptimizations" -> return@setMethodCallHandler result.success(isIgnoringBatteryOptimizations())
                // Material You's accent, from the wallpaper (Android 12+).
                "systemColor" -> return@setMethodCallHandler result.success(
                    if (Build.VERSION.SDK_INT >= 31) getColor(android.R.color.system_accent1_500) else null)
            }
            result.success(null)
        }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE, engine)
    }

    /** Shows [status] (title, text) in the ongoing notification, starting the service; null stops it. */
    private fun setStatus(status: Pair<String, String>?) {
        // The same status again still restarts a service the system has stopped.
        if (status == this.status && (status == null || serviceRunning)) return
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

    @Suppress("DEPRECATION")
    fun statusNotification(): Notification = builder(STATUS)
        .setContentTitle(status?.first ?: "Herdr Mobile")
        .setContentText(status?.second)
        .setOngoing(true)
        .setContentIntent(openIntent(STATUS_ID, null, null))
        .addAction(Notification.Action.Builder(0, "Disconnect", PendingIntent.getService(this, 0,
            Intent(this, StatusService::class.java).setAction(DISCONNECT),
            if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)).build())
        .build()

    /** One alert per [key] (machine/pane): a newer one replaces it. Tapping opens that pane. */
    private fun alert(key: String, title: String, text: String, machine: String, pane: String, urgent: Boolean, iconBytes: ByteArray? = null) {
        val id = key.hashCode()
        val b = builder(if (urgent) BLOCKED else FINISHED)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(openIntent(id, machine, pane))
        if (Build.VERSION.SDK_INT >= 21) {
            b.setCategory(Notification.CATEGORY_MESSAGE)
        }
        if (iconBytes != null) {
            val bitmap = BitmapFactory.decodeByteArray(iconBytes, 0, iconBytes.size)
            if (bitmap != null) {
                b.setLargeIcon(bitmap)
                if (Build.VERSION.SDK_INT >= 28) {
                    val user = Person.Builder().setName("User").build()
                    val sender = Person.Builder()
                        .setName(title)
                        .setIcon(Icon.createWithBitmap(bitmap))
                        .build()
                    val messagingStyle = Notification.MessagingStyle(user)
                        .setGroupConversation(false)
                        .addMessage(Notification.MessagingStyle.Message(text, System.currentTimeMillis(), sender))
                    b.setStyle(messagingStyle)
                }
            }
        }
        nm.notify(id, b.build())
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

    /** Opens the system notification settings for this application. */
    fun openNotificationSettings() {
        val target = activity ?: this
        val intent = if (Build.VERSION.SDK_INT >= 26) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            }
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        target.startActivity(intent)
    }

    fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < 23) return true
        return getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(packageName) == true
    }

    companion object {
        const val ENGINE = "main"
        const val STATUS_ID = 1
        const val STATUS = "status"
        const val BLOCKED = "blocked_v3"
        const val FINISHED = "finished_v3"
        const val DISCONNECT = "disconnect"
    }
}

/** Exists only to keep the process, and with it the Dart connection, alive in the background. */
class StatusService : Service() {
    private val app get() = application as HerdrApp

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Disconnecting every machine leaves Dart no status to show, so it stops this service.
        if (intent?.action == HerdrApp.DISCONNECT) {
            app.channel.invokeMethod("disconnect", null)
            return START_STICKY
        }
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
