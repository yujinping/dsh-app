import Cocoa
import WebKit

// ─── 日志 ───────────────────────────────────────────────────
let LOG_PATH = "/tmp/dsh-launcher.log"

func logToFile(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
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
class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {

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
        window.title = "DeepSeek Harness"
        window.center()
        window.setFrameAutosaveName("DSHMainWindow")
        window.isReleasedWhenClosed = false

        let container = NSView(frame: contentRect)

        // 内嵌 WebView：随窗口伸缩
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // 持久化存储，保留登录态等
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
        showLoading("正在启动 DeepSeek Harness…", spinner: true)

        // 端口已被占用（可能残留或手动启动过），直接加载
        if isPortOpen() {
            logToFile("端口 3080 已被占用，直接加载")
            loadDSH()
            return
        }

        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        let extraPath = "\(NSHomeDirectory())/Library/pnpm/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = "\(extraPath):\(path)"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["pnpx", "@deepseek-ai/dsh", "web"]
        proc.environment = env

        proc.terminationHandler = { _ in
            logToFile("dsh 进程退出")
        }

        dshProcess = proc
        startedDSHProcess = true

        DispatchQueue.global().async {
            do {
                try proc.run()
                logToFile("pnpx 已启动 (PID: \(proc.processIdentifier))")

                let started = self.waitForPort(timeout: 120)
                guard !self.isQuitting else { return }

                DispatchQueue.main.async {
                    if started {
                        logToFile("端口就绪，加载页面")
                        self.loadDSH()
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

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideLoading()
        window.title = webView.title ?? "DeepSeek Harness"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoading("加载失败：\(error.localizedDescription)", spinner: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
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
            logToFile("终止 pnpx 进程 (PID: \(proc.processIdentifier))")
            if proc.isRunning { proc.terminate() }
            dshProcess = nil
        }
        // 兜底：pnpx 退出后子进程可能残留，按端口把真正监听的 server 停掉
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
        appMenu.addItem(withTitle: "关于 DeepSeek Harness",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DeepSeek Harness",
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

// ─── 入口 ───────────────────────────────────────────────────
logToFile("=== 日志开始 ===")
AppDelegate.launch()