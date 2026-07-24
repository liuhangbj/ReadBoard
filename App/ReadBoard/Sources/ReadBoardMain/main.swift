// 可执行入口：仅转发到库里的 ReadBoardApp。
// 独立成 mini-target 是为了让库 target 无 @main——否则测试 runner 的 main 会撞符号。
import ReadBoard

@main
enum Entry {
    static func main() {
        ReadBoardApp.main()
    }
}
