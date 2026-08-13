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

package com.perol.pixez

import android.Manifest
import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.view.Surface
import android.view.SurfaceHolder
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.lifecycleScope
import com.perol.pixez.plugin.CustomTab
import com.perol.pixez.plugin.DeepLinkPlugin
import com.perol.pixez.plugin.JsEvalPlugin
import com.perol.pixez.plugin.OpenSettinger
import com.perol.pixez.plugin.Safer
import com.perol.pixez.plugin.SecurePlugin
import com.perol.pixez.plugin.SupporterPlugin
import com.perol.pixez.plugin.Weiss
import com.perol.pixez.plugin.exist
import com.perol.pixez.plugin.save
import com.waynejo.androidndkgif.GifEncoder
import io.flutter.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.*

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.perol.dev/save"
    private val ENCODE_CHANNEL = "samples.flutter.dev/battery"
    private val APP_WIDGET_CHANNEL = "com.perol.dev/app_widget"
    private val DISPLAY_MODE_CHANNEL = "com.perol.dev/display_mode"
    private val DISPLAY_MODE_TAG = "PixEzRefreshRate"
    private var saveMode = 0
    private val OPEN_DOCUMENT_TREE_CODE = 190
    private val PICK_IMAGE_FILE = 2
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private var helplessPath: String? = null
    private val SHARED_PREFERENCES_NAME = "FlutterSharedPreferences"
    private lateinit var sharedPreferences: SharedPreferences
    private var requestedRefreshRate = 0f
    private var requestedDisplayModeId = 0
    private var flutterSurfaceView: FlutterSurfaceView? = null
    private var flutterSurfaceHooked = false
    private var surfaceFrameRateHintSubmitted = false
    private var lastRefreshRateReason = "not-requested"
    private var lastSurfaceFrameRateError: String? = null
    private val flutterSurfaceCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
            submitAutomaticSurfaceFrameRateHint("surface-created", holder.surface)
        }

        override fun surfaceChanged(
            holder: SurfaceHolder,
            format: Int,
            width: Int,
            height: Int
        ) {
            submitAutomaticSurfaceFrameRateHint("surface-changed", holder.surface)
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            surfaceFrameRateHintSubmitted = false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { splashScreenView -> splashScreenView.remove() }
        }
        super.onCreate(savedInstanceState)
    }

    override fun onResume() {
        super.onResume()
        reassertWindowRefreshRatePreference("activity-resume")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            reassertWindowRefreshRatePreference("window-focus")
        }
    }

    override fun onFlutterSurfaceViewCreated(surfaceView: FlutterSurfaceView) {
        super.onFlutterSurfaceViewCreated(surfaceView)
        flutterSurfaceView?.holder?.removeCallback(flutterSurfaceCallback)
        flutterSurfaceView = surfaceView
        flutterSurfaceHooked = true
        surfaceView.holder.addCallback(flutterSurfaceCallback)
        submitAutomaticSurfaceFrameRateHint(
            "flutter-surface-hooked",
            surfaceView.holder.surface
        )
    }

    private val savingPools = Collections.synchronizedList(arrayListOf<String>())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(DeepLinkPlugin())
        sharedPreferences =
            this.getSharedPreferences(SHARED_PREFERENCES_NAME, Context.MODE_PRIVATE)
        helplessPath = sharedPreferences.getString("flutter.store_path", null)
        saveMode = sharedPreferences.getLong("flutter.save_mode", 0).toInt()
        OpenSettinger.bindChannel(flutterEngine, this)
        Weiss.bindChannel(flutterEngine)
        CustomTab.bindChannel(this, flutterEngine)
        Safer.bindChannel(this, flutterEngine)
        JsEvalPlugin(this).bindChannel(flutterEngine)
        SecurePlugin(this).bindChannel(flutterEngine)
        SupporterPlugin().bindChannel(this, flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DISPLAY_MODE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "applyRefreshRate" -> {
                    requestedRefreshRate =
                        (call.argument<Number>("refreshRate")?.toFloat() ?: 0f)
                            .coerceAtLeast(0f)
                    requestedDisplayModeId =
                        (call.argument<Number>("preferredModeId")?.toInt() ?: 0)
                            .coerceAtLeast(0)
                    result.success(applyRefreshRatePreference("dart-request"))
                }

                "getRefreshRateDiagnostics" ->
                    result.success(refreshRateDiagnostics("dart-query"))

                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        result.success(true)
                    }
                }

                "permissionStatus" -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        if (BuildConfig.IS_GOOGLEPLAY) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        val checkSelfPermission = ContextCompat.checkSelfPermission(
                            this,
                            Manifest.permission.READ_MEDIA_IMAGES
                        )
                        result.success(checkSelfPermission == PackageManager.PERMISSION_GRANTED)
                    }
                }

                "save" -> {
                    val data = call.argument<ByteArray>("data")
                    val name = call.argument<String>("name")
                    if (data == null || name == null) {
                        result.error("INVALID_ARGS", "data and name are required", null)
                        return@setMethodCallHandler
                    }
                    var clearOld = call.argument<Boolean>("clear_old")
                    saveMode = call.argument<Int>("save_mode") ?: 0
                    if (clearOld == null)
                        clearOld = false
                    if (savingPools.contains(name)) {
                        result.error("SAVE_IN_PROGRESS", "A save with the same name is already running", null)
                        return@setMethodCallHandler
                    }
                    savingPools.add(name)
                    lifecycleScope.launch {
                        try {
                            var saved = false
                            when (saveMode) {
                                0 -> {
                                    val path = withContext(Dispatchers.IO) {
                                        save(data, name)
                                    }
                                    if (path != null) {
                                        saved = true
                                        MediaScannerConnection.scanFile(
                                            this@MainActivity,
                                            arrayOf(path),
                                            arrayOf(
                                                MimeTypeMap.getSingleton()
                                                    .getMimeTypeFromExtension(File(path).extension)
                                            )
                                        ) { _, _ ->
                                        }
                                    }
                                }

                                2 -> {
                                    if (helplessPath == null) {
                                        helplessPath =
                                            sharedPreferences.getString("flutter.store_path", null)
                                        if (helplessPath == null) {
                                            helplessPath = "/storage/emulated/0/Pictures/pixez"
                                        }
                                    }
                                    val fullPath = "$helplessPath/$name"
                                    val file = File(fullPath)
                                    withContext(Dispatchers.IO) {
                                        val dirPath = file.parent
                                        val dirFile = File(dirPath)
                                        if (!dirFile.exists()) {
                                            dirFile.mkdirs()
                                        }
                                        if (!file.exists()) {
                                            file.createNewFile()
                                        }
                                        file.outputStream().write(data)
                                        if (clearOld && name.contains("_p0")) {
                                            val oldFileName = name.replace("_p0", "")
                                            val oldFile = File("$helplessPath", oldFileName)
                                            if (oldFile.exists()) {
                                                oldFile.delete()
                                            }
                                        }
                                    }
                                    MediaScannerConnection.scanFile(
                                        this@MainActivity,
                                        arrayOf(file.path),
                                        arrayOf(
                                            MimeTypeMap.getSingleton()
                                                .getMimeTypeFromExtension(File(file.path).extension)
                                        )
                                    ) { _, _ ->
                                    }

                                    saved = true
                                }

                                1 -> {
                                    withContext(Dispatchers.IO) {
                                        val uri = writeFileUri(name, clearOld)
                                        if (uri != null) {
                                            wr(data, uri)
                                            saved = true
                                        }
                                    }
                                }
                            }
                            result.success(saved)
                        } catch (e: Throwable) {
                            Log.d("Save", "${e.message}")
                            result.success(false)
                        } finally {
                            savingPools.remove(name)
                        }
                    }
                }

                "saveFromPath" -> {
                    val sourcePath = call.argument<String>("source_path")
                    val name = call.argument<String>("name")
                    if (sourcePath == null || name == null) {
                        result.error("INVALID_ARGS", "source_path and name are required", null)
                        return@setMethodCallHandler
                    }
                    var clearOld = call.argument<Boolean>("clear_old")
                    saveMode = call.argument<Int>("save_mode") ?: 0
                    if (clearOld == null)
                        clearOld = false
                    if (savingPools.contains(name)) {
                        result.error("SAVE_IN_PROGRESS", "A save with the same name is already running", null)
                        return@setMethodCallHandler
                    }
                    savingPools.add(name)
                    lifecycleScope.launch {
                        try {
                            val sourceFile = File(sourcePath)
                            var saved = false
                            when (saveMode) {
                                0 -> {
                                    val data = withContext(Dispatchers.IO) {
                                        sourceFile.readBytes()
                                    }
                                    val path = save(data, name)
                                    if (path != null) {
                                        saved = true
                                        MediaScannerConnection.scanFile(
                                            this@MainActivity,
                                            arrayOf(path),
                                            arrayOf(
                                                MimeTypeMap.getSingleton()
                                                    .getMimeTypeFromExtension(File(path).extension)
                                            )
                                        ) { _, _ ->
                                        }
                                    }
                                }

                                2 -> {
                                    val target = File("$helplessPath/$name")
                                    withContext(Dispatchers.IO) {
                                        val dirPath = target.parent
                                        val dirFile = File(dirPath)
                                        if (!dirFile.exists()) {
                                            dirFile.mkdirs()
                                        }
                                        sourceFile.copyTo(target, overwrite = true)
                                    }
                                    saved = true
                                    MediaScannerConnection.scanFile(
                                        this@MainActivity,
                                        arrayOf(target.path),
                                        arrayOf(
                                            MimeTypeMap.getSingleton()
                                                .getMimeTypeFromExtension(target.extension)
                                        )
                                    ) { _, _ ->
                                    }
                                }

                                1 -> {
                                    withContext(Dispatchers.IO) {
                                        val uri = writeFileUri(name, clearOld)
                                        if (uri != null) {
                                            val data = sourceFile.readBytes()
                                            wr(data, uri)
                                            saved = true
                                        }
                                    }
                                }
                            }
                            sourceFile.delete()
                            result.success(saved)
                        } catch (e: Throwable) {
                            Log.d("SaveFromPath", "${e.message}")
                            result.success(false)
                        } finally {
                            savingPools.remove(name)
                        }
                    }
                }

                "get_path" -> {
                    saveMode = call.argument<Int>("save_mode") ?: 0
                    lifecycleScope.launch {
                        val path = withContext(Dispatchers.IO) {
                            getPath()
                        }
                        result.success(path)
                    }
                }

                "exist" -> {
                    val name = call.argument<String>("name")!!
                    saveMode = call.argument<Int>("save_mode") ?: 0
                    lifecycleScope.launch {
                        val isFileExist = withContext(Dispatchers.IO) {
                            try {
                                return@withContext isFileExist(name)
                            } catch (e: Throwable) {
                            }
                        }
                        result.success(isFileExist)
                    }
                }

                "choice_folder" -> {
                    saveMode = call.argument<Int>("save_mode") ?: 0
                    choiceFolder()
                    pendingPickResult = result
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ENCODE_CHANNEL
        ).setMethodCallHandler { call, result ->
            if (call.method == "getBatteryLevel") {
                val path = call.argument<String>("path")!!
                val delay = call.argument<Int>("delay")!!
                val delayArray = call.argument<List<Int>>("delay_array")!!
                lifecycleScope.launch {
                    val gifPath = withContext(Dispatchers.IO) {
                        encodeGif(path, delay, delayArray)
                    }
                    if (gifPath != null) {
                        result.success(gifPath)
                    } else {
                        result.error("ENCODE_FAILED", "GIF encoding failed", null)
                    }
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_WIDGET_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setRecommendType" -> {
                    val type = call.argument<String>("type") ?: "recom"
                    sharedPreferences.edit().putString("flutter.widget_illust_type", type).apply()
                    refreshAppWidgets()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        flutterSurfaceView?.holder?.removeCallback(flutterSurfaceCallback)
        flutterSurfaceView = null
        flutterSurfaceHooked = false
        super.cleanUpFlutterEngine(flutterEngine)
    }

    @Suppress("DEPRECATION")
    private fun currentDisplay() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            windowManager.defaultDisplay
        }

    private fun applyRefreshRatePreference(reason: String): Map<String, Any?> {
        lastRefreshRateReason = reason
        surfaceFrameRateHintSubmitted = false
        lastSurfaceFrameRateError = null

        if (requestedRefreshRate > 0f) {
            val attributes = window.attributes
            if (requestedDisplayModeId > 0) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    attributes.preferredDisplayModeId = requestedDisplayModeId
                }
                attributes.preferredRefreshRate = 0f
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Android 11+ recommends Surface.setFrameRate for render surfaces.
                // Clear Window mode/rate overrides so they cannot supersede the
                // Flutter surface compatibility hint.
                attributes.preferredDisplayModeId = 0
                attributes.preferredRefreshRate = 0f
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    attributes.preferredDisplayModeId = 0
                }
                attributes.preferredRefreshRate = requestedRefreshRate
            }
            window.attributes = attributes

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                if (requestedDisplayModeId == 0) {
                    submitAutomaticSurfaceFrameRateHint(
                        reason,
                        flutterSurfaceView?.holder?.surface
                    )
                } else {
                    clearAutomaticSurfaceFrameRateHint(
                        "explicit-mode-selected",
                        flutterSurfaceView?.holder?.surface
                    )
                }
            }
        }

        val diagnostics = refreshRateDiagnostics(reason)
        Log.i(DISPLAY_MODE_TAG, diagnostics.toString())
        return diagnostics
    }

    private fun reassertWindowRefreshRatePreference(reason: String) {
        if (requestedRefreshRate <= 0f) return
        lastRefreshRateReason = reason
        val attributes = window.attributes
        if (requestedDisplayModeId > 0) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                attributes.preferredDisplayModeId = requestedDisplayModeId
            }
            attributes.preferredRefreshRate = 0f
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            attributes.preferredDisplayModeId = 0
            attributes.preferredRefreshRate = 0f
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                attributes.preferredDisplayModeId = 0
            }
            attributes.preferredRefreshRate = requestedRefreshRate
        }
        window.attributes = attributes
        Log.i(DISPLAY_MODE_TAG, refreshRateDiagnostics(reason).toString())
    }

    private fun submitAutomaticSurfaceFrameRateHint(reason: String, surface: Surface?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
            requestedDisplayModeId != 0 ||
            requestedRefreshRate <= 0f
        ) {
            return
        }
        lastRefreshRateReason = reason
        if (surface?.isValid != true) {
            surfaceFrameRateHintSubmitted = false
            lastSurfaceFrameRateError = "Flutter surface unavailable or invalid"
            return
        }
        try {
            surface.setFrameRate(
                requestedRefreshRate,
                Surface.FRAME_RATE_COMPATIBILITY_DEFAULT
            )
            // A successful call means Android accepted the compatibility hint;
            // the compositor may still choose another active refresh rate.
            surfaceFrameRateHintSubmitted = true
            lastSurfaceFrameRateError = null
        } catch (error: Throwable) {
            surfaceFrameRateHintSubmitted = false
            lastSurfaceFrameRateError =
                "${error.javaClass.simpleName}: ${error.message.orEmpty()}"
        }
        Log.i(DISPLAY_MODE_TAG, refreshRateDiagnostics(reason).toString())
    }

    private fun clearAutomaticSurfaceFrameRateHint(reason: String, surface: Surface?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        lastRefreshRateReason = reason
        if (surface?.isValid != true) {
            surfaceFrameRateHintSubmitted = false
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                surface.clearFrameRate()
            } else {
                // clearFrameRate() was added in API 34. Passing 0 on Android
                // 11-13 clears the earlier Surface frame-rate hint.
                surface.setFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
            }
            surfaceFrameRateHintSubmitted = false
            lastSurfaceFrameRateError = null
        } catch (error: Throwable) {
            lastSurfaceFrameRateError =
                "${error.javaClass.simpleName}: ${error.message.orEmpty()}"
        }
        Log.i(DISPLAY_MODE_TAG, refreshRateDiagnostics(reason).toString())
    }

    @Suppress("DEPRECATION")
    private fun refreshRateDiagnostics(reason: String): Map<String, Any?> {
        val currentDisplay = currentDisplay()
        val attributes = window.attributes
        val activeMode =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) currentDisplay?.mode else null
        val supportedModes =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                currentDisplay?.supportedModes?.map { mode ->
                    "${mode.modeId}:${mode.physicalWidth}x${mode.physicalHeight}" +
                        "@${"%.2f".format(Locale.US, mode.refreshRate)}"
                } ?: emptyList()
            } else {
                emptyList()
            }
        return linkedMapOf(
            "reason" to reason,
            "lastApplyReason" to lastRefreshRateReason,
            "sdk" to Build.VERSION.SDK_INT,
            "requestedRefreshRate" to requestedRefreshRate,
            "requestedDisplayModeId" to requestedDisplayModeId,
            "preferredRefreshRate" to attributes.preferredRefreshRate,
            "preferredDisplayModeId" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                attributes.preferredDisplayModeId
            } else {
                0
            },
            "activeRefreshRate" to (activeMode?.refreshRate ?: currentDisplay?.refreshRate),
            "activeDisplayModeId" to (activeMode?.modeId ?: 0),
            "surfaceHooked" to flutterSurfaceHooked,
            "surfaceAvailable" to (flutterSurfaceView != null),
            "surfaceValid" to (flutterSurfaceView?.holder?.surface?.isValid == true),
            "surfaceFrameRateHintSubmitted" to surfaceFrameRateHintSubmitted,
            "surfaceSetFrameRateError" to lastSurfaceFrameRateError,
            "supportedModes" to supportedModes
        )
    }

    private fun refreshAppWidgets() {
        val appWidgetManager = AppWidgetManager.getInstance(this)
        listOf(SquareAppWidget::class.java, IllustCardAppWidget::class.java).forEach { widgetClass ->
            val componentName = ComponentName(this, widgetClass)
            val widgetIds = appWidgetManager.getAppWidgetIds(componentName)
            if (widgetIds.isNotEmpty()) {
                sendBroadcast(Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).apply {
                    component = componentName
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, widgetIds)
                })
            }
        }
    }

    override fun onActivityResult(
        requestCode: Int, resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        Safer.bindResult(this, requestCode, resultCode, data)
        when (requestCode) {
            PICK_IMAGE_FILE -> if (resultCode == Activity.RESULT_OK) {
                data?.data?.also { uri ->
                    Log.d("flutter.store_path", uri.toString())
                    applicationContext.contentResolver.openInputStream(uri)?.use {
                        val dataR = it.readBytes()
                        pendingPickResult?.success(dataR)
                        pendingPickResult = null
                    }
                }
            } else {
                pendingResult?.success(null)
                pendingResult = null
            }

            OPEN_DOCUMENT_TREE_CODE ->
                if (resultCode == Activity.RESULT_OK) {
                    data?.data?.also { uri ->
                        Log.d("flutter.store_path", uri.toString())
                        if (uri.toString().lowercase().contains("download")) {
                            Toast.makeText(
                                applicationContext,
                                getString(R.string.do_not_choice_download_folder_message),
                                Toast.LENGTH_LONG
                            ).show()
                            choiceFolder(needHint = false)
                            return
                        }
                        val contentResolver = applicationContext.contentResolver
                        val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        contentResolver.takePersistableUriPermission(uri, takeFlags)
                        for (i in contentResolver.persistedUriPermissions) {
                            if (i.isReadPermission && i.isWritePermission && i.uri != uri) {
                                contentResolver.releasePersistableUriPermission(i.uri, takeFlags)
                            }
                        }
                        pendingPickResult?.success(true)
                        pendingPickResult = null
                    }
                } else {
                    Toast.makeText(
                        applicationContext,
                        getString(R.string.failure_to_obtain_authorization_may_cause_some_functions_to_fail_or_crash),
                        Toast.LENGTH_SHORT
                    ).show()
                    pendingPickResult?.success(false)
                    pendingPickResult = null
                }
        }
    }

    private fun getPath(): String? {
        if (saveMode == 0) {
            return "Pictures/PixEz"
        }
        if (saveMode == 2) {
            helplessPath = sharedPreferences.getString("flutter.store_path", "")
            return helplessPath
        }
        val list =
            contentResolver.persistedUriPermissions.takeWhile { it.isReadPermission && it.isWritePermission }
        if (list.isEmpty()) {
            return null
        }
        return list.first().uri.toString()
    }

    private fun encodeGif(path: String, delay: Int, delayArray: List<Int>): String? {
        val file = File(path)
        val tempFile = File.createTempFile("encode_", ".gif", applicationContext.cacheDir)
        try {
            val listFiles = file.listFiles()
            if (listFiles == null || listFiles.isEmpty()) {
                throw RuntimeException("unzip files not found")
            }
            val arrayFile = mutableListOf<File>()
            for (i in listFiles) {
                val ext = i.extension.lowercase()
                if (ext == "jpg" || ext == "jpeg" || ext == "png") {
                    arrayFile.add(i)
                }
            }
            arrayFile.sortWith { o1, o2 -> o1.name.compareTo(o2.name) }
            val bitmap: Bitmap = BitmapFactory.decodeFile(arrayFile.first().path)
            val encoder = GifEncoder()
            encoder.init(
                bitmap.width,
                bitmap.height,
                tempFile.path,
                GifEncoder.EncodingType.ENCODING_TYPE_STABLE_HIGH_MEMORY
            )
            for (i in arrayFile.indices) {
                val trueDelay = if (i < delayArray.size) {
                    delayArray[i]
                } else {
                    delay
                }
                if (i != 0) {
                    val bmp = BitmapFactory.decodeFile(arrayFile[i].path)
                    encoder.encodeFrame(bmp, trueDelay)
                    bmp.recycle()
                } else encoder.encodeFrame(bitmap, trueDelay)
            }
            encoder.close()
            bitmap.recycle()
            return tempFile.absolutePath
        } catch (e: Throwable) {
            e.printStackTrace()
            tempFile.delete()
            return null
        }
    }

    private fun splicingUrl(parentUri: String, fileName: String) = if (parentUri.endsWith(":")) {
        parentUri + fileName
    } else {
        "$parentUri/$fileName"
    }

    private fun choiceFolder(needHint: Boolean = true) {
        if (saveMode == 2 || saveMode == 0) {
            pendingPickResult?.success(true)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
        }
        if (needHint)
            Toast.makeText(
                this,
                getString(R.string.choose_a_suitable_image_storage_directory),
                Toast.LENGTH_SHORT
            ).show()
        startActivityForResult(intent, OPEN_DOCUMENT_TREE_CODE)
    }

    private fun isFileExist(name: String): Boolean {
        when (saveMode) {
            0 -> {
                return exist(name)
            }

            2 -> {
                return File("$helplessPath/$name").exists()
            }

            else -> {
                val treeDocument = DocumentFile.fromTreeUri(
                    this@MainActivity,
                    contentResolver.persistedUriPermissions.takeWhile { it.isReadPermission && it.isWritePermission }
                        .first().uri
                )!!
                if (name.contains("/")) {
                    val names = name.split("/")
                    if (names.size >= 2) {
                        val treeId = DocumentsContract.getTreeDocumentId(treeDocument.uri)
                        val folderName = names.first()
                        val fName = names.last()
                        val dirId = splicingUrl(treeId, folderName)
                        val dirUri =
                            DocumentsContract.buildDocumentUriUsingTree(treeDocument.uri, dirId)
                        val dirDocument = DocumentFile.fromSingleUri(this, dirUri)
                        return if (dirDocument == null || !dirDocument.exists()) {
                            false
                        } else if (dirDocument.isFile) {
                            dirDocument.delete()
                            false
                        } else {
                            val fileId = splicingUrl(dirId, fName)
                            val fileUri =
                                DocumentsContract.buildDocumentUriUsingTree(
                                    treeDocument.uri,
                                    fileId
                                )
                            val targetFile = DocumentFile.fromSingleUri(this, fileUri)
                            targetFile != null && targetFile.exists()
                        }
                    } else {
                        return false
                    }
                }
                val treeId = DocumentsContract.getTreeDocumentId(treeDocument.uri)
                val fileId = splicingUrl(treeId, name)
                val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeDocument.uri, fileId)
                val targetFile = DocumentFile.fromSingleUri(this, fileUri)
                return targetFile != null && targetFile.exists()
            }
        }
    }

    private fun writeFileUri(fileName: String, clearOld: Boolean = false): Uri? {
        val mimeType = if (fileName.endsWith("jpg", ignoreCase = true) || fileName.endsWith(
                "jpeg",
                ignoreCase = true
            )
        ) {
            "image/jpg"
        } else {
            if (fileName.endsWith("png")) {
                "image/png"
            } else {
                "image/gif"
            }
        }
        val permissions =
            contentResolver.persistedUriPermissions.takeWhile { it.isReadPermission && it.isWritePermission }
        if (permissions.isEmpty()) {
            choiceFolder()
            return null
        }
        val parentUri =
            permissions
                .first().uri
        val treeDocument = DocumentFile.fromTreeUri(this@MainActivity, parentUri)!!
        val treeId = DocumentsContract.getTreeDocumentId(treeDocument.uri)

        if (fileName.contains("/")) {
            val names = fileName.split("/")
            if (names.size >= 2) {
                try {
                    var folderDocument: DocumentFile? = treeDocument
                    val fName = names.last()
                    val list = names.subList(0, names.size - 1)
                    for (name in list) {
                        folderDocument = folderDocument!!.findFile(name)
                            ?: folderDocument.createDirectory(name)!!
                    }
                    return folderDocument?.createFile(mimeType, fName)?.uri
                } catch (e: Throwable) {
                    return null
                }
            }
        }
        if (clearOld && fileName.contains("_p0"))
            treeDocument.findFile(fileName.replace("_p0", ""))
        val fileId = splicingUrl(treeId, fileName)
        val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeDocument.uri, fileId)
        val targetFile = DocumentFile.fromSingleUri(this, fileUri)
        if (targetFile != null) {
            if (targetFile.exists()) {
                targetFile.delete()
            }
        }
        return treeDocument.createFile(mimeType, fileName)?.uri
    }

    private fun wr(data: ByteArray, uri: Uri) {
        contentResolver.openOutputStream(uri, "w")?.use {
            it.write(data)
        }
    }

}
