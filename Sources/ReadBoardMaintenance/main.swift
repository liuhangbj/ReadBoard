import Foundation
import ReadBoard

@main
struct ReadBoardMaintenance {
    static func main() async {
        let supportName = ProcessInfo.processInfo.environment["READBOARD_APPLICATION_SUPPORT_NAME"]
            ?? "ReadBoard Pro Beta"
        setenv("READBOARD_APPLICATION_SUPPORT_NAME", supportName, 1)
        _ = await BilibiliAccessBackfill.run()
    }
}
