package dev.herdr.herdr_mobile

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/** Shows the engine [HerdrApp] owns, which outlives this activity. */
class MainActivity : FlutterActivity() {
    private val app get() = application as HerdrApp

    override fun provideFlutterEngine(context: Context): FlutterEngine? = FlutterEngineCache.getInstance().get(HerdrApp.ENGINE)

    override fun shouldDestroyEngineWithHost() = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app.activity = this
        open(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        open(intent)
    }

    override fun onResume() {
        super.onResume()
        if (app.askPending || (android.os.Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED)) {
            app.askPermissions()
        }
    }

    override fun onDestroy() {
        if (app.activity === this) app.activity = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        app.askBattery()
    }

    /** A tapped alert carries the machine and pane to open. */
    private fun open(intent: Intent) {
        val machine = intent.getStringExtra("machine") ?: return
        intent.removeExtra("machine")
        app.open(machine, intent.getStringExtra("pane") ?: return)
    }
}
