package com.perol.pixez.glance

import android.content.Context
import android.database.sqlite.SQLiteDatabase

private const val ROTATION_POOL_SIZE = 200

data class GlanceIllust(
    val illustId: Long,
    val title: String?,
    val userName: String?,
    val pictureUrl: String
)

class GlanceDBManager {
    fun fetch(context: Context, type: String, seen: Set<String>, lastId: Long): GlanceIllust? {
        val file = context.getDatabasePath("glanceillustpersist.db")
        if (!file.isFile) return null

        return SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            // The table keeps every list ever browsed; rotate through the
            // most recent works so new recommendations actually show up.
            val rows = db.rawQuery(
                "SELECT illust_id, MAX(id) AS last FROM glanceillustpersist WHERE type = ? " +
                    "GROUP BY illust_id ORDER BY last DESC LIMIT $ROTATION_POOL_SIZE",
                arrayOf(type)
            ).use { cursor ->
                buildMap {
                    while (cursor.moveToNext()) put(cursor.getLong(0), cursor.getLong(1))
                }
            }
            val pool = rows.keys.filter { it.toString() !in seen }.ifEmpty { rows.keys.toList() }
            val illustId = pool.filterNot { it == lastId }.randomOrNull() ?: pool.firstOrNull() ?: return null
            db.rawQuery(
                "SELECT title, user_name, picture_url FROM glanceillustpersist WHERE id = ?",
                arrayOf(rows.getValue(illustId).toString())
            ).use { cursor ->
                if (!cursor.moveToFirst()) return null
                GlanceIllust(illustId, cursor.getString(0), cursor.getString(1), cursor.getString(2))
            }
        }
    }
}
