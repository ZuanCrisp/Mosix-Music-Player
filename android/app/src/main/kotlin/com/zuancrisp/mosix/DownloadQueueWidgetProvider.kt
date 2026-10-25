package com.zuancrisp.mosix

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Home-screen widget showing the active download. Updated only on discrete
 * events (track transition, status change, throttled progress ticks) from
 * DownloadService, never per progress byte, to respect battery discipline.
 * The last pushed state is persisted so launcher-driven refreshes (reboot,
 * resize) render without the service running.
 */
class DownloadQueueWidgetProvider : AppWidgetProvider() {

    override fun onEnabled(context: Context) {
        widgetPreferences(context).edit().putBoolean(KEY_ENABLED, true).apply()
    }

    override fun onDisabled(context: Context) {
        widgetPreferences(context).edit().putBoolean(KEY_ENABLED, false).apply()
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        if (appWidgetIds.isNotEmpty()) {
            widgetPreferences(context).edit().putBoolean(KEY_ENABLED, true).apply()
        }
        render(context, appWidgetManager, appWidgetIds)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        render(context, appWidgetManager, intArrayOf(appWidgetId))
    }

    companion object {
        private const val PREFS = "download_widget_state"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_RUNNING = "running"
        private const val KEY_TITLE = "title"
        private const val KEY_SUBTITLE = "subtitle"
        private const val KEY_PERCENT = "percent" // -1 = indeterminate
        private const val KEY_QUEUED = "queued"

        /** Persists the state and re-renders all widget instances. */
        fun push(
            context: Context,
            running: Boolean,
            title: String = "",
            subtitle: String = "",
            percent: Int = -1,
            queued: Int = 0,
        ) {
            val prefs = widgetPreferences(context)
            // Most users never add the optional launcher widget. Keep the
            // download hot path free of AppWidget IPC and preference writes
            // for those users.
            if (!prefs.getBoolean(KEY_ENABLED, false)) return

            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, DownloadQueueWidgetProvider::class.java)
            )
            if (ids.isEmpty()) {
                prefs.edit().putBoolean(KEY_ENABLED, false).apply()
                return
            }
            prefs.edit()
                .putBoolean(KEY_RUNNING, running)
                .putString(KEY_TITLE, title)
                .putString(KEY_SUBTITLE, subtitle)
                .putInt(KEY_PERCENT, percent)
                .putInt(KEY_QUEUED, queued)
                .apply()
            render(context, manager, ids)
        }

        private fun widgetPreferences(context: Context) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private fun render(
            context: Context,
            manager: AppWidgetManager,
            ids: IntArray,
        ) {
            val prefs = widgetPreferences(context)
            val running = prefs.getBoolean(KEY_RUNNING, false)
            val percent = if (running) prefs.getInt(KEY_PERCENT, -1) else -1
            val queued = if (running) prefs.getInt(KEY_QUEUED, 0) else 0
            val launch = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            for (id in ids) {
                val options = manager.getAppWidgetOptions(id)
                val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 280)
                val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 72)
                val large = height >= 180
                val views = RemoteViews(
                    context.packageName,
                    if (large) R.layout.widget_download_queue_large else R.layout.widget_download_queue,
                )
                val determinate = percent in 0..100

                if (running) {
                    val subtitle = prefs.getString(KEY_SUBTITLE, "").orEmpty()
                    views.setTextViewText(
                        R.id.widget_title,
                        prefs.getString(KEY_TITLE, "").orEmpty()
                            .ifEmpty { context.getString(R.string.download_widget_downloading) }
                    )
                    views.setTextViewText(R.id.widget_subtitle, subtitle)
                    views.setViewVisibility(
                        R.id.widget_subtitle,
                        if (subtitle.isEmpty()) View.GONE else View.VISIBLE,
                    )
                } else {
                    views.setTextViewText(
                        R.id.widget_title,
                        context.getString(if (large) R.string.download_widget_idle_title else R.string.download_widget_name),
                    )
                    views.setTextViewText(R.id.widget_subtitle, context.getString(R.string.download_widget_idle))
                    views.setViewVisibility(R.id.widget_subtitle, View.VISIBLE)
                }
                views.setImageViewResource(
                    R.id.widget_icon,
                    if (running) R.drawable.ic_widget_download else R.drawable.ic_widget_done,
                )
                views.setTextViewText(
                    R.id.widget_percent,
                    context.getString(R.string.download_widget_percent, percent.coerceAtLeast(0)),
                )
                views.setViewVisibility(
                    R.id.widget_percent,
                    if (determinate && (!large || height >= 220)) View.VISIBLE else View.GONE,
                )
                views.setTextViewText(R.id.widget_queue, context.getString(R.string.download_widget_queue, queued))
                views.setViewVisibility(
                    R.id.widget_queue,
                    if (queued > 1 && (large || width >= 260)) View.VISIBLE else View.GONE,
                )

                if (large) {
                    views.setTextViewText(
                        R.id.widget_status,
                        context.getString(
                            if (running) R.string.download_widget_status_active else R.string.download_widget_status_idle
                        ),
                    )
                    views.setViewVisibility(R.id.widget_wave, if (running) View.VISIBLE else View.GONE)
                    if (running) {
                        views.setImageViewBitmap(R.id.widget_wave, wavyBar(context, width - 32, percent))
                    }
                } else {
                    views.setViewVisibility(R.id.widget_icon, if (determinate) View.GONE else View.VISIBLE)
                    if (running) {
                        views.setImageViewBitmap(R.id.widget_ring, wavyRing(context, percent))
                    } else {
                        views.setImageViewResource(R.id.widget_ring, R.drawable.widget_disc_tonal)
                    }
                }
                views.setOnClickPendingIntent(R.id.widget_root, launch)
                manager.updateAppWidget(id, views)
            }
        }

        private fun color(context: Context, id: Int) = context.getColor(id)

        /**
         * Material 3 Expressive linear indicator: a wavy active track, a gap,
         * the flat remaining track and a stop dot. -1 draws an empty track.
         */
        private fun wavyBar(context: Context, widthDp: Int, percent: Int): Bitmap {
            val density = context.resources.displayMetrics.density
            val w = (widthDp.coerceIn(120, 600) * density).toInt()
            val h = (16 * density).toInt()
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val stroke = 4 * density
            val mid = h / 2f
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = stroke
                strokeCap = Paint.Cap.ROUND
            }
            val start = stroke / 2
            val end = w - stroke / 2
            val split = start + (end - start) * percent.coerceIn(0, 100) / 100f
            val gap = 6 * density
            if (percent > 0) {
                val amplitude = 3 * density
                val wavelength = 28 * density
                val path = Path().apply {
                    moveTo(start, mid)
                    var x = start
                    while (x < split) {
                        x = minOf(x + density, split)
                        lineTo(x, mid + amplitude * sin(2 * PI * (x - start) / wavelength).toFloat())
                    }
                }
                paint.color = color(context, R.color.widgetAccent)
                canvas.drawPath(path, paint)
            }
            val trackStart = if (percent > 0) split + gap else start
            if (trackStart < end) {
                paint.color = color(context, R.color.widgetTrack)
                canvas.drawLine(trackStart, mid, end, mid, paint)
                paint.style = Paint.Style.FILL
                paint.color = color(context, R.color.widgetAccent)
                canvas.drawCircle(end, mid, stroke / 2, paint)
            }
            return bitmap
        }

        /** Circular counterpart on a tonal disc; the active arc ripples around it. */
        private fun wavyRing(context: Context, percent: Int): Bitmap {
            val density = context.resources.displayMetrics.density
            val size = (56 * density).toInt()
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val c = size / 2f
            canvas.drawCircle(c, c, c, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = color(context, R.color.widgetAccentContainer)
            })
            val stroke = 3.5f * density
            val radius = c - 6 * density
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = stroke
                strokeCap = Paint.Cap.ROUND
            }
            val sweep = 360f * percent.coerceIn(0, 100) / 100f
            val gap = if (percent in 1..99) 14f else 0f
            val oval = RectF(c - radius, c - radius, c + radius, c + radius)
            if (sweep < 360f) {
                paint.color = color(context, R.color.widgetOnAccentContainer) and 0x00ffffff or (0x33 shl 24)
                canvas.drawArc(oval, -90f + sweep + gap / 2, (360f - sweep - gap).coerceAtLeast(0f), false, paint)
            }
            if (sweep > 0f) {
                val amplitude = 1.2f * density
                val path = Path()
                var angle = 0f
                while (angle <= sweep) {
                    val theta = Math.toRadians((angle - 90f).toDouble())
                    val r = radius + amplitude * sin(angle / 360f * 2 * PI * 10).toFloat()
                    val x = c + r * cos(theta).toFloat()
                    val y = c + r * sin(theta).toFloat()
                    if (angle == 0f) path.moveTo(x, y) else path.lineTo(x, y)
                    angle += 2f
                }
                paint.color = color(context, R.color.widgetAccent)
                canvas.drawPath(path, paint)
            }
            return bitmap
        }
    }
}
