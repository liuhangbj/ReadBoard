import SwiftUI
import CoreImage.CIFilterBuiltins
import ReadBoardContract

/// B站扫码登录弹窗
/// 流程：生成二维码 → 用户手机扫码 → 轮询确认 → 拿 SESSDATA → 存 SecretStore
struct BilibiliQRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: NSImage? = nil
    @State private var qrcodeKey: String? = nil
    @State private var statusText = "正在生成二维码..."
    @State private var isPolling = false
    @State private var pollTask: Task<Void, Never>? = nil
    private let authentication: any AuthenticationGateway

    let onLoginSuccess: (String) -> Void

    init(authentication: any AuthenticationGateway, onLoginSuccess: @escaping (String) -> Void) {
        self.authentication = authentication; self.onLoginSuccess = onLoginSuccess
    }

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
            let challenge = try await authentication.beginAuthentication(platformID: "bilibili")
            qrcodeKey = challenge.challengeID
            qrImage = generateQRImage(from: challenge.qrPayload)
            statusText = "请用手机 BiliBili App 扫码"
            Trace.i("二维码生成成功", category: "bilibili")
            startPolling(key: challenge.challengeID)
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
                    let result = try await authentication.pollAuthentication(
                        platformID: "bilibili", challengeID: key)
                    statusText = result.status.message ?? "等待扫码…"
                    if result.completed {
                        onLoginSuccess(result.status.accountName ?? "BiliBili 用户")
                        dismiss()
                        break
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
