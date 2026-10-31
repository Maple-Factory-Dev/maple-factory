package dev.maplefactory.kit

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Each saved factory's token, one per factory key (host:port), in EncryptedSharedPreferences: the
 * values are AES-256-GCM encrypted under a master key the Android Keystore holds.
 */
class TokenStore(private val prefs: SharedPreferences) {
    fun read(factory: String): String? = prefs.getString(SavedFactory.key(factory), null)

    fun write(factory: String, token: String) {
        prefs.edit().putString(SavedFactory.key(factory), token).apply()
    }

    fun delete(factory: String) {
        prefs.edit().remove(SavedFactory.key(factory)).apply()
    }

    companion object {
        fun open(context: Context): TokenStore {
            val key = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            val prefs = EncryptedSharedPreferences.create(
                context, "factory_tokens", key,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
            return TokenStore(prefs)
        }
    }
}
