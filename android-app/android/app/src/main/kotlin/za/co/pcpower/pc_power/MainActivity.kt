package za.co.pcpower.pc_power

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    /** "off" when the widget's Off button opened the app. The app takes it once and asks what to do. */
    private var widgetRequest: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        widgetRequest = intent?.getStringExtra(EXTRA_REQUEST)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(EXTRA_REQUEST)?.let { widgetRequest = it }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pcpower/widget").setMethodCallHandler { call, result ->
            when (call.method) {
                // The app tells the widget when the chosen PC changed, so its label stays right.
                "refresh" -> {
                    WakeWidget.refresh(this)
                    result.success(null)
                }
                "takeRequest" -> {
                    result.success(widgetRequest)
                    widgetRequest = null
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        const val EXTRA_REQUEST = "pcpower_request"
    }
}
