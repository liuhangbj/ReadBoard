import Foundation
import CryptoKit

/// B站扫码登录 + SESSDATA 管理
/// 登录态存 SecretStore(加密)，UserDefaults 只存"已登录"标记
public enum BilibiliAuth {

    private actor WBIIdentityStore {
        var cached: (cookie: String, mixinKey: String, createdAt: Date)?

        func current(maxAge: TimeInterval) -> (cookie: String, mixinKey: String)? {
            guard let cached, Date().timeIntervalSince(cached.createdAt) < maxAge else { return nil }
            return (cookie: cached.cookie, mixinKey: cached.mixinKey)
        }

        func store(cookie: String, mixinKey: String) {
            cached = (cookie: cookie, mixinKey: mixinKey, createdAt: Date())
        }
    }

    // MARK: - 常量

    private static let sessdataKey = "bilibili.auth.sessdata"
    private static let uidKey = "bilibili.auth.uid"
    private static let unameKey = "bilibili.auth.uname"
    private static let authSetKey = "bilibili.auth.set"

    // MARK: - 登录态查询

    /// 是否已登录（有有效 SESSDATA）
    static var isLoggedIn: Bool {
        UserDefaults.standard.bool(forKey: authSetKey) && sessdata != nil
    }

    /// 当前 SESSDATA（从 SecretStore 读，可能为 nil）
    static var sessdata: String? {
        SecretStore.load(forKey: sessdataKey)
    }

    /// 当前登录用户 UID
    static var uid: String? {
        SecretStore.load(forKey: uidKey)
    }

    /// 当前登录用户昵称
    static var uname: String? {
        SecretStore.load(forKey: unameKey)
    }

    // MARK: - 二维码登录流程

    /// 生成登录二维码，返回 (二维码 URL, qrcode_key)
    static func generateQRCode() async throws -> (url: String, key: String) {
        let url = "https://passport.bilibili.com/x/passport-login/web/qrcode/generate?source=subscription&gaia_vtoken=&local_id=readboard"
        let (data, _) = try await httpGet(url, cookie: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let dataObj = json["data"] as? [String: Any],
              let qrURL = dataObj["url"] as? String,
              let qrKey = dataObj["qrcode_key"] as? String else {
            throw BilibiliError.qrGenerateFailed
        }
        return (qrURL, qrKey)
    }

    /// 轮询扫码状态，返回 SESSDATA 或 nil(未扫/过期)
    static func pollQRCode(key: String) async throws -> String? {
        let url = "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=\(key)"
        let (data, response) = try await httpGet(url, cookie: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int else {
            throw BilibiliError.qrPollFailed
        }
        // 外层 code=0 只表示接口调用成功，真正状态在 data.code
        guard code == 0, let dataObj = json["data"] as? [String: Any] else {
            return nil
        }
        // data.code: 0=扫码成功, 86038=二维码过期, 86090=已扫码未确认, 86101=未扫码
        guard let dataCode = dataObj["code"] as? Int, dataCode == 0 else {
            return nil
        }
        // 扫码成功后，SESSDATA 在 Set-Cookie 响应头里，不在 data.url
        if let sessdata = extractSessdataFromCookie(response: response) {
            return sessdata
        }
        // 兜底：尝试从 data.url 提取（旧版接口可能仍用 url）
        if let sessdata = extractSessdata(from: dataObj) {
            return sessdata
        }
        return nil
    }

    /// 从 Set-Cookie 响应头提取 SESSDATA
    private static func extractSessdataFromCookie(response: HTTPURLResponse) -> String? {
        guard let setCookie = response.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        // Set-Cookie 格式：SESSDATA=xxx; Path=/; Expires=...; HttpOnly; Secure
        let components = setCookie.components(separatedBy: ";")
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SESSDATA=") {
                return String(trimmed.dropFirst("SESSDATA=".count))
            }
        }
        return nil
    }

    /// 从 poll 响应的 data 中提取 SESSDATA
    private static func extractSessdata(from data: [String: Any]) -> String? {
        // data.url 格式：https://passport.bilibili.com/...?SESSDATA=xxx&DedeUserID=yyy&bili_jct=zzz
        guard let urlStr = data["url"] as? String,
              let url = URL(string: urlStr),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        return queryItems.first(where: { $0.name == "SESSDATA" })?.value
    }

    /// 用 SESSDATA 换取用户信息(UID + 昵称)
    static func fetchUserInfo(sessdata: String) async throws -> (uid: String, uname: String) {
        let cookie = "SESSDATA=\(sessdata)"
        let (data, _) = try await httpGet("https://api.bilibili.com/x/web-interface/nav", cookie: cookie)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let dataObj = json["data"] as? [String: Any],
              let isLogin = dataObj["isLogin"] as? Bool, isLogin,
              let mid = dataObj["mid"] as? Int,
              let uname = dataObj["uname"] as? String else {
            throw BilibiliError.userInfoFailed
        }
        return (String(mid), uname)
    }

    /// 保存登录态到 SecretStore + UserDefaults 标记
    static func saveAuth(sessdata: String, uid: String, uname: String) -> Bool {
        let ok1 = SecretStore.save(sessdata, forKey: sessdataKey)
        let ok2 = SecretStore.save(uid, forKey: uidKey)
        let ok3 = SecretStore.save(uname, forKey: unameKey)
        guard ok1 && ok2 && ok3 else { return false }
        UserDefaults.standard.set(true, forKey: authSetKey)
        return true
    }

    /// 清除登录态
    static func clearAuth() {
        _ = SecretStore.delete(forKey: sessdataKey)
        _ = SecretStore.delete(forKey: uidKey)
        _ = SecretStore.delete(forKey: unameKey)
        UserDefaults.standard.set(false, forKey: authSetKey)
    }

    // MARK: - 关注列表

    /// 拉取当前登录用户的关注列表(需 WBI 签名)
    static func fetchFollowings(sessdata: String, uid: String, maxPages: Int = 5) async throws -> [(mid: String, uname: String)] {
        // 先取 buvid3
        let buvid3 = try await fetchBuvid3()
        let cookie = "buvid3=\(buvid3); SESSDATA=\(sessdata)"

        // 取 WBI 签名密钥
        let (navData, _) = try await httpGet("https://api.bilibili.com/x/web-interface/nav", cookie: cookie)
        guard let navJson = try? JSONSerialization.jsonObject(with: navData) as? [String: Any],
              let navDataObj = navJson["data"] as? [String: Any],
              let wbiImg = navDataObj["wbi_img"] as? [String: Any],
              let imgURL = wbiImg["img_url"] as? String,
              let subURL = wbiImg["sub_url"] as? String else {
            throw BilibiliError.wbiKeyFailed
        }
        let imgKey = String(imgURL.split(separator: "/").last?.split(separator: ".").first ?? "")
        let subKey = String(subURL.split(separator: "/").last?.split(separator: ".").first ?? "")
        let mixinKey = generateMixinKey(imgKey: imgKey, subKey: subKey)

        var allFollowings: [(String, String)] = []
        for page in 1...maxPages {
            let params: [String: String] = [
                "vmid": uid,
                "pn": String(page),
                "ps": "50",
                "web_location": "333.1387"
            ]
            let signedQuery = wbiSign(params: params, mixinKey: mixinKey)
            let url = "https://api.bilibili.com/x/relation/followings?\(signedQuery)"
            let (data, _) = try await httpGet(url, cookie: cookie)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["code"] as? Int, code == 0,
                  let dataObj = json["data"] as? [String: Any],
                  let list = dataObj["list"] as? [[String: Any]] else {
                // 第一页失败抛错，后续页失败返回已收集的
                if page == 1 { throw BilibiliError.followingsFailed }
                break
            }
            let pageItems = list.compactMap { item -> (String, String)? in
                guard let mid = item["mid"] as? Int,
                      let uname = item["uname"] as? String else { return nil }
                return (String(mid), uname)
            }
            allFollowings.append(contentsOf: pageItems)
            // 不足一页说明到底了
            if pageItems.count < 50 { break }
        }
        return allFollowings
    }

    // MARK: - WBI 签名

    private static let wbiIdentityStore = WBIIdentityStore()

    /// 为必须绑定当前登录设备的 WBI 接口生成签名 URL 与配套 Cookie。
    /// URL 和 Cookie 必须成对使用，避免把 SESSDATA 与另一个临时设备指纹混用。
    static func signedWBIRequest(
        path: String,
        params: [String: String],
        sessdata: String
    ) async throws -> (url: String, cookie: String) {
        let identity = try await wbiIdentity(sessdata: sessdata)
        let query = wbiSign(params: params, mixinKey: identity.mixinKey)
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return ("https://api.bilibili.com\(normalizedPath)?\(query)", identity.cookie)
    }

    /// 生成 B站移动端投稿接口请求。Web 动态流和 WBI 投稿列表可能同时被
    /// -352/HTTP 412 风控拦截，移动端使用独立的 App 签名，可作为只读降级路径。
    static func signedAppArchiveRequest(
        params: [String: String],
        sessdata: String
    ) throws -> URLRequest {
        let appKey = "dfca71928277209b"
        let appSecret = "b5475a8825547a4fc26c7d518eaaa02e"
        var allParams = params
        allParams["appkey"] = appKey
        allParams["mobi_app"] = "android_hd"
        allParams["platform"] = "android"
        allParams["ts"] = String(Int(Date().timeIntervalSince1970))

        let unsignedQuery = appQuery(allParams)
        allParams["sign"] = md5(unsignedQuery + appSecret)
        let query = appQuery(allParams)
        guard let url = URL(
            string: "https://app.biliapi.com/x/v2/space/archive/cursor?\(query)"
        ) else {
            throw BilibiliError.badURL
        }
        var request = URLRequest(url: url)
        request.setValue(
            "bili-universal/103300 (iPhone; iOS 18.2; Scale/3.00)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("SESSDATA=\(sessdata)", forHTTPHeaderField: "Cookie")
        return request
    }

    private static func appQuery(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }.map { key, value in
            "\(appPercentEncode(key))=\(appPercentEncode(value))"
        }.joined(separator: "&")
    }

    private static func appPercentEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// WBI 设备指纹与签名密钥缓存。批量回填时不能逐条重新取 buvid3/nav，
    /// 否则 4,000 条历史视频会制造数倍无意义请求。
    private static func wbiIdentity(sessdata: String) async throws -> (cookie: String, mixinKey: String) {
        if let cached = await wbiIdentityStore.current(maxAge: 3_600) {
            return cached
        }

        let buvid3 = try await fetchBuvid3()
        let cookie = "buvid3=\(buvid3); SESSDATA=\(sessdata)"
        let (navData, _) = try await httpGet(
            "https://api.bilibili.com/x/web-interface/nav",
            cookie: cookie
        )
        guard let navJson = try? JSONSerialization.jsonObject(with: navData) as? [String: Any],
              let navDataObj = navJson["data"] as? [String: Any],
              let wbiImg = navDataObj["wbi_img"] as? [String: Any],
              let imgURL = wbiImg["img_url"] as? String,
              let subURL = wbiImg["sub_url"] as? String else {
            throw BilibiliError.wbiKeyFailed
        }
        let imgKey = String(imgURL.split(separator: "/").last?.split(separator: ".").first ?? "")
        let subKey = String(subURL.split(separator: "/").last?.split(separator: ".").first ?? "")
        let mixinKey = generateMixinKey(imgKey: imgKey, subKey: subKey)

        await wbiIdentityStore.store(cookie: cookie, mixinKey: mixinKey)
        return (cookie: cookie, mixinKey: mixinKey)
    }

    private static func generateMixinKey(imgKey: String, subKey: String) -> String {
        let table = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,
                     37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
        let orig = imgKey + subKey
        let origArray = Array(orig)
        var mixin = ""
        for i in table.prefix(32) {
            mixin.append(origArray[i])
        }
        return mixin
    }

    private static func wbiSign(params: [String: String], mixinKey: String) -> String {
        var p = params
        p["wts"] = String(Int(Date().timeIntervalSince1970))
        let items = p.sorted { $0.key < $1.key }.map { key, value in
            // 过滤 !'()* 字符
            let filtered = value.replacingOccurrences(of: "!", with: "")
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "*", with: "")
            return "\(key)=\(filtered)"
        }
        let query = items.joined(separator: "&")
        let wrid = md5(query + mixinKey)
        return query + "&w_rid=" + wrid
    }

    private static func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - buvid3

    private static func fetchBuvid3() async throws -> String {
        let (data, _) = try await httpGet("https://api.bilibili.com/x/frontend/finger/spi", cookie: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let dataObj = json["data"] as? [String: Any],
              let buvid3 = dataObj["b_3"] as? String else {
            throw BilibiliError.buvid3Failed
        }
        return buvid3
    }

    // MARK: - HTTP 工具

    private static func httpGet(_ urlString: String, cookie: String?) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let url = URL(string: urlString) else { throw BilibiliError.badURL }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BilibiliError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return (data, http)
    }
}

// MARK: - 错误

public enum BilibiliError: Error, LocalizedError {
    case badURL
    case httpError(Int)
    case apiError(Int, String)
    case loginRequired
    case qrGenerateFailed
    case qrPollFailed
    case userInfoFailed
    case wbiKeyFailed
    case buvid3Failed
    case followingsFailed

    public var errorDescription: String? {
        switch self {
        case .badURL: return "无效的 URL"
        case .httpError(let c): return "HTTP 错误 \(c)"
        case .apiError(let code, let message): return "B站接口错误 \(code)：\(message)"
        case .loginRequired: return "B站登录态不可用，请重新扫码登录"
        case .qrGenerateFailed: return "生成二维码失败"
        case .qrPollFailed: return "轮询扫码状态失败"
        case .userInfoFailed: return "获取用户信息失败"
        case .wbiKeyFailed: return "获取 WBI 签名密钥失败"
        case .buvid3Failed: return "获取 buvid3 失败"
        case .followingsFailed: return "获取关注列表失败"
        }
    }
}
