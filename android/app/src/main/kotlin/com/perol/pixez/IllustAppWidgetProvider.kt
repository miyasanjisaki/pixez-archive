package com.perol.pixez

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteException
import android.graphics.Bitmap
import android.net.Uri
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import coil3.imageLoader
import coil3.network.NetworkHeaders
import coil3.network.httpHeaders
import coil3.request.ErrorResult
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.transformations
import coil3.toBitmap
import coil3.transform.RoundedCornersTransformation
import com.perol.pixez.glance.GlanceIllust
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

abstract class IllustAppWidgetProvider(
    private val layout: Int,
    private val contentId: Int
) : AppWidgetProvider() {
    private companion object {
        val scope = MainScope()
        val updates = mutableMapOf<Int, Job>()
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val pending = goAsync()
        val jobs = appWidgetIds.map { id ->
            updates[id]?.cancel()
            scope.launch { updateWidget(context, appWidgetManager, id) }.also { updates[id] = it }
        }
        scope.launch {
            try {
                // Release the broadcast on time even if a slow image is still loading.
                withTimeoutOrNull(8_000L) { jobs.joinAll() }
            } finally {
                pending.finish()
            }
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        for (id in appWidgetIds) {
            updates.remove(id)?.cancel()
            widgetHistory(context, id).edit().clear().apply()
        }
    }

    private suspend fun updateWidget(context: Context, manager: AppWidgetManager, id: Int) {
        val selector = AppWidgetIllustSelector(context, id)
        val illust = try {
            withContext(Dispatchers.IO) { selector.next() }
        } catch (error: SQLiteException) {
            Log.w("IllustAppWidget", "Cannot read illustrations for widget $id", error)
            return
        }

        val views = RemoteViews(context.packageName, layout)
        if (illust == null) {
            views.setViewVisibility(contentId, View.GONE)
            views.setViewVisibility(R.id.appwidget_warning_container, View.VISIBLE)
            views.setViewVisibility(R.id.appwidget_warning_title, View.VISIBLE)
            manager.updateAppWidget(id, views)
            return
        }

        val bitmap = withContext(Dispatchers.IO) { loadBitmap(context, illust.pictureUrl) } ?: return
        views.setImageViewBitmap(R.id.appwidget_image, bitmap)
        views.setViewVisibility(contentId, View.VISIBLE)
        views.setViewVisibility(R.id.appwidget_warning_container, View.GONE)
        val intent = Intent(context, MainActivity::class.java).apply {
            action = "com.perol.pixez.OPEN_WIDGET_ILLUST.${illust.illustId}"
            putExtra("iid", illust.illustId)
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
        }
        val click = PendingIntent.getActivity(context, id, intent, PendingIntent.FLAG_IMMUTABLE)
        views.setOnClickPendingIntent(contentId, click)
        bindDetails(context, views, illust)
        manager.updateAppWidget(id, views)
        selector.markShown(illust.illustId)
    }

    protected open fun bindDetails(context: Context, views: RemoteViews, illust: GlanceIllust) {}

    private suspend fun loadBitmap(context: Context, pictureUrl: String): Bitmap? {
        val host = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.picture_source", null)
        val url = if (host == null) pictureUrl else pictureUrl.replace("i.pximg.net", host)
        val headers = NetworkHeaders.Builder()
            .set("referer", "https://app-api.pixiv.net/")
            .set("User-Agent", "PixivIOSApp/5.8.0")
        Uri.parse(url).host?.let { headers.set("host", it) }
        val radius = 16f * context.resources.displayMetrics.density + 0.5f
        val request = ImageRequest.Builder(context)
            .data(url)
            .httpHeaders(headers.build())
            .transformations(RoundedCornersTransformation(radius))
            .size(540, 540)
            .build()
        return when (val result = context.imageLoader.execute(request)) {
            is SuccessResult -> result.image.toBitmap()
            is ErrorResult -> {
                Log.w("IllustAppWidget", "Cannot load $url", result.throwable)
                null
            }
        }
    }
}
