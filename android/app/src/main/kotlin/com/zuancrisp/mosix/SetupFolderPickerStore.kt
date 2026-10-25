package com.zuancrisp.mosix

import android.content.SharedPreferences

/** A setup folder result survives process death until Dart saves its draft. */
internal class SetupFolderPickerStore(private val preferences: SharedPreferences) {
    fun begin(forSetup: Boolean) {
        check(preferences.edit().clear().putBoolean("pending", forSetup).commit()) {
            "Could not save folder picker state"
        }
    }

    fun complete(payload: String?): Boolean {
        if (!preferences.getBoolean("pending", false)) return false
        check(preferences.edit().putBoolean("pending", false)
            .putString("result", payload ?: "{}").commit()) {
            "Could not save selected setup folder"
        }
        return true
    }

    fun read(): String? = preferences.getString("result", null)

    fun acknowledge(payload: String) {
        if (read() == payload) preferences.edit().remove("result").commit()
    }
}
