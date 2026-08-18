import Cocoa

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
class AppDelegate: NSObject, NSApplicationDelegate {

    let DSH_URL = "http://127.0.0.1:3080"
    var dshProcess: Process?
    var browserOpenedAt: Date?

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        logToFile("=== App 启动 ===")

        // 监听 Chrome / PWA 退出
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        startDSH()
    }

    // MARK: 启动 dsh

    func startDSH() {
        if isPortOpen() {
            logToFile("端口 3080 已被占用")
            openBrowser()
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
            logToFile("dsh 进程退出，自动终止")
            DispatchQueue.main.async { exit(0) }
        }

        dshProcess = proc

        DispatchQueue.global().async {
            do {
                try proc.run()
                logToFile("pnpx 已启动 (PID: \(proc.processIdentifier))")

                let started = self.waitForPort(timeout: 120)
                if started {
                    logToFile("端口就绪")
                    DispatchQueue.main.async { self.openBrowser() }
                } else {
                    logToFile("端口等待超时")
                }
            } catch {
                logToFile("启动失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Chrome 窗口关闭时立即终止

    @objc func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else { return }

        // 只关心 --app 窗口/PWA 进程（com.google.Chrome.app.xxx），不关心 Chrome 主进程
        guard bundleId.hasPrefix("com.google.Chrome.app.") else { return }

        // 忽略启动后 2 秒内的进程退出（Chrome --app 初始化时的临时进程）
        if let opened = browserOpenedAt, Date().timeIntervalSince(opened) < 2 { return }

        logToFile("Chrome 窗口已关闭，自动终止")
        self.dshProcess?.terminate()
        // exit(0) 强制退出，确保 Dock 图标立即消失
        exit(0)
    }

    // MARK: 打开浏览器

    func openBrowser() {
        browserOpenedAt = Date()

        // 1. 优先找 Chrome 安装的 PWA App
        if let app = findInstalledChromeApp() {
            logToFile("找到 Chrome PWA: \(app.path)")
            NSWorkspace.shared.open(app)
            startConnectionMonitor()
            return
        }

        // 2. 未安装 PWA，用默认浏览器打开（之后用户可手动安装 PWA）
        logToFile("未找到 PWA，使用默认浏览器")
        if let url = URL(string: DSH_URL) {
            NSWorkspace.shared.open(url)
        }
        startConnectionMonitor()
    }

    // MARK: 连接监控（--app 模式关闭窗口不会退出 Chrome，靠这个兜底）

    var monitorTimer: Timer?

    func startConnectionMonitor() {
        // 每 2 秒检查一次，连续 2 次无连接（~4 秒）则退出
        var idleCount = 0
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let connections = self.activeConnections()
            if connections > 0 {
                idleCount = 0
            } else {
                idleCount += 1
                if idleCount >= 2 {
                    logToFile("Chrome 窗口已关闭，自动终止")
                    self.monitorTimer?.invalidate()
                    self.dshProcess?.terminate()
                    exit(0)
                }
            }
        }
    }

    /// 统计端口 3080 上的 ESTABLISHED 连接数
    func activeConnections() -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-i", ":3080", "-s", "TCP:ESTABLISHED"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()  // 丢弃 stderr 错误信息
        try? task.run()
        task.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let lines = output.split(separator: "\n").filter { !$0.isEmpty }
        return max(0, lines.count - 1)  // 减去标题行
    }

    func findInstalledChromeApp() -> URL? {
        let chromeAppsDir = NSHomeDirectory() + "/Applications/Chrome Apps.localized"
        guard FileManager.default.fileExists(atPath: chromeAppsDir),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: chromeAppsDir) else { return nil }

        for item in contents where item.hasSuffix(".app") {
            let name = (item as NSString).deletingPathExtension.lowercased()
            if name.contains("deepseek") || name.contains("dsh") || name.contains("localhost") {
                return URL(fileURLWithPath: chromeAppsDir + "/" + item)
            }
        }
        return nil
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