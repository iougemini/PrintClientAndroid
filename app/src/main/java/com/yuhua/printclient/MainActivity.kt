package com.yuhua.printclient

import android.Manifest
import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.print.PrintAttributes
import android.print.PrintJob
import android.print.PrintManager
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.view.View
import android.webkit.DownloadListener
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

/**
 * 外壳主界面：一个 WebView 加载内网地址，外加 4 件原生能力
 *   1. 打印（网页里的 window.print 由注入脚本转到系统打印）
 *   2. 导出下载（网页用 Blob 生成 .xls/.json，转 base64 交给原生写入「下载」）
 *   3. 选文件（稿件选择框 input[type=file]）
 *   4. 断线兜底页 + 返回键逻辑
 *
 * 业务逻辑、权限、数据全在服务端，这里不做任何缓存或本地库。
 */
class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private lateinit var progress: ProgressBar
    private lateinit var errorPanel: View
    private lateinit var errMsg: TextView

    private var fileChooserCallback: ValueCallback<Array<Uri>>? = null
    private var lastBackAt = 0L
    private var printing = false

    /** 网页里 <input type="file"> 的选文件回调 */
    private val filePicker = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val cb = fileChooserCallback
        fileChooserCallback = null
        cb?.onReceiveValue(
            WebChromeClient.FileChooserParams.parseResult(result.resultCode, result.data)
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!Prefs.hasServer(this)) {
            startActivity(Intent(this, SetupActivity::class.java))
            finish()
            return
        }
        setContentView(R.layout.activity_main)

        webView = findViewById(R.id.web)
        progress = findViewById(R.id.progress)
        errorPanel = findViewById(R.id.errorPanel)
        errMsg = findViewById(R.id.errMsg)

        findViewById<Button>(R.id.btnRetry).setOnClickListener {
            errorPanel.visibility = View.GONE
            loadServer()
        }
        findViewById<Button>(R.id.btnChange).setOnClickListener { openSettings() }

        setupWebView()
        setupBackHandling()
        askLegacyStoragePermission()
        loadServer()

        // 桌面长按「服务器设置」快捷方式冷启动：直接叠一层设置页
        if (intent?.action == ACTION_SETTINGS) openSettings()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == ACTION_SETTINGS) openSettings()
    }

    /* ------------------------------------------------------------------ WebView */

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        webView.setBackgroundColor(0xFFF5F4F0.toInt())
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true          // 登录 token 存在 localStorage，必须开
            databaseEnabled = true
            useWideViewPort = true            // 尊重网页的 viewport，按手机宽度排版
            loadWithOverviewMode = false
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            mediaPlaybackRequiresUserGesture = false
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            cacheMode = WebSettings.LOAD_DEFAULT
            userAgentString = userAgentString + " PrintClient/1.0"
        }

        webView.addJavascriptInterface(Bridge(), "PrintBridge")

        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                progress.visibility = View.VISIBLE
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                progress.visibility = View.GONE
                errorPanel.visibility = View.GONE
                injectShim()
            }

            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val uri = request?.url ?: return false
                if (uri.scheme == "http" || uri.scheme == "https") return false
                // 电话、邮件等交给系统
                return try {
                    startActivity(Intent(Intent.ACTION_VIEW, uri)); true
                } catch (e: Exception) {
                    true
                }
            }

            @Suppress("DEPRECATION")
            override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean {
                val uri = Uri.parse(url ?: return false)
                if (uri.scheme == "http" || uri.scheme == "https") return false
                return try {
                    startActivity(Intent(Intent.ACTION_VIEW, uri)); true
                } catch (e: Exception) {
                    true
                }
            }

            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                if (request?.isForMainFrame != true) return
                progress.visibility = View.GONE
                errMsg.text = "${Prefs.server(this@MainActivity) ?: ""}\n${error?.description ?: "网络错误"}"
                errorPanel.visibility = View.VISIBLE
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onShowFileChooser(
                webView: WebView?,
                callback: ValueCallback<Array<Uri>>?,
                params: FileChooserParams?
            ): Boolean {
                fileChooserCallback?.onReceiveValue(null)
                fileChooserCallback = callback
                return try {
                    val intent = params?.createIntent() ?: return false
                    filePicker.launch(Intent.createChooser(intent, "选择文件"))
                    true
                } catch (e: Exception) {
                    fileChooserCallback = null
                    false
                }
            }
        }

        // 直链下载（.xls/.json 走 Blob，由注入脚本接管，不会走到这里）
        webView.setDownloadListener(DownloadListener { url, _, contentDisposition, mimeType, _ ->
            if (url.startsWith("blob:")) {
                toast("文件生成中，稍等一下")
                return@DownloadListener
            }
            enqueueDownload(url, contentDisposition, mimeType)
        })
    }

    private fun loadServer() {
        val url = Prefs.server(this) ?: return
        errorPanel.visibility = View.GONE
        webView.loadUrl(url)
    }

    /** 注入打印/下载桥接与少量移动端样式；失败不影响主流程。 */
    private fun injectShim() {
        try {
            val js = assets.open("shim.js").bufferedReader().use { it.readText() }
            webView.evaluateJavascript(js, null)
        } catch (e: Exception) {
            Log.w(TAG, "注入脚本失败", e)
        }
    }

    /* ------------------------------------------------------------------ 返回键 */

    private fun setupBackHandling() {
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (webView.canGoBack()) {
                    webView.goBack()
                    return
                }
                val now = System.currentTimeMillis()
                if (now - lastBackAt < 2000) {
                    finish()
                } else {
                    lastBackAt = now
                    toast(getString(R.string.exit_hint) + "（长按桌面图标可改服务器地址）")
                }
            }
        })
    }

    /* ------------------------------------------------------------------ 打印 */

    private fun startPrint() {
        if (printing) {
            toast("打印任务正在进行")
            return
        }
        printing = true
        // 网页的 @media print 规则在 WebView 里不一定生效，
        // 先用 .printing 类把页面切成「只显示单据」的白底版式，再交给系统打印。
        webView.evaluateJavascript("document.documentElement.classList.add('printing')", null)
        webView.postDelayed({
            try {
                val pm = getSystemService(Context.PRINT_SERVICE) as PrintManager
                @Suppress("DEPRECATION")
                val adapter = webView.createPrintDocumentAdapter("瑜华印务管理系统")
                val attrs = PrintAttributes.Builder()
                    .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
                    .setColorMode(PrintAttributes.COLOR_MODE_COLOR)
                    .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                    .build()
                watchPrintJob(pm.print("瑜华印务管理系统-单据", adapter, attrs))
            } catch (e: Throwable) {
                endPrinting()
                toast("无法调起打印：${e.message}")
            }
        }, 400)
    }

    /**
     * 盯着打印任务，结束后把页面从白底单据版式恢复回来。
     *
     * 注意：PrintManager 的 PrintJobStateChangeListener / addPrintJobStateChangeListener
     * 都是 system API（@SystemApi），普通应用编译时根本看不到这些符号，所以这里改用
     * 公开 API PrintManager.getPrintJobs() 每秒轮询一次任务状态。
     */
    private fun watchPrintJob(job: PrintJob?) {
        val target = job ?: run { endPrinting(); return }
        val pm = getSystemService(Context.PRINT_SERVICE) as PrintManager
        var waited = 0L
        var seen = false
        val tick = object : Runnable {
            override fun run() {
                waited += POLL_MS
                val current = try {
                    pm.printJobs.firstOrNull { it.id == target.id }
                } catch (e: Exception) {
                    null
                }
                if (current != null) seen = true
                val finished = (current == null && seen) ||
                    current?.isCompleted == true ||
                    current?.isCancelled == true ||
                    current?.isFailed == true
                // 任务一直没出现在列表里（用户直接关掉了打印面板）也别死等
                val giveUp = if (seen) waited >= PRINT_TIMEOUT_MS else waited >= NO_JOB_MS
                if (finished || giveUp) {
                    endPrinting()
                } else {
                    webView.postDelayed(this, POLL_MS)
                }
            }
        }
        webView.postDelayed(tick, POLL_MS)
    }

    private fun endPrinting() {
        printing = false
        webView.post {
            webView.evaluateJavascript("document.documentElement.classList.remove('printing')", null)
        }
    }

    /* ------------------------------------------------------------------ 导出保存 */

    private fun saveToDownloads(name: String, mime: String, base64: String) {
        try {
            val bytes = Base64.decode(base64, Base64.DEFAULT)
            val safeName = name.replace(Regex("[\\\\/:*?\"<>|]"), "_").ifBlank { "导出文件" }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/印刷系统导出")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val resolver = contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IOException("系统未返回文件位置")
                resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: throw IOException("写入失败")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } else {
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE)
                    != PackageManager.PERMISSION_GRANTED
                ) {
                    toast("请在系统设置里允许「存储」权限后再导出")
                    return
                }
                val dir = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    "印刷系统导出"
                )
                if (!dir.exists()) dir.mkdirs()
                var target = File(dir, safeName)
                var i = 1
                while (target.exists()) {
                    val dot = safeName.lastIndexOf('.')
                    val stem = if (dot > 0) safeName.substring(0, dot) else safeName
                    val ext = if (dot > 0) safeName.substring(dot) else ""
                    target = File(dir, "$stem(${i++})$ext")
                }
                FileOutputStream(target).use { it.write(bytes) }
            }
            toast("已保存到「下载/印刷系统导出/$safeName」")
        } catch (e: Exception) {
            toast("保存失败：${e.message}")
        }
    }

    private fun enqueueDownload(url: String, contentDisposition: String?, mimeType: String?) {
        try {
            @Suppress("DEPRECATION")
            val dm = getSystemService(Context.DOWNLOAD_SERVICE) as android.app.DownloadManager
            val req = android.app.DownloadManager.Request(Uri.parse(url)).apply {
                setMimeType(mimeType)
                setNotificationVisibility(
                    android.app.DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                )
                setDestinationInExternalPublicDir(
                    Environment.DIRECTORY_DOWNLOADS, guessFileName(url, contentDisposition)
                )
            }
            dm.enqueue(req)
            toast("开始下载到「下载」目录")
        } catch (e: Exception) {
            toast("下载失败：${e.message}")
        }
    }

    private fun guessFileName(url: String, contentDisposition: String?): String {
        val cd = contentDisposition ?: ""
        val idx = cd.indexOf("filename=")
        if (idx >= 0) {
            return cd.substring(idx + 9).trim().trim('"', '\'', ';').ifBlank { "download" }
        }
        val tail = url.substringBefore('?').substringAfterLast('/')
        return if (tail.isBlank()) "download" else Uri.decode(tail)
    }

    /* ------------------------------------------------------------------ 权限与工具 */

    private fun askLegacyStoragePermission() {
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 2001)
        }
    }

    private fun openSettings() {
        startActivity(Intent(this, SetupActivity::class.java))
    }

    private fun toast(msg: String) {
        // 导出/保存跑在子线程，统一回主线程弹
        runOnUiThread { Toast.makeText(this, msg, Toast.LENGTH_SHORT).show() }
    }

    /* ------------------------------------------------------------------ JS 桥 */

    /** 网页侧通过 window.PrintBridge 调用，方法签名不可随意改（见 assets/shim.js） */
    inner class Bridge {

        @JavascriptInterface
        fun printPage() {
            runOnUiThread { startPrint() }
        }

        @JavascriptInterface
        fun saveFile(name: String?, mime: String?, base64: String?) {
            val data = base64
            if (data.isNullOrEmpty()) return
            val n = name?.takeIf { it.isNotBlank() } ?: "导出文件"
            val m = mime?.takeIf { it.isNotBlank() } ?: "application/octet-stream"
            Thread { saveToDownloads(n, m, data) }.start()
        }

        @JavascriptInterface
        fun toast(msg: String?) {
            runOnUiThread { Toast.makeText(this@MainActivity, msg.orEmpty(), Toast.LENGTH_SHORT).show() }
        }

        @JavascriptInterface
        fun serverUrl(): String = Prefs.server(this@MainActivity).orEmpty()

        @JavascriptInterface
        fun openSettings() {
            runOnUiThread { this@MainActivity.openSettings() }
        }
    }

    companion object {
        private const val TAG = "PrintClient"
        const val ACTION_SETTINGS = "com.yuhua.printclient.action.SETTINGS"

        /** 打印任务状态轮询间隔 */
        private const val POLL_MS = 1000L

        /** 打印任务最长观察时间，超时无条件恢复页面 */
        private const val PRINT_TIMEOUT_MS = 120_000L

        /** 打印任务始终没出现在系统列表里（用户关掉了面板）时的等待上限 */
        private const val NO_JOB_MS = 20_000L
    }
}
