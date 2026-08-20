// dsh-app 注入的 Web API polyfill
// 用途：为 macOS 12（Safari 15 引擎）等旧 WebKit 兜底缺失的现代 Web API。
// 新增 polyfill 直接追加到此文件即可，无需改动 Swift 源码，重新构建自动打入 .app。
//
// 背景：dsh 前端通信层（dsh-client-connection）的 postJson / mintRpcId 会调用
// AbortSignal.timeout / AbortSignal.any / crypto.randomUUID，缺失时所有 API RPC 失败，
// 依赖 RPC 的插件（如 session-log-export 的「Session log」按钮）不会被加载。

// AbortSignal.timeout —— 原生支持需 Safari 16+ / Chrome 103+ / Firefox 100+
if (typeof AbortSignal.timeout !== 'function') {
    AbortSignal.timeout = function (ms) {
        var controller = new AbortController();
        setTimeout(function () {
            controller.abort(new DOMException('The operation timed out', 'TimeoutError'));
        }, ms);
        return controller.signal;
    };
}

// AbortSignal.any —— 原生支持需 Safari 17.4+ / Chrome 116+ / Firefox 117+
// 组合多个 signal：任一中止则整体中止，reason 沿用首个中止的 signal
if (typeof AbortSignal.any !== 'function') {
    AbortSignal.any = function (signals) {
        var controller = new AbortController();
        if (!signals || signals.length === 0) return controller.signal;
        var onAbort = function () {
            controller.abort(this.reason);
            signals.forEach(function (s) { s.removeEventListener('abort', onAbort); });
        };
        for (var i = 0; i < signals.length; i++) {
            var s = signals[i];
            if (!s) continue;
            if (s.aborted) { onAbort.call(s); break; }
            s.addEventListener('abort', onAbort);
        }
        return controller.signal;
    };
}

// crypto.randomUUID —— 原生支持需 Safari 15.4+ / Chrome 92+ / Firefox 95+
// macOS 12 早期补丁（Safari 15.0–15.3）缺失；RPC 消息 id 生成依赖它
if (typeof crypto !== 'undefined' && typeof crypto.randomUUID !== 'function') {
    crypto.randomUUID = function () {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
            var r = Math.random() * 16 | 0;
            var v = c === 'x' ? r : (r & 0x3 | 0x8);
            return v.toString(16);
        });
    };
}

// lookbehind 断言降级 —— 原生支持需 Safari 16.4+ / Chrome 62+ / Firefox 78+
// dsh 代码高亮库（highlight.js）的语言定义大量使用动态 lookbehind 正则
// （new RegExp("(?<!...)")），旧引擎直接抛 SyntaxError，导致 conversation 插件
// 崩溃、消息区与 session log 按钮等不显示。此处仅在不支持 lookbehind 的引擎上
// 劫持 RegExp 构造：将 lookbehind 断言弱化为空断言 (?:)（不消耗字符、不改捕获组号），
// 代价是部分代码高亮边界判定不精确，换取页面不崩溃。命名组 (?<name>) 不受影响。
(function () {
    var supported = false;
    try { new RegExp('(?<=a)b'); supported = true; } catch (e) {}
    if (supported) return;

    var NativeRegExp = RegExp;

    // 把 (?<=...) / (?<!...) 替换为 (?:)，正确处理嵌套括号与转义，保留命名组
    function stripLookbehind(pattern) {
        var out = '', i = 0, len = pattern.length;
        while (i < len) {
            var ch = pattern[i];
            if (ch === '\\') {
                out += ch + (pattern[i + 1] || '');
                i += 2;
                continue;
            }
            if (ch === '(' && pattern[i + 1] === '?' && pattern[i + 2] === '<' &&
                (pattern[i + 3] === '=' || pattern[i + 3] === '!')) {
                var depth = 1, j = i + 4;
                while (j < len && depth > 0) {
                    if (pattern[j] === '\\') { j += 2; continue; }
                    if (pattern[j] === '(') depth++;
                    else if (pattern[j] === ')') depth--;
                    j++;
                }
                out += '(?:)';
                i = j;
            } else {
                out += ch;
                i++;
            }
        }
        return out;
    }

    window.RegExp = function (pattern, flags) {
        if (typeof pattern === 'string' && pattern.indexOf('(?<') !== -1) {
            pattern = stripLookbehind(pattern);
        }
        return new NativeRegExp(pattern, flags);
    };
    window.RegExp.prototype = NativeRegExp.prototype;
})();
