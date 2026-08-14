/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 */

package com.perol.pixez.plugin

import android.content.ContentValues
import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.ArrayDeque
import java.util.Locale
import java.util.UUID

fun Context.save(byteArray: ByteArray, name: String): String? {
    if (true || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        val dirFile = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "pixez")
        if (!dirFile.exists())
            dirFile.mkdirs()
        val targetFile = File(dirFile.absolutePath + "/" + name)
        val parentFile = targetFile.parentFile
        if (parentFile != null && !parentFile.exists())
            parentFile.mkdirs();
        if (!targetFile.exists())
            targetFile.createNewFile()
        else
            targetFile.delete()
        targetFile.outputStream().use {
            it.write(byteArray)
        }
        return targetFile.absolutePath
    }
    val values = ContentValues();
    val displayName = name.split("/").last()
    values.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
    values.put(MediaStore.MediaColumns.MIME_TYPE, MimeTypeMap.getSingleton().getMimeTypeFromExtension(displayName))

    val path = if (name.contains("/")) {
        "${Environment.DIRECTORY_PICTURES}/pixez/${name.split("/").first()}"
    } else {
        "${Environment.DIRECTORY_PICTURES}/pixez"
    }
    values.put(MediaStore.MediaColumns.RELATIVE_PATH, path);
    var uri: Uri? = null
    try {
        uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        contentResolver.openOutputStream(uri!!)?.use {
            it.write(byteArray)
            it.flush()
        }
    } catch (e: Exception) {
        if (uri != null) {
            contentResolver.delete(uri, null, null);
        }
    }
    return null
}

fun Context.exist(name: String): Boolean {
    if (true || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        //what the hell
        val dirFile = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "pixez")
        if (!dirFile.exists())
            dirFile.mkdirs()
        val targetFile = File(dirFile.absolutePath + "/" + name)
        return targetFile.exists()
    }
    val projection = arrayOf(
            MediaStore.Images.Media._ID,
    )
    val path = if (name.contains("/")) {
        "${Environment.DIRECTORY_PICTURES}/pixez/${name.split("/").first()}"
    } else {
        "${Environment.DIRECTORY_PICTURES}/pixez"
    }
    //想不到吧？居然是这样写？
    //咕噜咕噜，这不翻源码写的出来？
    val selection = "${MediaStore.Images.Media.RELATIVE_PATH} LIKE ? AND ${MediaStore.Images.Media.DISPLAY_NAME} = ?"
    val selectionArgs = arrayOf(
            "%${path}%",
            name.split("/").last(),
    )
    val sortOrder = "${MediaStore.Images.Media.DISPLAY_NAME} ASC"
    val query = contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            sortOrder
    )
    query?.use { cursor ->
        while (cursor.moveToNext()) {
            return true
        }
    }
    return false
}

private val savedImageExtensions = setOf("jpg", "jpeg", "png", "webp", "gif", "avif")

private data class FileScanEntry(val file: File, val depth: Int)
private data class DocumentScanEntry(val file: DocumentFile, val depth: Int, val relativePath: String)

enum class SavedImageTokenKind {
    FILE,
    MEDIA_STORE,
    DOCUMENT
}

data class SavedImageTokenEntry(
    val generation: Long,
    val rootKey: String,
    val uri: Uri,
    val kind: SavedImageTokenKind,
    val displayName: String
)

/**
 * Bounded, process-local capabilities for images returned to Dart.
 *
 * A DocumentsProvider document ID is opaque and must not be interpreted as a
 * filesystem path. Dart therefore receives a random token instead of a URI.
 * The token is useful only for the latest scan and the same authorized root.
 */
class SavedImageTokenRegistry {
    private var generation = 0L
    private var currentRootKey: String? = null
    private val entries = LinkedHashMap<String, SavedImageTokenEntry>()

    @Synchronized
    fun begin(rootKey: String): Long {
        generation++
        currentRootKey = rootKey
        entries.clear()
        return generation
    }

    @Synchronized
    fun issue(
        generation: Long,
        rootKey: String,
        uri: Uri,
        kind: SavedImageTokenKind,
        displayName: String
    ): String {
        if (generation != this.generation || rootKey != currentRootKey) {
            throw SavedImageAccessException(
                "SAVED_IMAGE_SCAN_EXPIRED",
                "The saved image scan is no longer current"
            )
        }
        val token = UUID.randomUUID().toString()
        entries[token] = SavedImageTokenEntry(
            generation = generation,
            rootKey = rootKey,
            uri = uri,
            kind = kind,
            displayName = displayName
        )
        return token
    }

    @Synchronized
    fun resolve(token: String, rootKey: String, kind: SavedImageTokenKind): SavedImageTokenEntry {
        val entry = entries[token]
            ?: throw SavedImageAccessException(
                "SAVED_IMAGE_TOKEN_INVALID",
                "The saved image token is invalid or expired"
            )
        if (entry.generation != generation ||
            entry.rootKey != rootKey ||
            currentRootKey != rootKey ||
            entry.kind != kind
        ) {
            throw SavedImageAccessException(
                "SAVED_IMAGE_TOKEN_INVALID",
                "The saved image token does not belong to the current save root"
            )
        }
        return entry
    }
}

class SavedImageAccessException(val errorCode: String, message: String) : RuntimeException(message)

private fun File.isInside(root: File): Boolean {
    val rootPath = root.path
    val candidatePath = path
    return candidatePath == rootPath || candidatePath.startsWith(rootPath + File.separator)
}

fun Context.listSavedFileImages(
    rootDirectory: File,
    maximumCount: Int,
    maximumDepth: Int,
    registry: SavedImageTokenRegistry,
    rootKey: String
): List<Map<String, Any?>> {
    // Dart requests one sentinel entry beyond its 4096 indexing limit so it
    // can report that the save folder was truncated instead of silently
    // presenting a partial scan as complete.
    val limit = maximumCount.coerceIn(1, 4097)
    val depthLimit = maximumDepth.coerceIn(0, 8)
    val root = try {
        rootDirectory.canonicalFile
    } catch (error: Throwable) {
        throw SavedImageAccessException("SAVE_ROOT_INVALID", error.message ?: "Invalid save root")
    }
    if (!root.exists() || !root.isDirectory) {
        throw SavedImageAccessException("SAVE_ROOT_MISSING", "The configured save root is unavailable")
    }

    val result = mutableListOf<Map<String, Any?>>()
    val generation = registry.begin(rootKey)
    val queue = ArrayDeque<FileScanEntry>()
    val visitedDirectories = mutableSetOf<String>()
    queue.addLast(FileScanEntry(root, 0))
    var visitedEntries = 0
    val maximumVisitedEntries = limit * 8 + 128
    while (queue.isNotEmpty() && result.size < limit && visitedEntries < maximumVisitedEntries) {
        val entry = queue.removeFirst()
        val directory = try {
            entry.file.canonicalFile
        } catch (_: Throwable) {
            continue
        }
        if (!directory.isInside(root) || !visitedDirectories.add(directory.path)) continue
        val children = try {
            val listed = directory.listFiles()
                ?: throw SavedImageAccessException(
                    "SAVE_ROOT_UNREADABLE",
                    "The configured save root cannot be read"
                )
            listed.sortedWith(
                compareByDescending<File> { it.lastModified() }
                    .thenBy { it.name.lowercase() }
            )
        } catch (error: SavedImageAccessException) {
            throw error
        } catch (error: Throwable) {
            throw SavedImageAccessException(
                "SAVE_ROOT_UNREADABLE",
                error.message ?: "The configured save root cannot be read"
            )
        }
        for (childValue in children) {
            if (result.size >= limit || visitedEntries >= maximumVisitedEntries) break
            visitedEntries++
            val child = try {
                childValue.canonicalFile
            } catch (_: Throwable) {
                continue
            }
            if (!child.isInside(root)) continue
            if (child.isDirectory) {
                if (entry.depth < depthLimit) {
                    queue.addLast(FileScanEntry(child, entry.depth + 1))
                }
                continue
            }
            if (!child.isFile || child.extension.lowercase() !in savedImageExtensions) continue
            val relativePath = child.path
                .removePrefix(root.path)
                .trimStart(File.separatorChar)
                .replace(File.separatorChar, '/')
            result.add(
                mapOf(
                    "token" to registry.issue(
                        generation,
                        rootKey,
                        Uri.fromFile(child),
                        SavedImageTokenKind.FILE,
                        child.name
                    ),
                    "display_name" to child.name,
                    "relative_path" to relativePath,
                    "byte_length" to child.length()
                )
            )
        }
    }
    return result
}

fun Context.readSavedFileImage(
    rootDirectory: File,
    token: String,
    maximumBytes: Int,
    registry: SavedImageTokenRegistry,
    rootKey: String
): ByteArray? {
    val root = try {
        rootDirectory.canonicalFile
    } catch (error: Throwable) {
        throw SavedImageAccessException(
            "SAVE_ROOT_INVALID",
            error.message ?: "Invalid save root"
        )
    }
    val uri = registry.resolve(token, rootKey, SavedImageTokenKind.FILE).uri
    if (uri.scheme != "file") {
        throw SavedImageAccessException("SAVED_IMAGE_TOKEN_INVALID", "Expected a file token")
    }
    val file = try {
        File(
            uri.path
                ?: throw SavedImageAccessException(
                    "SAVED_IMAGE_TOKEN_INVALID",
                    "Saved image token has no file path"
                )
        ).canonicalFile
    } catch (error: SavedImageAccessException) {
        throw error
    } catch (error: Throwable) {
        throw SavedImageAccessException(
            "SAVED_IMAGE_TOKEN_INVALID",
            error.message ?: "Saved image token has an invalid file path"
        )
    }
    if (!file.isInside(root) ||
        !file.isFile ||
        file.extension.lowercase() !in savedImageExtensions
    ) {
        throw SavedImageAccessException(
            "SAVED_IMAGE_OUTSIDE_ROOT",
            "The saved image is no longer inside the configured save root"
        )
    }
    val limit = maximumBytes.coerceIn(1, 64 * 1024 * 1024)
    if (file.length() <= 0L || file.length() > limit.toLong()) return null
    return try {
        file.inputStream().use { it.readBoundedBytes(limit, file.length()) }
    } catch (error: Throwable) {
        throw SavedImageAccessException(
            "SAVED_IMAGE_READ_FAILED",
            error.message ?: "Unable to read saved image"
        )
    }
}

fun Context.listSavedMediaImages(
    relativeRoot: String,
    maximumCount: Int,
    registry: SavedImageTokenRegistry,
    rootKey: String
): List<Map<String, Any?>> {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        throw SavedImageAccessException(
            "MEDIA_STORE_UNAVAILABLE",
            "MediaStore relative paths require Android 10 or newer"
        )
    }
    val limit = maximumCount.coerceIn(1, 4097)
    val generation = registry.begin(rootKey)
    val queryRoot = relativeRoot.replace('\\', '/').trim('/')
    val normalizedRoot = normalizeRelativeRoot(queryRoot)
    val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    val projection = arrayOf(
        MediaStore.Images.Media._ID,
        MediaStore.Images.Media.DISPLAY_NAME,
        MediaStore.Images.Media.RELATIVE_PATH,
        MediaStore.Images.Media.SIZE
    )
    val selection = "${MediaStore.Images.Media.RELATIVE_PATH} LIKE ?"
    val selectionArgs = arrayOf("$queryRoot/%")
    val sortOrder = "${MediaStore.Images.Media.DATE_MODIFIED} DESC, ${MediaStore.Images.Media._ID} DESC"
    val cursor = try {
        contentResolver.query(collection, projection, selection, selectionArgs, sortOrder)
            ?: throw SavedImageAccessException(
                "MEDIA_STORE_QUERY_FAILED",
                "MediaStore did not return a cursor"
            )
    } catch (error: SavedImageAccessException) {
        throw error
    } catch (error: SecurityException) {
        throw SavedImageAccessException(
            "MEDIA_READ_PERMISSION_REQUIRED",
            error.message ?: "Media permission is required"
        )
    } catch (error: Throwable) {
        throw SavedImageAccessException(
            "MEDIA_STORE_QUERY_FAILED",
            error.message ?: "Unable to query saved images"
        )
    }

    val result = mutableListOf<Map<String, Any?>>()
    cursor.use {
        val idColumn = it.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
        val nameColumn = it.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
        val relativePathColumn = it.getColumnIndexOrThrow(MediaStore.Images.Media.RELATIVE_PATH)
        val sizeColumn = it.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
        while (it.moveToNext() && result.size < limit) {
            val displayName = it.getString(nameColumn) ?: continue
            if (displayName.substringAfterLast('.', "").lowercase() !in savedImageExtensions) continue
            val relativePath = it.getString(relativePathColumn) ?: continue
            if (!isInsideRelativeRoot(relativePath, normalizedRoot)) continue
            val uri = ContentUris.withAppendedId(collection, it.getLong(idColumn))
            val size = if (it.isNull(sizeColumn)) null else it.getLong(sizeColumn).takeIf { value -> value > 0 }
            result.add(
                mapOf(
                    "token" to registry.issue(
                        generation,
                        rootKey,
                        uri,
                        SavedImageTokenKind.MEDIA_STORE,
                        displayName
                    ),
                    "display_name" to displayName,
                    "relative_path" to relativePathUnderRoot(relativePath, normalizedRoot),
                    "byte_length" to size
                )
            )
        }
    }
    return result
}

fun Context.readSavedMediaImage(
    relativeRoot: String,
    token: String,
    maximumBytes: Int,
    registry: SavedImageTokenRegistry,
    rootKey: String
): ByteArray? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        throw SavedImageAccessException("MEDIA_STORE_UNAVAILABLE", "MediaStore is unavailable")
    }
    val entry = registry.resolve(token, rootKey, SavedImageTokenKind.MEDIA_STORE)
    val normalizedRoot = normalizeRelativeRoot(relativeRoot)
    val projection = arrayOf(
        MediaStore.Images.Media.DISPLAY_NAME,
        MediaStore.Images.Media.RELATIVE_PATH,
        MediaStore.Images.Media.SIZE
    )
    val cursor = try {
        contentResolver.query(entry.uri, projection, null, null, null)
            ?: throw SavedImageAccessException(
                "SAVED_IMAGE_READ_FAILED",
                "MediaStore image is unavailable"
            )
    } catch (error: SavedImageAccessException) {
        throw error
    } catch (error: SecurityException) {
        throw SavedImageAccessException(
            "MEDIA_READ_PERMISSION_REQUIRED",
            error.message ?: "Media permission is required"
        )
    }
    cursor.use {
        if (!it.moveToFirst()) {
            throw SavedImageAccessException("SAVED_IMAGE_MISSING", "Saved image no longer exists")
        }
        val displayName = it.getString(
            it.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
        ) ?: throw SavedImageAccessException("SAVED_IMAGE_READ_FAILED", "Saved image has no name")
        val relativePath = it.getString(
            it.getColumnIndexOrThrow(MediaStore.Images.Media.RELATIVE_PATH)
        ) ?: throw SavedImageAccessException("SAVED_IMAGE_OUTSIDE_ROOT", "Saved image has no relative path")
        if (displayName != entry.displayName ||
            !isInsideRelativeRoot(relativePath, normalizedRoot) ||
            displayName.substringAfterLast('.', "").lowercase() !in savedImageExtensions
        ) {
            throw SavedImageAccessException(
                "SAVED_IMAGE_OUTSIDE_ROOT",
                "Saved image is no longer inside the configured save root"
            )
        }
        val sizeColumn = it.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
        val limit = maximumBytes.coerceIn(1, 64 * 1024 * 1024)
        if (!it.isNull(sizeColumn)) {
            val length = it.getLong(sizeColumn)
            if (length <= 0L || length > limit.toLong()) return null
        }
        return readBoundedContentUri(entry.uri, limit)
    }
}

fun Context.listSavedDocumentImages(
    root: DocumentFile,
    maximumCount: Int,
    maximumDepth: Int,
    registry: SavedImageTokenRegistry,
    rootKey: String
): List<Map<String, Any?>> {
    val limit = maximumCount.coerceIn(1, 4097)
    val depthLimit = maximumDepth.coerceIn(0, 8)
    if (!root.exists() || !root.isDirectory) {
        throw SavedImageAccessException("SAF_ROOT_INVALID", "The authorized SAF root is unavailable")
    }

    val result = mutableListOf<Map<String, Any?>>()
    val generation = registry.begin(rootKey)
    val queue = ArrayDeque<DocumentScanEntry>()
    val visited = mutableSetOf<String>()
    queue.addLast(DocumentScanEntry(root, 0, ""))
    var visitedEntries = 0
    val maximumVisitedEntries = limit * 8 + 128
    while (queue.isNotEmpty() && result.size < limit && visitedEntries < maximumVisitedEntries) {
        val entry = queue.removeFirst()
        if (!visited.add(entry.file.uri.toString())) continue
        val children = try {
            entry.file.listFiles().sortedWith(
                compareByDescending<DocumentFile> { it.lastModified() }
                    .thenBy { (it.name ?: "").lowercase() }
            )
        } catch (error: Throwable) {
            throw SavedImageAccessException(
                "SAF_SCAN_FAILED",
                error.message ?: "Unable to read the authorized SAF root"
            )
        }
        for (child in children) {
            if (result.size >= limit || visitedEntries >= maximumVisitedEntries) break
            visitedEntries++
            val name = child.name ?: continue
            val relativePath = if (entry.relativePath.isEmpty()) {
                name
            } else {
                "${entry.relativePath}/$name"
            }
            if (child.isDirectory) {
                if (entry.depth < depthLimit) {
                    queue.addLast(DocumentScanEntry(child, entry.depth + 1, relativePath))
                }
                continue
            }
            if (!child.isFile || name.substringAfterLast('.', "").lowercase() !in savedImageExtensions) continue
            result.add(
                mapOf(
                    "token" to registry.issue(
                        generation,
                        rootKey,
                        child.uri,
                        SavedImageTokenKind.DOCUMENT,
                        name
                    ),
                    "display_name" to name,
                    "relative_path" to relativePath,
                    "byte_length" to child.length().takeIf { it > 0 }
                )
            )
        }
    }
    return result
}

fun Context.readSavedDocumentImage(
    token: String,
    maximumBytes: Int,
    registry: SavedImageTokenRegistry,
    rootKey: String
): ByteArray? {
    val entry = registry.resolve(token, rootKey, SavedImageTokenKind.DOCUMENT)
    val uri = entry.uri
    if (uri.scheme != "content" || !DocumentsContract.isDocumentUri(this, uri)) {
        throw SavedImageAccessException("SAVED_IMAGE_TOKEN_INVALID", "Expected a SAF document token")
    }
    val document = DocumentFile.fromSingleUri(this, uri)
        ?: throw SavedImageAccessException("SAVED_IMAGE_MISSING", "SAF document no longer exists")
    val documentName = document.name
        ?: throw SavedImageAccessException("SAVED_IMAGE_READ_FAILED", "SAF document has no name")
    if (documentName != entry.displayName ||
        !document.isFile ||
        documentName.substringAfterLast('.', "").lowercase() !in savedImageExtensions
    ) {
        throw SavedImageAccessException("SAVED_IMAGE_READ_FAILED", "SAF document is not a supported image")
    }

    val limit = maximumBytes.coerceIn(1, 64 * 1024 * 1024)
    return readBoundedContentUri(uri, limit)
}

private fun Context.readBoundedContentUri(uri: Uri, limit: Int): ByteArray? {
    return try {
        contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
            if (descriptor.length > limit.toLong()) return null
        }
        contentResolver.openInputStream(uri)?.use { it.readBoundedBytes(limit) }
            ?: throw SavedImageAccessException(
                "SAVED_IMAGE_READ_FAILED",
                "Unable to open saved image"
            )
    } catch (error: SavedImageAccessException) {
        throw error
    } catch (error: SecurityException) {
        throw SavedImageAccessException(
            "SAVED_IMAGE_PERMISSION_REVOKED",
            error.message ?: "Saved image permission was revoked"
        )
    } catch (error: Throwable) {
        throw SavedImageAccessException(
            "SAVED_IMAGE_READ_FAILED",
            error.message ?: "Unable to read saved image"
        )
    }
}

private fun normalizeRelativeRoot(value: String): String = value
    .replace('\\', '/')
    .trim('/')
    .lowercase(Locale.ROOT)

private fun isInsideRelativeRoot(relativePath: String, normalizedRoot: String): Boolean {
    val candidate = relativePath.replace('\\', '/').trim('/').lowercase(Locale.ROOT)
    return candidate == normalizedRoot || candidate.startsWith("$normalizedRoot/")
}

private fun relativePathUnderRoot(relativePath: String, normalizedRoot: String): String {
    val candidate = relativePath.replace('\\', '/').trim('/')
    val normalizedCandidate = candidate.lowercase(Locale.ROOT)
    return if (normalizedCandidate == normalizedRoot) {
        ""
    } else {
        candidate.substring(normalizedRoot.length + 1)
    }
}

private fun InputStream.readBoundedBytes(maximumBytes: Int, declaredLength: Long = -1): ByteArray? {
    val initialCapacity = when {
        declaredLength in 1L..maximumBytes.toLong() -> declaredLength.toInt()
        else -> minOf(maximumBytes, 1024 * 1024)
    }
    val output = ByteArrayOutputStream(initialCapacity)
    val buffer = ByteArray(64 * 1024)
    var total = 0
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        total += count
        if (total > maximumBytes) return null
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}
