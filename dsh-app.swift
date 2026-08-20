import Cocoa
import WebKit

// ─── 日志 ───────────────────────────────────────────────────
let LOG_PATH = "/tmp/dsh-launcher.log"

// 统一使用北京时间（Asia/Shanghai），不随系统时区变化
let LOG_FORMATTER: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func logToFile(_ msg: String) {
    let line = "[\(LOG_FORMATTER.string(from: Date()))] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: LOG_PATH) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: LOG_PATH)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: LOG_PATH))
        }
    }
}

// ─── App Delegate ───────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {

    let DSH_URL = "http://127.0.0.1:3080"

    var dshProcess: Process?
    var startedDSHProcess = false  // 本次会话是否由本应用启动过 dsh（决定退出时是否清理 3080）
    var window: NSWindow!
    var webView: WKWebView!
    var loadingView: NSView!
    var loadingSpinner: NSProgressIndicator!
    var statusLabel: NSTextField!
    var retryButton: NSButton!
    var isQuitting = false
    var cachedDSHVersion: String?   // dsh 启动成功后异步预取的版本，缓存供 About 使用
    private var isPrefetchingVersion = false  // 防止版本预取被并发触发多次
    private var aboutPanelController: AboutPanelController?  // 持有 About 面板防止释放

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        logToFile("=== App 启动 ===")
        buildMainMenu()
        setupWindow()
        startDSH()
    }

    func applicationWillTerminate(_ notification: Notification) {
        isQuitting = true
        stopDSH()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            setupWindow()
            startDSH()
        }
        return true
    }

    // MARK: 窗口与内嵌 WebView

    func setupWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 1200, height: 800)

        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "dsh-app"
        window.center()
        window.setFrameAutosaveName("DSHMainWindow")
        window.isReleasedWhenClosed = false

        let container = NSView(frame: contentRect)

        // 内嵌 WebView：随窗口伸缩
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // 持久化存储，保留登录态等

        // 注入 Web API polyfill（资源文件 polyfills.js，旧版 WebKit 兜底；新增 polyfill 无需改 Swift）
        // 资源缺失时降级为不注入：新版 macOS 本身支持这些 API，不影响正常使用
        if let polyfillURL = Bundle.main.url(forResource: "polyfills", withExtension: "js", subdirectory: "js"),
           let polyfillJS = try? String(contentsOf: polyfillURL, encoding: .utf8) {
            config.userContentController.addUserScript(
                WKUserScript(source: polyfillJS,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: false)
            )
        } else {
            logToFile("警告: 未找到 polyfills.js 资源，跳过 polyfill 注入")
        }

        // 注入页面 console 转发桥（console-bridge.js）：页面内 JS 日志/报错写入 App 日志，方便排查
        if let bridgeURL = Bundle.main.url(forResource: "console-bridge", withExtension: "js", subdirectory: "js"),
           let bridgeJS = try? String(contentsOf: bridgeURL, encoding: .utf8) {
            config.userContentController.addUserScript(
                WKUserScript(source: bridgeJS,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: false)
            )
            config.userContentController.add(self, name: "dshConsole")
        } else {
            logToFile("警告: 未找到 console-bridge.js 资源，跳过页面日志转发")
        }

        webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        container.addSubview(webView)

        // 等待画面（覆盖在 WebView 之上）
        loadingView = NSView(frame: container.bounds)
        loadingView.autoresizingMask = [.width, .height]
        loadingView.wantsLayer = true
        loadingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.addSubview(loadingView)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(spinner)
        loadingSpinner = spinner

        let label = NSTextField(labelWithString: "正在启动 DeepSeek Harness…")
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(label)
        statusLabel = label

        let retry = NSButton(title: "重试", target: self, action: #selector(retryStart))
        retry.isHidden = true
        retry.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(retry)
        retryButton = retry

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor, constant: -20),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: loadingView.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(lessThanOrEqualTo: loadingView.trailingAnchor, constant: -40),
            label.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            retry.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            retry.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16)
        ])

        spinner.startAnimation(nil)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
    }

    // MARK: 启动 dsh

    func startDSH() {
        logToFile("startDSH 调用")
        if isQuitting { return }
        showLoading("正在检查 Node.js / pnpm…", spinner: true)

        checkEnvironment { ok in
            guard !self.isQuitting else { return }
            if !ok {
                logToFile("环境检测未通过，等待重试")
                self.loadingSpinner?.stopAnimation(nil)
                self.loadingSpinner?.isHidden = true
                self.retryButton?.isHidden = false
                return
            }
            self.launchDSH()
        }
    }

    /// 环境就绪后的启动流程（端口判断 + 拉起 pnpm dlx）
    private func launchDSH() {
        logToFile("环境检测通过，开始启动")
        showLoading("正在启动 DeepSeek Harness…", spinner: true)

        // 端口已被占用（可能残留或手动启动过），直接加载
        if isPortOpen() {
            logToFile("端口 3080 已被占用，直接加载")
            loadDSH()
            prefetchDSHVersion()
            return
        }

        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        let extraPath = "\(NSHomeDirectory())/Library/pnpm/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = "\(extraPath):\(path)"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["pnpm", "dlx", "@deepseek-ai/dsh", "web"]
        proc.environment = env

        proc.terminationHandler = { _ in
            logToFile("dsh 进程退出")
        }

        dshProcess = proc
        startedDSHProcess = true

        DispatchQueue.global().async {
            do {
                try proc.run()
                logToFile("pnpm dlx 已启动 (PID: \(proc.processIdentifier))")

                let started = self.waitForPort(timeout: 120)
                guard !self.isQuitting else { return }

                DispatchQueue.main.async {
                    if started {
                        logToFile("端口就绪，加载页面")
                        self.loadDSH()
                        self.prefetchDSHVersion()
                    } else {
                        logToFile("端口等待超时")
                        self.showLoading("启动超时（120s），请检查网络后重试", spinner: false)
                    }
                }
            } catch {
                logToFile("启动失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.showLoading("启动失败：\(error.localizedDescription)", spinner: false)
                }
            }
        }
    }

    // MARK: 加载页面

    func loadDSH() {
        guard let url = URL(string: DSH_URL) else { return }
        let request = URLRequest(url: url)
        webView.load(request)
    }

    // MARK: 环境检测

    /// 后台检测 node / pnpm，结果写回等待画面，回调返回是否全部就绪
    func checkEnvironment(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let node = self.commandVersion("node")
            let pnpm = self.commandVersion("pnpm")

            var parts: [String] = []
            if let v = node {
                parts.append("✅ Node.js \(v)")
            } else {
                parts.append("❌ Node.js 未安装（brew install node）")
            }
            if let v = pnpm {
                parts.append("✅ pnpm \(v)")
            } else {
                parts.append("❌ pnpm 未安装（npm install -g pnpm）")
            }
            let message = parts.joined(separator: "\n")

            DispatchQueue.main.async {
                self.statusLabel?.stringValue = message
                self.statusLabel?.textColor = (node != nil && pnpm != nil) ? .secondaryLabelColor : .systemRed
                completion(node != nil && pnpm != nil)
            }
        }
    }

    /// 运行 `<cmd> --version`，成功返回版本串（走与启动一致的 PATH）
    private func commandVersion(_ cmd: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [cmd, "--version"]

        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        let extraPath = "\(NSHomeDirectory())/Library/pnpm/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = "\(extraPath):\(path)"
        task.environment = env

        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let data = (task.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile(),
              let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty else { return nil }
        return str
    }

    // MARK: 等待画面控制

    func showLoading(_ message: String, spinner: Bool) {
        loadingSpinner?.startAnimation(nil)
        loadingSpinner?.isHidden = !spinner
        statusLabel?.stringValue = message
        retryButton?.isHidden = spinner
        loadingView?.isHidden = false
    }

    func hideLoading() {
        loadingSpinner?.stopAnimation(nil)
        loadingView?.isHidden = true
    }

    @objc func retryStart() {
        logToFile("手动重试")
        stopDSH()
        startDSH()
    }

    // MARK: 下载支持（a[download] / Content-Disposition: attachment → WKDownload）
    // WKWebView 默认不处理 <a download>，需要原生 WKDownload 支持才能把 ZIP 保存到磁盘

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let url = navigationResponse.response.url?.absoluteString ?? ""
        var isDownload = false
        if let http = navigationResponse.response as? HTTPURLResponse {
            let cd = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            isDownload = cd.contains("attachment") || ct.contains("zip")
        }
        // Session 导出下载走 /api/session.export（响应头可能不带 attachment），URL 兜底判断
        if isDownload || url.contains("/api/session.export") {
            logToFile("开始下载: \(url)")
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dest = dir.appendingPathComponent(suggestedFilename)
        logToFile("下载保存到: \(dest.path)")
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        logToFile("下载完成: \(download.originalRequest?.url?.absoluteString ?? "未知")")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        logToFile("下载失败: \(error.localizedDescription)")
    }

    // MARK: WKScriptMessageHandler（页面 console → App 日志）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dshConsole",
              let payload = message.body as? [String: Any],
              let level = payload["level"] as? String,
              let text = payload["text"] as? String else { return }
        logToFile("页面[\(level)]: \(text)")
    }

    // MARK: WKNavigationDelegate

    /// 下载导航（a[download] 被转为 WKDownload 后）会触发
    /// 「Frame load interrupted」（WebKitErrorDomain 102），这是策略变更的正常表现，
    /// 不应当作页面加载失败处理（否则会弹错误遮罩挡住页面与下载成功提示）
    private func isDownloadInterruptedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "WebKitErrorDomain" && nsError.code == 102
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideLoading()
        window.title = webView.title ?? "dsh-app"
        let url = webView.url?.absoluteString ?? "未知"
        logToFile("页面加载完成: \(url) (\(webView.title ?? "无标题"))")
        // 探测注入桥标记，区分「脚本未注入」与「消息未送达」
        webView.evaluateJavaScript("typeof window.__dshBridgeLoaded !== 'undefined' && window.__dshBridgeLoaded") { result, error in
            if let error = error {
                logToFile("页面注入探测失败: \(error.localizedDescription)")
            } else if let loaded = result as? Bool {
                logToFile("页面注入状态: console-bridge \(loaded ? "已加载" : "未加载")")
            } else {
                logToFile("页面注入状态: 未知 (\(String(describing: result)))")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isDownloadInterruptedError(error) { return }
        logToFile("页面导航失败: \(error.localizedDescription)")
        showLoading("加载失败：\(error.localizedDescription)", spinner: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isDownloadInterruptedError(error) { return }
        logToFile("页面加载失败: \(error.localizedDescription)")
        showLoading("加载失败：\(error.localizedDescription)", spinner: false)
    }

    // 站外链接交给默认浏览器，站内请求保持内嵌
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.host == "127.0.0.1" || url.host == "localhost" {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: WKUIDelegate（target=_blank / window.open 落到默认浏览器）

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    // MARK: 退出清理

    func stopDSH() {
        if let proc = dshProcess {
            logToFile("终止 pnpm dlx 进程 (PID: \(proc.processIdentifier))")
            if proc.isRunning { proc.terminate() }
            dshProcess = nil
        }
        // 兜底：pnpm dlx 退出后子进程可能残留，按端口把真正监听的 server 停掉
        if startedDSHProcess {
            killPortOwner()
        }
    }

    /// 杀掉监听 3080 端口的进程
    func killPortOwner() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-t", "-i", ":3080"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: data, encoding: .utf8)?
            .split(whereSeparator: { $0.isNewline })
            .compactMap { Int32(String($0)) } ?? []

        for pid in pids {
            logToFile("结束 dsh server 进程 (PID: \(pid))")
            kill(pid, SIGTERM)
        }
    }

    // MARK: 菜单

    func buildMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 dsh-app",
                        action: #selector(showAbout(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 dsh-app",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // 编辑菜单（WebView 内复制粘贴需要）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // 窗口菜单
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    /// 自定义“关于”对话框：主显示实际运行的 DeepSeek Harness 版本，辅显示启动器版本
    /// （dsh 版本为启动成功后异步预取并缓存的版本，避免每次打开对话框重复请求导致版本漂移）
    @objc func showAbout(_ sender: Any?) {
        let launcherVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"

        let controller = AboutPanelController(launcherVersion: launcherVersion)
        aboutPanelController = controller
        controller.show()

        if let version = cachedDSHVersion {
            controller.setDSHVersion(version)
        } else {
            prefetchDSHVersion()
            // 后台轮询等待版本预取完成，就绪后刷新面板
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak controller] in
                guard let self = self, let controller = controller else { return }
                let deadline = Date().addingTimeInterval(20)
                while self.cachedDSHVersion == nil && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.3)
                }
                DispatchQueue.main.async {
                    controller.setDSHVersion(self.cachedDSHVersion ?? "未知")
                    logToFile("About 显示 dsh 版本: \(self.cachedDSHVersion ?? "未知")")
                }
            }
        }
    }

    /// 在 dsh 启动成功后异步预取一次版本并缓存，之后 About 直接读缓存不再请求
    /// 同时保证只执行一次：已有缓存或正在获取时不重复触发
    func prefetchDSHVersion() {
        if cachedDSHVersion != nil { return }
        if isPrefetchingVersion { return }
        isPrefetchingVersion = true

        dshRuntimeVersion { [weak self] version in
            guard let self = self else { return }
            self.cachedDSHVersion = version ?? "未知"
            self.isPrefetchingVersion = false
            logToFile("已预取 dsh 版本: \(self.cachedDSHVersion ?? "未知")")
        }
    }

    /// 运行 `pnpm dlx @deepseek-ai/dsh --version` 获取实际运行的 dsh 版本（与启动走同一环境）
    private func dshRuntimeVersion(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var env = ProcessInfo.processInfo.environment
            let path = env["PATH"] ?? ""
            let extraPath = "\(NSHomeDirectory())/Library/pnpm/bin:/opt/homebrew/bin:/usr/local/bin"
            env["PATH"] = "\(extraPath):\(path)"

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["pnpm", "dlx", "@deepseek-ai/dsh", "--version"]
            proc.environment = env

            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()

            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // 超时保护：首次 dlx 可能下载较慢，20 秒后强制终止
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                if proc.isRunning { proc.terminate() }
            }

            proc.waitUntilExit()

            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            // 取最后一行非空、非 pnpm 进度/日志的输出作为版本号
            let version = lines.last(where: {
                !$0.isEmpty &&
                !$0.hasPrefix("Packages:") &&
                !$0.hasPrefix("Progress:") &&
                !$0.hasPrefix("Done in")
            })

            DispatchQueue.main.async {
                completion(version)
            }
        }
    }

    // MARK: 端口检测

    /// 快速检测 dsh 是否已在运行（端口 LISTEN 状态）
    func isPortOpen() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-i", ":3080", "-s", "TCP:LISTEN"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return !data.isEmpty
    }

    /// 等待 dsh HTTP 就绪（确认能正常响应请求后才返回）
    func waitForPort(timeout: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        let url = URL(string: DSH_URL)!

        while Date() < deadline {
            let sema = DispatchSemaphore(value: 0)
            var ready = false

            let task = URLSession.shared.dataTask(with: url) { _, resp, err in
                if let httpResp = resp as? HTTPURLResponse, err == nil {
                    ready = (200..<400).contains(httpResp.statusCode)
                }
                sema.signal()
            }
            task.resume()

            _ = sema.wait(timeout: .now() + 2)
            task.cancel()

            if ready { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    // MARK: 手动启动

    static func launch() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)  // 显示在 dock
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

// ─── 自定义“关于”面板 ────────────────────────────────────────
/// 无边框圆角毛玻璃面板：居中应用图标 + 版本文案，参照原 About 对话框保留“好”按钮
final class AboutPanelController: NSObject {
    private let panel: NSPanel
    private let versionLabel: NSTextField
    private let launcherVersion: String
    private var eventMonitor: Any?

    init(launcherVersion: String) {
        self.launcherVersion = launcherVersion
        versionLabel = NSTextField(labelWithString: "v\(launcherVersion)(dsh v获取中…)")

        // 毛玻璃视图：材质渲染不随自身 layer 的 masksToBounds 裁剪（macOS 12 上会画出直角），
        // 因此圆角+裁剪放到外层普通容器视图上，由父层裁剪子视图（含毛玻璃材质）保证圆角边框
        let content = NSVisualEffectView()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active

        // 普通容器视图承载圆角裁剪，作为面板 contentView；毛玻璃视图填满容器
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let panelSize = NSSize(width: 320, height: 240)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.contentView = container
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true  // 失焦自动隐藏

        super.init()

        // 应用图标（带 macOS 标准圆角比例）
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        let iconSize: CGFloat = 92
        iconView.layer?.cornerRadius = iconSize * 0.2237
        iconView.layer?.masksToBounds = true

        // 应用标题
        let titleLabel = NSTextField(labelWithString: "dsh-app")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        // 版本文案：v<launcher>(dsh v<dsh>)，等宽数字便于与系统版本信息对齐
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center

        let stack = NSStackView(views: [iconView, titleLabel, versionLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: iconView)
        stack.setCustomSpacing(10, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // “好”按钮：回车可触发，点击关闭面板
        let okButton = NSButton(title: "确定", target: self, action: #selector(okClicked(_:)))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        content.addSubview(okButton)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            okButton.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            okButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            okButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])

        panel.center()

        // ESC 关闭
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.panel.isVisible == true {
                self?.panel.close()
                return nil
            }
            return event
        }
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 刷新版本文案（主线程调用）
    func setDSHVersion(_ version: String) {
        versionLabel.stringValue = "v\(launcherVersion)(dsh v\(version))"
    }

    @objc private func okClicked(_ sender: Any?) {
        panel.close()
    }
}

// ─── 入口 ───────────────────────────────────────────────────
logToFile("=== 日志开始 ===")
AppDelegate.launch()
