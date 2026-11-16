import Foundation

/// 会话（cookie）持久化。
///
/// 存储位置：应用自己的数据目录 `~/Library/Application Support/NiceWatch/`
/// 存储格式：`session.bin`，AES-GCM 加密（见 SessionCrypto），文件权限 0600。
///
/// 明确不使用系统钥匙串：本应用以 ad-hoc 方式签名，每次重新构建签名身份都会变化，
/// 钥匙串 ACL 与旧身份绑定，会导致读取时阻塞等待授权，表现为「启动卡几十秒 + 登录态丢失」。
enum SessionStore {

    private static var fileURL: URL {
        AppLog.dirURL.appendingPathComponent("session.bin")
    }

    /// 旧版本的明文会话文件（仅用于迁移）
    private static var legacyURL: URL {
        AppLog.dirURL.appendingPathComponent("session.json")
    }

    static func save(_ cookies: [String: String]) {
        guard !cookies.isEmpty else { return }
        do {
            let json = try JSONEncoder().encode(cookies)
            guard let sealed = SessionCrypto.seal(json) else {
                AppLog.info("会话加密失败，本次不落盘")
                return
            }
            try sealed.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            AppLog.info("会话已加密保存（\(cookies.count) 个 cookie，\(sealed.count) 字节）")
        } catch {
            AppLog.info("写会话文件失败：\(error.localizedDescription)")
        }
    }

    static func load() -> [String: String] {
        if let sealed = try? Data(contentsOf: fileURL) {
            if let json = SessionCrypto.open(sealed),
               let cookies = try? JSONDecoder().decode([String: String].self, from: json),
               !cookies.isEmpty {
                AppLog.info("从加密文件恢复会话（\(cookies.count) 个 cookie）")
                return cookies
            }
            AppLog.info("会话文件存在但无法解密（可能换了机器或文件损坏），需要重新登录")
            return [:]
        }

        // 迁移：早期版本把 cookie 明文写在 session.json 里
        if let data = try? Data(contentsOf: legacyURL),
           let cookies = try? JSONDecoder().decode([String: String].self, from: data),
           !cookies.isEmpty {
            AppLog.info("发现旧的明文会话文件，迁移为加密存储")
            save(cookies)
            try? FileManager.default.removeItem(at: legacyURL)
            return cookies
        }

        AppLog.info("本地无会话，需要扫码登录")
        return [:]
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: legacyURL)
        AppLog.info("会话已清除")
    }
}
