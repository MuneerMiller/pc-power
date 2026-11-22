package za.co.pcpower.pc_power

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The app tells the widget when the chosen PC changed, so its label stays right.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pcpower/widget").setMethodCallHandler { call, result ->
            if (call.method == "refresh") {
                WakeWidget.refresh(this)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
