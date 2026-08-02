import SwiftUI
import CoreImage.CIFilterBuiltins

/// B站扫码登录弹窗
/// 流程：生成二维码 → 用户手机扫码 → 轮询确认 → 拿 SESSDATA → 存 SecretStore
struct BilibiliQRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: NSImage? = nil
    @State private var qrcodeKey: String? = nil
    @State private var statusText = "正在生成二维码..."
    @State private var isPolling = false
    @State private var pollTask: Task<Void, Never>? = nil

    let onLoginSuccess: (String) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("扫码登录 BiliBili")
                .font(.title2)
                .fontWeight(.semibold)

            if let qrImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .cornerRadius(8)
            } else {
                ProgressView()
                    .frame(width: 200, height: 200)
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(Color.rbText2)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("取消") {
                    pollTask?.cancel()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.rbText2)

                if qrcodeKey != nil && !isPolling {
                    Button("刷新二维码") {
                        Task { await generateQRCode() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.rbAccent)
                }
            }
        }
        .padding(24)
        .frame(width: 320, height: 380)
        .task {
            await generateQRCode()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private func generateQRCode() async {
        statusText = "正在生成二维码..."
        Trace.i("开始生成二维码", category: "bilibili")
        do {
            let (url, key) = try await BilibiliAuth.generateQRCode()
            qrcodeKey = key
            qrImage = generateQRImage(from: url)
            statusText = "请用手机 BiliBili App 扫码"
            Trace.i("二维码生成成功 qrcode_key=\(key)", category: "bilibili")
            startPolling(key: key)
        } catch {
            statusText = "生成失败：\(error.localizedDescription)"
            Trace.e("二维码生成失败: \(error.localizedDescription)", category: "bilibili")
        }
    }

    private func startPolling(key: String) {
        isPolling = true
        Trace.i("开始轮询扫码状态 qrcode_key=\(key)", category: "bilibili")
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 秒轮询
                guard !Task.isCancelled else { break }
                do {
                    if let sessdata = try await BilibiliAuth.pollQRCode(key: key) {
                        Trace.i("检测到扫码成功，SESSDATA 长度: \(sessdata.count)", category: "bilibili")
                        await handleLoginSuccess(sessdata: sessdata)
                        break
                    } else {
                        Trace.i("轮询中... 未扫码", category: "bilibili")
                    }
                } catch {
                    Trace.e("轮询失败: \(error.localizedDescription)", category: "bilibili")
                    statusText = "轮询失败：\(error.localizedDescription)"
                    break
                }
            }
            isPolling = false
        }
    }

    private func handleLoginSuccess(sessdata: String) async {
        statusText = "登录成功，正在获取用户信息..."
        Trace.i("handleLoginSuccess 开始", category: "bilibili")
        do {
            let (uid, uname) = try await BilibiliAuth.fetchUserInfo(sessdata: sessdata)
            Trace.i("获取用户信息成功: \(uname) (UID: \(uid))", category: "bilibili")
            let ok = BilibiliAuth.saveAuth(sessdata: sessdata, uid: uid, uname: uname)
            if ok {
                statusText = "登录成功：\(uname)"
                Trace.i("登录态保存成功，1 秒后关闭弹窗", category: "bilibili")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                onLoginSuccess(uname)
                dismiss()
                Trace.i("弹窗已关闭", category: "bilibili")
            } else {
                statusText = "保存登录态失败"
                Trace.e("登录态保存失败", category: "bilibili")
            }
        } catch {
            statusText = "获取用户信息失败：\(error.localizedDescription)"
            Trace.e("获取用户信息失败: \(error.localizedDescription)", category: "bilibili")
        }
    }

    private func generateQRImage(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 200, height: 200))
    }
}
