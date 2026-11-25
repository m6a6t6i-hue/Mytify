package pl.mytify.mytify

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Passwords of network sources, encrypted with a key that never leaves the Android
 * Keystore. Never in the catalog, logs, exports or the UI.
 */
object Secrets {
    private const val ALIAS = "mytify-source-secrets"

    /** Unit tests run without the Android Keystore. */
    @Volatile internal var memory: MutableMap<String, String>? = null

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let {
            return it
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private fun prefs(c: Context) = c.getSharedPreferences("source-secrets", Context.MODE_PRIVATE)

    fun store(c: Context, id: String, secret: String) {
        memory?.let {
            it[id] = secret
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val data = cipher.doFinal(secret.toByteArray(Charsets.UTF_8))
        val value =
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(data, Base64.NO_WRAP)
        check(prefs(c).edit().putString(id, value).commit()) { "Nie można zapisać hasła" }
    }

    fun load(c: Context, id: String): String? {
        memory?.let {
            return it[id]
        }
        val value = prefs(c).getString(id, null) ?: return null
        return runCatching {
                val (iv, data) = value.split(':').map { Base64.decode(it, Base64.NO_WRAP) }
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
                String(cipher.doFinal(data), Charsets.UTF_8)
            }
            .getOrNull()
    }

    fun delete(c: Context, id: String) {
        memory?.let {
            it.remove(id)
            return
        }
        prefs(c).edit().remove(id).apply()
    }
}
