package pl.mytify.mytify

import org.json.JSONObject

/** A text field, or null when it is missing, JSON null or empty (optString gives "null" for JSON null). */
fun JSONObject.text(key: String): String? =
    if (!has(key) || isNull(key)) null else optString(key).ifEmpty { null }
