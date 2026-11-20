package com.yuhua.printclient

import android.content.Context
import android.net.Uri

/**
 * 只存一个东西：服务端地址。
 * 其它业务数据全在服务端 SQLite 里，客户端不做任何本地存储。
 */
object Prefs {

    private const val SP_NAME = "settings"
    private const val KEY_SERVER = "server_url"

    /** 瑜华印务管理系统固定端口 */
    const val DEFAULT_PORT = 8090

    fun server(ctx: Context): String? {
        val v = sp(ctx).getString(KEY_SERVER, null)?.trim()
        return if (v.isNullOrEmpty()) null else v
    }

    fun hasServer(ctx: Context): Boolean = server(ctx) != null

    fun saveServer(ctx: Context, raw: String?) {
        val url = normalize(raw) ?: return
        sp(ctx).edit().putString(KEY_SERVER, url).apply()
    }

    /**
     * 把用户随手输的内容规整成可用地址：
     *  192.168.1.50            -> http://192.168.1.50:8090
     *  192.168.1.50:8090       -> http://192.168.1.50:8090
     *  http://192.168.1.50/    -> http://192.168.1.50:8090
     *  http://192.168.1.50:8090/#orders -> http://192.168.1.50:8090
     */
    fun normalize(raw: String?): String? {
        var s = raw?.trim().orEmpty()
        if (s.isEmpty()) return null
        s = s.replace('：', ':').replace('／', '/')
        s = s.substringBefore('#').substringBefore('?')
        if (!s.startsWith("http://", true) && !s.startsWith("https://", true)) {
            s = "http://$s"
        }
        val u = try {
            Uri.parse(s)
        } catch (e: Exception) {
            return null
        }
        val host = u.host ?: return null
        if (host.isBlank()) return null
        val scheme = u.scheme?.lowercase() ?: "http"
        val port = if (u.port > 0) u.port else DEFAULT_PORT
        val path = (u.path ?: "").trimEnd('/')
        return "$scheme://$host:$port$path"
    }

    private fun sp(ctx: Context) = ctx.getSharedPreferences(SP_NAME, Context.MODE_PRIVATE)
}
