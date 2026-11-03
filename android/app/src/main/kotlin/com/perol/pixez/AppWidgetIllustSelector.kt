package com.perol.pixez

import android.content.Context
import com.perol.pixez.glance.GlanceDBManager
import com.perol.pixez.glance.GlanceIllust

private const val SHARED_PREFERENCES_NAME = "FlutterSharedPreferences"
private const val WIDGET_ILLUST_TYPE_KEY = "flutter.widget_illust_type"
internal const val LAST_SHOWN_ILLUST = "last"
private val supportedWidgetTypes = listOf("recom", "rank", "follow_illust")

internal fun widgetHistory(context: Context, appWidgetId: Int) =
    context.getSharedPreferences("widget_illust_history_$appWidgetId", Context.MODE_PRIVATE)

internal class AppWidgetIllustSelector(private val context: Context, appWidgetId: Int) {
    private val history = widgetHistory(context, appWidgetId)
    private val type = context.getSharedPreferences(SHARED_PREFERENCES_NAME, Context.MODE_PRIVATE)
        .getString(WIDGET_ILLUST_TYPE_KEY, "recom")?.takeIf { it in supportedWidgetTypes } ?: "recom"
    private val seen = history.getStringSet(type, emptySet()).orEmpty()

    fun next(): GlanceIllust? =
        GlanceDBManager().fetch(context, type, seen, history.getLong(LAST_SHOWN_ILLUST, 0L))

    fun markShown(illustId: Long) {
        val id = illustId.toString()
        val round = if (id in seen) setOf(id) else seen + id
        history.edit().putStringSet(type, round).putLong(LAST_SHOWN_ILLUST, illustId).apply()
    }
}
