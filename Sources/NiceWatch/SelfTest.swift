import Foundation

/// 无界面自检模式：`NiceWatch --selftest`
/// 在终端里直接验证接口层是否工作，不依赖 UI。
enum SelfTest {

    static func run() {
        let sem = DispatchSemaphore(value: 0)
        Task {
            await main()
            sem.signal()
        }
        sem.wait()
    }

    /// 风控退避行为测试：验证指数递增与封顶，以及成功清零
    static func backoffTest() {
        line("=== 风控退避测试 ===")
        let expected: [(Int, TimeInterval, String)] = [
            (1, 600, "10 分钟"),
            (2, 1800, "30 分钟"),
            (3, 7200, "2 小时"),
            (4, 21600, "6 小时"),
            (5, 21600, "6 小时（封顶）"),
            (99, 21600, "6 小时（封顶）"),
        ]
        var allOK = true
        for (attempt, want, label) in expected {
            let got = AppModel.backoffDelay(forAttempt: attempt)
            if got == want {
                ok("第 \(attempt) 次失败 → \(label)")
            } else {
                bad("第 \(attempt) 次失败 → 期望 \(Int(want))s，实际 \(Int(got))s")
                allOK = false
            }
        }
        if AppModel.backoffDelay(forAttempt: 0) == 0 {
            ok("0 次失败 → 不退避")
        } else {
            bad("0 次失败应返回 0")
            allOK = false
        }
        line(allOK ? "全部通过" : "存在失败项")
        line("=== 测试结束 ===")
    }

    /// 持久化回归测试：写入 → 重新从磁盘读取 → 校验字段是否完整
    static func storeRoundtrip() {
        line("=== 持久化回归测试 ===")
        let probeName = "__roundtrip_probe__"

        let store1 = Store()
        // 快照用户真实设置，测试结束后必须原样还原
        let originalBarkKey = store1.data.settings.barkKey
        store1.data.ups.removeAll { $0.name == probeName }
        store1.data.ups.append(
            MonitoredUP(mid: -999_000_001,
                        name: probeName,
                        face: "",
                        baselinePubdate: 1_700_000_000)
        )
        store1.data.settings.barkKey = "__probe_key__"
        store1.save()
        ok("已写入探针数据")

        let store2 = Store()
        guard let up = store2.data.ups.first(where: { $0.name == probeName }) else {
            bad("重新读取后找不到探针 UP —— 数据丢失！")
            return
        }
        ok("UP 记录保留：mid=\(up.mid) baseline=\(up.baselinePubdate)")
        if up.baselinePubdate == 1_700_000_000 {
            ok("baselinePubdate 数值正确")
        } else {
            bad("baselinePubdate 不正确：\(up.baselinePubdate)")
        }
        if up.addedAt.timeIntervalSince1970 > 1_600_000_000 {
            ok("addedAt 日期正确")
        } else {
            bad("addedAt 日期异常：\(up.addedAt)")
        }
        if store2.data.settings.barkKey == "__probe_key__" {
            ok("设置项保留")
        } else {
            bad("设置项丢失：'\(store2.data.settings.barkKey ?? "nil")'")
        }

        // 清理探针，并还原用户真实设置
        let store3 = Store()
        store3.data.ups.removeAll { $0.name == probeName }
        store3.data.settings.barkKey = originalBarkKey
        store3.save()
        if store3.data.settings.barkKey == originalBarkKey {
            ok("已还原用户原有设置")
        } else {
            bad("还原设置失败，请检查 barkKey")
        }
        line("=== 回归测试结束 ===")
    }

    private static func line(_ s: String) {
        print(s)
        fflush(stdout)
    }

    private static func ok(_ s: String) { line("  ✓ " + s) }
    private static func bad(_ s: String) { line("  ✗ " + s) }

    private static func main() async {
        let client = BiliClient.shared
        line("=== NiceWatch 自检 ===")

        // 1. 二维码生成
        line("\n[1] 二维码生成")
        do {
            let gen = try await client.qrGenerate()
            ok("qrcode_key = \(gen.qrcodeKey.prefix(12))…")
            ok("url 长度 = \(gen.url.count)")
            if let img = QRCode.image(from: gen.url) {
                ok("二维码图片生成成功 \(Int(img.size.width))x\(Int(img.size.height))")
            } else {
                bad("二维码图片生成失败（CIQRCodeGenerator 返回 nil）")
            }
        } catch {
            bad("失败：\(error.localizedDescription)")
        }

        // 2. 载入已有会话
        line("\n[2] 载入探测脚本的登录态")
        let sessionPath = FileManager.default.currentDirectoryPath + "/tools/.bili_session.json"
        var loaded = false
        if let raw = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
           let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let cookies = obj["cookies"] as? [String: String] {
            client.loadCookies(cookies)
            ok("已载入 \(cookies.count) 个 cookie")
            loaded = true
        } else {
            bad("读不到 \(sessionPath)")
        }

        guard loaded else {
            line("\n跳过后续接口测试")
            return
        }

        await client.warmFingerprint()

        // 3. 账号
        line("\n[3] 账号信息")
        var myMid: Int64 = 0
        do {
            if let info = try await client.nav() {
                ok("已登录 \(info.uname) (UID \(info.mid))")
                myMid = info.mid
            } else {
                bad("nav 返回未登录")
            }
        } catch {
            bad("失败：\(error.localizedDescription)")
        }

        // 4. 关注列表
        line("\n[4] 关注列表")
        var firstMid: (Int64, String) = (0, "")
        do {
            let (list, total) = try await client.followings(vmid: myMid, page: 1, pageSize: 20)
            ok("共 \(total) 个关注，本页 \(list.count) 个")
            if let f = list.first { firstMid = (f.mid, f.uname ?? "") }
        } catch {
            bad("失败：\(error.localizedDescription)")
        }

        // 5. 动态 feed
        line("\n[5] 关注动态 feed（主通道）")
        do {
            let items = try await client.dynamicVideoFeed()
            ok("拿到 \(items.count) 条视频动态")
            for v in items.prefix(3) {
                line("      · \(v.bvid) \(v.author)：\(v.title.prefix(24))")
            }
        } catch {
            bad("失败：\(error.localizedDescription)")
        }

        // 6. 单个 UP 投稿列表
        line("\n[6] 投稿列表（兜底通道）")
        if firstMid.0 != 0 {
            do {
                let vids = try await client.spaceVideos(mid: firstMid.0, pageSize: 5)
                ok("\(firstMid.1) 返回 \(vids.count) 条投稿")
                if let v = vids.first {
                    line("      · \(v.bvid) \(v.title.prefix(30))")
                }
            } catch {
                bad("失败：\(error.localizedDescription)")
            }
        }

        // 7. Bark 配置
        line("\n[7] Bark 通知配置")
        let st = Store()
        if let k = st.data.settings.barkKey, !k.isEmpty {
            ok("已配置 Bark key：\(k.prefix(6))…（共 \(k.count) 位）")
        } else {
            bad("尚未填写 Bark key")
        }

        line("\n=== 自检结束 ===")
    }
}
