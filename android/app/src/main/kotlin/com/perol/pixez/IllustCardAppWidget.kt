package com.perol.pixez

import android.content.Context
import android.graphics.Color
import android.widget.RemoteViews
import androidx.core.widget.RemoteViewsCompat.setImageViewColorFilter
import com.google.android.material.color.MaterialColors
import com.perol.pixez.glance.GlanceIllust

class IllustCardAppWidget : IllustAppWidgetProvider(
    R.layout.illust_app_widget, R.id.appwidget_normal_container
) {
    override fun bindDetails(context: Context, views: RemoteViews, illust: GlanceIllust) {
        views.setTextViewText(R.id.appwidget_title, illust.title)
        views.setTextViewText(R.id.appwidget_subtitle, illust.userName)
        views.setImageViewResource(R.id.appwidget_app_icon, R.mipmap.ic_launcher_foreground)
        views.setImageViewColorFilter(
            R.id.appwidget_app_icon,
            MaterialColors.getColor(context, android.R.attr.colorAccent, Color.BLACK)
        )
    }
}
