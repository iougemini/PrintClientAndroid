package com.yuhua.printclient

import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException

/**
 * 内网地址设置页。首次启动、连接失败、桌面图标长按快捷方式都会进入这里。
 * 点「测试并进入」会真的去 ping 一下 /api/session：能通（哪怕返回 401）就说明服务器活着。
 */
class SetupActivity : AppCompatActivity() {

    private lateinit var edServer: TextInputEditText
    private lateinit var tilServer: TextInputLayout
    private lateinit var tvStatus: TextView
    private lateinit var btnConnect: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_setup)

        edServer = findViewById(R.id.edServer)
        tilServer = findViewById(R.id.tilServer)
        tvStatus = findViewById(R.id.tvStatus)
        btnConnect = findViewById(R.id.btnConnect)

        edServer.setText(Prefs.server(this) ?: BuildConfig.DEFAULT_SERVER_URL)

        btnConnect.setOnClickListener { testAndEnter() }
        edServer.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_GO || actionId == EditorInfo.IME_ACTION_DONE) {
                testAndEnter(); true
            } else false
        }
    }

    private fun testAndEnter() {
        tilServer.error = null
        val url = Prefs.normalize(edServer.text?.toString())
        if (url == null) {
            tilServer.error = getString(R.string.err_bad_url)
            return
        }
        edServer.setText(url)
        btnConnect.isEnabled = false
        btnConnect.text = getString(R.string.setup_testing)
        showStatus(getString(R.string.setup_testing))

        Thread {
            val fail = probe(url)
            runOnUiThread {
                btnConnect.isEnabled = true
                btnConnect.text = getString(R.string.setup_test)
                if (fail == null) {
                    Prefs.saveServer(this, url)
                    showStatus(getString(R.string.setup_ok))
                    startActivity(Intent(this, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                    })
                    finish()
                } else {
                    showStatus("连不上：$fail")
                    confirmEnterAnyway(url, fail)
                }
            }
        }.start()
    }

    /** 探测失败时也允许进：万一是服务端临时忙，进去后错误页还能重试。 */
    private fun confirmEnterAnyway(url: String, reason: String) {
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.err_title)
            .setMessage("$reason\n\n要让 App 直接打开这个地址吗？进去后仍可重试或改地址。")
            .setNegativeButton("留在此页") { _, _ -> }
            .setPositiveButton("仍然进入") { _, _ ->
                Prefs.saveServer(this, url)
                startActivity(Intent(this, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                })
                finish()
            }
            .show()
    }

    /** 返回 null 表示可达；否则返回失败原因。 */
    private fun probe(base: String): String? {
        var conn: HttpURLConnection? = null
        try {
            val c = (URL("$base/api/session").openConnection() as HttpURLConnection).apply {
                connectTimeout = 4000
                readTimeout = 4000
                requestMethod = "GET"
                instanceFollowRedirects = false
            }
            conn = c
            // 401 说明服务器在跑、只是没登录，同样算「通」
            val code = c.responseCode
            return if (code in 100..599) null else "HTTP $code"
        } catch (e: Exception) {
            return when (e) {
                is SocketTimeoutException -> "连接超时（服务端电脑没开机 / 不在同一局域网 / 防火墙拦截）"
                is ConnectException -> "连接被拒绝（端口写错，或服务端没启动）"
                is UnknownHostException -> "地址无法解析，请检查 IP"
                else -> e.message ?: e.javaClass.simpleName
            }
        } finally {
            try { conn?.disconnect() } catch (e: Exception) { /* 忽略 */ }
        }
    }

    private fun showStatus(msg: String) {
        tvStatus.visibility = View.VISIBLE
        tvStatus.text = msg
    }
}
