// dsh-app 页面 console 转发桥
// 将页面内 JS 的 console 日志 / 未捕获异常 / 未处理 Promise 拒绝转发到原生日志
// （/tmp/dsh-launcher.log），便于排查只发生在页面内的报错。
(function () {
    if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.dshConsole) {
        return;
    }
    var bridge = window.webkit.messageHandlers.dshConsole;

    // 诊断标记：Swift 侧可在 didFinish 后通过 evaluateJavaScript 探测此标记，
    // 用于区分「脚本未注入」与「消息未送达」两种失败场景
    window.__dshBridgeLoaded = true;

    function stringify(arg) {
        if (arg instanceof Error) {
            return arg.name + ': ' + arg.message + (arg.stack ? '\n' + arg.stack : '');
        }
        if (typeof arg === 'object' && arg !== null) {
            try {
                return JSON.stringify(arg);
            } catch (e) {
                return String(arg);
            }
        }
        return String(arg);
    }

    function send(level, args) {
        try {
            var text = Array.prototype.map.call(args, stringify).join(' ');
            bridge.postMessage({ level: level, text: text });
        } catch (e) { /* 转发失败不影响页面运行 */ }
    }

    // 注入确认：桥加载后立即上报，用于确认转发链路已打通
    send('info', ['console-bridge 已注入 @ ' + window.location.href]);

    // 关键时机补报：排除「文档早期 postMessage 消息丢失」的情况
    document.addEventListener('DOMContentLoaded', function () {
        send('info', ['DOMContentLoaded @ ' + window.location.href]);
    });
    window.addEventListener('load', function () {
        send('info', ['window.load @ ' + window.location.href]);
    });

    // 引擎能力报告：确认 polyfill 是否生效（load 后延迟执行，等插件加载完成）
    window.addEventListener('load', function () {
        setTimeout(function () {
            var lookbehind = true;
            try { new RegExp('(?<=a)b'); } catch (e) { lookbehind = false; }
            var api = {
                'AbortSignal.timeout': typeof AbortSignal.timeout === 'function',
                'AbortSignal.any': typeof AbortSignal.any === 'function',
                'crypto.randomUUID': typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function',
                'RegExp.lookbehind': lookbehind
            };
            var sessionBtn = document.body && document.body.innerText.indexOf('Session log') >= 0;
            send('info', ['引擎能力: ' + JSON.stringify(api) +
                          ' | Session log 按钮: ' + (sessionBtn ? '存在' : '不存在') +
                          ' | UA: ' + navigator.userAgent]);
        }, 5000);
    });

    var levels = ['log', 'info', 'warn', 'error', 'debug'];
    levels.forEach(function (level) {
        var original = console[level];
        console[level] = function () {
            send(level, arguments);
            if (original) { original.apply(console, arguments); }
        };
    });

    // 未捕获异常
    window.addEventListener('error', function (e) {
        send('error', [e.message + ' @ ' + e.filename + ':' + e.lineno + ':' + e.colno +
                       (e.error && e.error.stack ? '\n' + e.error.stack : '')]);
    });

    // 未处理的 Promise 拒绝
    window.addEventListener('unhandledrejection', function (e) {
        var reason = e.reason;
        send('error', ['Unhandled promise rejection: ' +
                       (reason instanceof Error ? reason.name + ': ' + reason.message : String(reason))]);
    });

    // 拦截 fetch：记录非 2xx 响应与网络错误（页面内 API 调用失败常被前端静默吞掉，console 看不到）
    var origFetch = window.fetch;
    if (typeof origFetch === 'function') {
        window.fetch = function () {
            var input = arguments[0];
            var urlStr = typeof input === 'string' ? input : (input && input.url) || String(input);
            return origFetch.apply(this, arguments).then(function (resp) {
                if (!resp.ok) {
                    send('warn', ['fetch 非2xx: ' + urlStr + ' → ' + resp.status + ' ' + resp.statusText]);
                }
                return resp;
            }, function (err) {
                send('error', ['fetch 网络错误: ' + urlStr + ' → ' +
                               (err && err.message ? err.message : String(err))]);
                throw err;
            });
        };
    }

    // 拦截 XMLHttpRequest：记录非 2xx 响应与网络错误
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
        this._dshMethod = method;
        this._dshUrl = String(url);
        return origOpen.apply(this, arguments);
    };
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function () {
        var self = this;
        this.addEventListener('load', function () {
            if (self.status >= 400) {
                send('warn', ['XHR ' + self._dshMethod + ' ' + self._dshUrl +
                              ' → ' + self.status + ' ' + self.statusText]);
            }
        });
        this.addEventListener('error', function () {
            send('error', ['XHR 网络错误: ' + self._dshMethod + ' ' + self._dshUrl]);
        });
        return origSend.apply(this, arguments);
    };
})();
