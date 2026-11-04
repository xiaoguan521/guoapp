package com.duanju.duanju_app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class AppUpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var attached = false

    companion object {
        @Suppress("DEPRECATION")
        fun information(context: Context): Map<String, Any> {
            val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_META_DATA)
            val build = context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA).metaData?.get("duanju.buildNumber")?.toString()?.toLongOrNull() ?: 0L
            val abis = Build.SUPPORTED_ABIS.filter {
                if (Process.is64Bit()) it == "arm64-v8a" || it == "x86_64" else it == "armeabi-v7a"
            }
            return mapOf("version" to info.versionName.orEmpty(), "build" to build, "abis" to abis)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "duanju/update")
        channel.setMethodCallHandler(this)
        attached = true
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> result.success(information(context))
            "canInstall" -> result.success(Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls())
            "openInstallSettings" -> {
                try {
                    if (Build.VERSION.SDK_INT >= 26) {
                        context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                    result.success(null)
                } catch (_: Exception) {
                    result.error("install_settings_unavailable", "无法打开安装来源设置，请在系统设置中检查", null)
                }
            }
            "openReleasePage" -> {
                try {
                    val uri = Uri.parse(call.argument<String>("url"))
                    val allowedHost = call.argument<String>("host").orEmpty()
                    require(uri.scheme == "https" && uri.host == allowedHost && allowedHost.isNotEmpty())
                    context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                } catch (_: Exception) {
                    result.error("release_page_unavailable", "无法打开官方下载页", null)
                }
            }
            "install" -> worker.execute {
                val checked = runCatching { verifyPackage(call) }
                main.post {
                    if (attached) checked.fold(onSuccess = { file ->
                        if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
                            result.success("permissionRequired")
                        } else {
                            try {
                                val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", file)
                                context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                result.success("installerOpened")
                            } catch (_: Exception) {
                                result.error("installer_unavailable", "无法打开系统安装器，请从官方下载页安装", null)
                            }
                        }
                    }, onFailure = { failure ->
                        result.error("invalid_update_package", failure.message ?: "更新包校验失败，请重新下载", null)
                    })
                }
            }
            else -> result.notImplemented()
        }
    }

    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> {
        val certificates = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return certificates.orEmpty().map {
            MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString("") { part -> "%02x".format(part) }
        }.toSet()
    }

    @Suppress("DEPRECATION")
    private fun verifyPackage(call: MethodCall): File {
        val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
        val root = File(context.cacheDir, "app_updates").canonicalFile
        require(file.isFile && file.extension == "apk" && file.path.startsWith(root.path + File.separator)) {
            "更新包路径无效，请重新下载"
        }
        val expected = call.argument<String>("sha256").orEmpty()
        require(expected.matches(Regex("[0-9a-f]{64}"))) { "更新包缺少校验信息" }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        require(actual == expected) { "更新包摘要不一致，请重新下载" }
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val candidate = context.packageManager.getPackageArchiveInfo(file.path, flags)
            ?: throw IllegalArgumentException("无法读取更新包签名，请重新下载")
        val installed = context.packageManager.getPackageInfo(context.packageName, flags)
        require(candidate.packageName == context.packageName) { "更新包不属于当前应用版本" }
        val expectedSignatures = signatures(installed)
        require(expectedSignatures.isNotEmpty() && signatures(candidate) == expectedSignatures) {
            "更新包与当前应用签名不一致，不能覆盖安装，请使用原渠道的兼容版本"
        }
        val candidateCode = if (Build.VERSION.SDK_INT >= 28) candidate.longVersionCode else candidate.versionCode.toLong()
        val installedCode = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
        require(candidateCode > installedCode) { "更新包版本不高于当前安装版本" }
        return file
    }
}

class AppUpdateFileProvider : FileProvider()
