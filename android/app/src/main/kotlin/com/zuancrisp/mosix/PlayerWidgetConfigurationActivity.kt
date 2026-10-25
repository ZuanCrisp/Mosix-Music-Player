package com.zuancrisp.mosix

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView
import org.json.JSONObject

/** Bottom sheet that styles one player widget, previewing the real widget live. */
class PlayerWidgetConfigurationActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private var theme = "artwork"
    private var showArtist = true
    private var cover: Bitmap? = null
    private lateinit var state: JSONObject
    private lateinit var sheet: View
    private lateinit var preview: FrameLayout
    private val tiles = mutableListOf<Pair<String, LinearLayout>>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        val prefs = PlayerWidgetProvider.preferences(this)
        theme = prefs.getString("theme_$widgetId", "artwork") ?: "artwork"
        showArtist = prefs.getBoolean("artist_$widgetId", true)
        state = PlayerWidgetProvider.state(this)
        cover = PlayerWidgetProvider.cover(this, state)

        setContentView(R.layout.widget_player_configure)
        sheet = findViewById(R.id.config_sheet)
        preview = findViewById(R.id.config_preview)
        val bottomPadding = sheet.paddingBottom
        sheet.setOnApplyWindowInsetsListener { view, insets ->
            val bottom = if (android.os.Build.VERSION.SDK_INT >= 30) {
                insets.getInsets(WindowInsets.Type.systemBars()).bottom
            } else {
                @Suppress("DEPRECATION") insets.systemWindowInsetBottom
            }
            view.setPadding(view.paddingLeft, view.paddingTop, view.paddingRight, bottomPadding + bottom)
            insets
        }
        findViewById<View>(R.id.config_scrim).setOnClickListener { finish() }

        val themes = findViewById<LinearLayout>(R.id.config_themes)
        listOf(
            "artwork" to R.string.player_widget_artwork,
            "light" to R.string.player_widget_light,
            "dark" to R.string.player_widget_dark,
        ).forEachIndexed { index, (key, label) ->
            val tile = themeTile(key, getString(label))
            themes.addView(tile, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                if (index > 0) marginStart = dp(12)
            })
            tiles += key to tile
        }

        val artist = findViewById<Switch>(R.id.config_artist)
        artist.isChecked = showArtist
        artist.setOnCheckedChangeListener { _, checked -> showArtist = checked; refresh() }
        findViewById<View>(R.id.config_artist_row).setOnClickListener { artist.toggle() }

        findViewById<View>(R.id.config_save).setOnClickListener {
            prefs.edit().putString("theme_$widgetId", theme).putBoolean("artist_$widgetId", showArtist).apply()
            PlayerWidgetProvider.update(this, intArrayOf(widgetId))
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
            finish()
        }
        refresh()

        // Emphasized-decelerate entrance, as Material 3 sheets do.
        sheet.alpha = 0f
        sheet.post {
            sheet.translationY = sheet.height.toFloat()
            sheet.alpha = 1f
            sheet.animate().translationY(0f).setDuration(400)
                .setInterpolator(PathInterpolator(0.05f, 0.7f, 0.1f, 1f)).start()
        }
    }

    override fun onDestroy() {
        cover?.recycle()
        cover = null
        super.onDestroy()
    }

    private fun refresh() {
        val width = (resources.displayMetrics.widthPixels / resources.displayMetrics.density).toInt() - 48
        val views = PlayerWidgetProvider.render(this, state, cover, theme, showArtist, width, 148)
        preview.removeAllViews()
        preview.addView(InertFrame(this).apply { addView(views.apply(this@PlayerWidgetConfigurationActivity, this)) })
        for ((key, tile) in tiles) select(tile, key == theme)
    }

    /** A swatch drawn from the theme's real palette, with its label below. */
    private fun themeTile(key: String, label: String): LinearLayout {
        val colors = PlayerWidgetProvider.palette(this, key, PlayerWidgetProvider.seed(state))
        val swatch = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(12), 0, dp(12), 0)
            addView(block(colors.tonal, 28, 28, 8), LinearLayout.LayoutParams(dp(28), dp(28)))
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(block(colors.onContainer, 36, 6, 3), LinearLayout.LayoutParams(dp(36), dp(6)))
                addView(block(colors.primary, 24, 12, 6), LinearLayout.LayoutParams(dp(24), dp(12)).apply { topMargin = dp(6) })
            }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                marginStart = dp(8)
            })
            tag = colors.container
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            isClickable = true
            contentDescription = label
            addView(swatch, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(76)))
            addView(TextView(context).apply {
                text = label
                textSize = 13f
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(8)
            })
            setOnClickListener {
                if (theme != key) { theme = key; refresh() }
            }
        }
    }

    /** Selection morphs the swatch from a rounded square to a rounder, outlined one. */
    private fun select(tile: LinearLayout, selected: Boolean) {
        val swatch = tile.getChildAt(0)
        val accent = getColor(R.color.widgetAccent)
        swatch.background = GradientDrawable().apply {
            setColor(swatch.tag as Int)
            cornerRadius = dp(if (selected) 28 else 16).toFloat()
            setStroke(dp(if (selected) 3 else 1), if (selected) accent else getColor(R.color.widgetTrack))
        }
        (tile.getChildAt(1) as TextView).apply {
            setTextColor(if (selected) accent else getColor(R.color.widgetTextSecondary))
            typeface = Typeface.create("sans-serif-medium", if (selected) Typeface.BOLD else Typeface.NORMAL)
        }
        tile.isSelected = selected
    }

    private fun block(color: Int, width: Int, height: Int, radius: Int) = View(this).apply {
        background = GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(radius).toFloat()
            setSize(dp(width), dp(height))
        }
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    /** The preview shows the real widget but must not trigger its playback intents. */
    private class InertFrame(context: Context) : FrameLayout(context) {
        override fun onInterceptTouchEvent(event: MotionEvent) = true
    }
}
