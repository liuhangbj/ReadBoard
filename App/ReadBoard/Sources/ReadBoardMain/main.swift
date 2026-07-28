// 可执行入口：仅转发到库里的 ReadBoardApp。
// 独立成 mini-target 是为了让库 target 无 @main——否则测试 runner 的 main 会撞符号。
import Darwin
import ReadBoard

@main
enum Entry {
    static func main() {
        // 在任何 Swift/Foundation 初始化之前忽略 SIGPIPE。
        // URLSession/Network 在沙箱/VPN/代理环境下 write() 到已关闭的 socket
        // 会触发 SIGPIPE，默认行为是杀进程。
        signal(SIGPIPE, SIG_IGN)
        ReadBoardApp.main()
    }
}
