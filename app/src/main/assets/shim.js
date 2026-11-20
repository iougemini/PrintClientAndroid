/* ============================================================
   印刷管理 App 注入脚本（在网页加载完成后由原生注入）
   作用：把安卓 WebView 缺的几件事补齐，网页源码一行不改。
     1. window.print()  -> 系统打印（原生 PrintManager）
     2. Blob 导出下载   -> 保存到手机「下载/印刷系统导出」
     3. 打印版式 + 手机端少量样式微调
   ============================================================ */
(function () {
  if (window.__printClientShim) return;
  window.__printClientShim = true;

  var B = window.PrintBridge;

  /* ---------- 1. 样式：打印版式（复刻 style.css 的 @media print）---------- */
  var css = ''
    + 'html.printing,html.printing[data-theme="dark"]{'
    + '--text:#111;--text-2:#333;--text-3:#555;--bg:#fff;--bg-2:#fff;--surface:#fff;--line:#999;'
    + '--ink-2:#333;--ink-3:#555}'
    + 'html.printing body{background:#fff;color:#111}'
    + 'html.printing .app,html.printing .modal-mask,html.printing .toast,html.printing .no-print{display:none !important}'
    + 'html.printing .print-only{display:block !important;padding:0;color:#111}'
    /* 手机端微调：窄屏留白收一点，输入框 16px 避免聚焦时被强制放大 */
    + '@media (max-width:600px){'
    + '.content{padding:12px}'
    + 'input,select,textarea{font-size:16px !important}'
    + '}'
    + 'html{-webkit-text-size-adjust:100%}'
    + 'body{padding-bottom:env(safe-area-inset-bottom)}';

  try {
    var style = document.createElement('style');
    style.id = 'print-client-style';
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  } catch (e) { /* 忽略 */ }

  if (!B) return;

  /* ---------- 2. 打印：window.print() 交给原生 ---------- */
  window.print = function () {
    try { B.printPage(); } catch (e) { /* 忽略 */ }
  };

  /* ---------- 3. 导出：Blob 的 a[download] 改走原生保存 ---------- */
  var origClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    try {
      var href = this.getAttribute('href') || '';
      if (this.hasAttribute('download') && href.indexOf('blob:') === 0) {
        var name = this.getAttribute('download') || '导出文件';
        fetch(href).then(function (r) {
          return r.blob();
        }).then(function (blob) {
          var fr = new FileReader();
          fr.onload = function () {
            var s = String(fr.result || '');
            var i = s.indexOf(',');
            var b64 = i >= 0 ? s.slice(i + 1) : '';
            if (!b64) { B.toast('导出失败：文件为空'); return; }
            B.saveFile(name, blob.type || 'application/octet-stream', b64);
          };
          fr.onerror = function () { B.toast('导出失败，请重试'); };
          fr.readAsDataURL(blob);
        }).catch(function () {
          B.toast('导出失败，请重试');
        });
        return;
      }
    } catch (e) { /* 落到原生行为 */ }
    return origClick.apply(this, arguments);
  };

  /* ---------- 4. 长按返回键无法拦截时，网页侧提供手动入口 ---------- */
  window.PrintClient = {
    version: '1.0',
    serverUrl: function () { try { return B.serverUrl(); } catch (e) { return ''; } },
    openSettings: function () { try { B.openSettings(); } catch (e) { /* 忽略 */ } }
  };
})();
