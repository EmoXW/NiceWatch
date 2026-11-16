import Foundation
import CryptoKit

/// 会话文件的加密层。
///
/// 需求：登录态只存在应用自己的目录里，不使用系统钥匙串。
/// 做法：AES-GCM 对称加密，密钥由「本机硬件标识 + 应用固定盐」经 HKDF-SHA256 派生。
///
/// 安全边界（据实说明，不夸大）：
/// - 能防住：别人翻看 ~/Library/Application Support/NiceWatch/ 时看不到明文 cookie，
///   把文件拷到另一台机器上也解不开（密钥随机器变化）。
/// - 不能防住：已经能在本机以你的身份任意执行代码的攻击者——
///   他能跑同样的派生流程。对自用的监控小工具而言这是合理取舍。
enum SessionCrypto {

    private static let salt = Data("NiceWatch.Session.v1.salt".utf8)
    private static let info = Data("NiceWatch.Session.v1.info".utf8)

    /// 本机硬件 UUID（随机器变化，因此拷贝走文件也解不开）
    private static let machineID: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            // 形如：    "IOPlatformUUID" = "5F2C1B44-...."
            if let range = text.range(of: "\"IOPlatformUUID\" = \"") {
                let rest = text[range.upperBound...]
                if let end = rest.firstIndex(of: "\"") {
                    let uuid = String(rest[..<end])
                    if !uuid.isEmpty { return uuid }
                }
            }
        } catch {
            // 落到下面的兜底
        }
        // 兜底：退化为固定标识（仍然可用，只是不再具有「换机失效」特性）
        return "nicewatch-fallback-machine"
    }()

    private static let key: SymmetricKey = {
        let material = SymmetricKey(data: Data(machineID.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }()

    static func seal(_ plaintext: Data) -> Data? {
        guard let sealed = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        return sealed.combined
    }

    static func `open`(_ ciphertext: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
