package za.co.pcpower.pc_power

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.RemoteViews
import android.widget.Toast
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/**
 * Sends the turn-on (Wake-on-LAN) signal without opening the app, for the home-screen widget and the
 * quick settings tile. It only needs the PC's hardware address, which the app saves for it; it never
 * touches the access key, so it cannot turn a PC off or change anything.
 */
object Wake {
    /** The PC the app marked for the widget: {"name","mac","broadcast","wanHost","wanPort"}. */
    private fun target(context: Context): JSONObject? {
        val raw = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.wake_target", null) ?: return null
        return try { JSONObject(raw) } catch (e: Exception) { null }
    }

    fun targetName(context: Context): String? = target(context)?.optString("name")?.takeIf { it.isNotEmpty() }

    /** Sends the signal. Returns a short message to show the user. Call from a background thread. */
    fun send(context: Context): String {
        val t = target(context) ?: return "Open PC Power and add a PC first"
        val hex = t.optString("mac").filter { it.isLetterOrDigit() }
        if (hex.length != 12) return "PC Power has no address for ${t.optString("name", "this PC")} yet"
        val mac = try { ByteArray(6) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() } } catch (e: Exception) { return "PC Power has no address for this PC yet" }
        val packet = ByteArray(102)
        for (i in 0 until 6) packet[i] = 0xFF.toByte()
        for (i in 0 until 16) System.arraycopy(mac, 0, packet, 6 + i * 6, 6)

        val targets = mutableListOf("255.255.255.255" to 9)
        t.optString("broadcast").takeIf { it.isNotEmpty() }?.let { targets.add(it to 9) }
        t.optString("wanHost").takeIf { it.isNotEmpty() }?.let { targets.add(it to t.optInt("wanPort", 9)) }
        var sent = 0
        try {
            DatagramSocket().use { socket ->
                socket.broadcast = true
                for ((host, port) in targets) {
                    try {
                        val address = InetAddress.getByName(host)
                        repeat(3) { socket.send(DatagramPacket(packet, packet.size, address, port)) }
                        sent++
                    } catch (e: Exception) {
                        // one unreachable destination must not stop the others
                    }
                }
            }
        } catch (e: Exception) {
            return "Could not send the wake signal"
        }
        val name = t.optString("name", "your PC")
        return if (sent > 0) "Wake signal sent to $name" else "Could not send the wake signal"
    }

    fun sendInBackground(context: Context, done: (() -> Unit)? = null) {
        val app = context.applicationContext
        Thread {
            val message = send(app)
            Handler(Looper.getMainLooper()).post {
                Toast.makeText(app, message, Toast.LENGTH_SHORT).show()
                done?.invoke()
            }
        }.start()
    }
}

/** Receives the tap on the widget. */
class WakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Wake.sendInBackground(context) { pending.finish() }
    }
}

/** The home-screen widget: one button that turns the chosen PC on. */
class WakeWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(context))
    }

    companion object {
        fun views(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.wake_widget)
            views.setTextViewText(R.id.wake_label, "Turn on ${Wake.targetName(context) ?: "PC"}")
            val intent = Intent(context, WakeReceiver::class.java)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            views.setOnClickPendingIntent(R.id.wake_root, PendingIntent.getBroadcast(context, 0, intent, flags))
            // Off opens the app, which confirms (and asks for the app lock if it is on) before turning the PC off.
            val off = Intent(context, MainActivity::class.java)
                .putExtra(MainActivity.EXTRA_REQUEST, "off")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            views.setOnClickPendingIntent(R.id.off_button, PendingIntent.getActivity(context, 1, off, flags))
            return views
        }

        /** Called by the app when the chosen PC or its name changes. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, WakeWidget::class.java))
            for (id in ids) manager.updateAppWidget(id, views(context))
        }
    }
}

/** The quick settings tile (swipe down from the top of the screen). */
class WakeTileService : TileService() {
    override fun onStartListening() {
        qsTile?.apply {
            label = "Turn on ${Wake.targetName(this@WakeTileService) ?: "PC"}"
            state = Tile.STATE_INACTIVE
            updateTile()
        }
    }

    override fun onClick() {
        Wake.sendInBackground(this)
    }
}
