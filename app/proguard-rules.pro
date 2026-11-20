# WebView 的 JS 桥接由 @JavascriptInterface 反射调用，禁止混淆（release 已关闭混淆，此处双保险）
-keepclassmembers class com.yuhua.printclient.** {
    @android.webkit.JavascriptInterface <methods>;
}
-keep class com.yuhua.printclient.MainActivity$Bridge { *; }
