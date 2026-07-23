import Foundation
import SwiftUI

@MainActor
final class ContentViewModel: ObservableObject {
    @Published var sourceGroups: [SourceGroup] = []
    @Published var items: [ContentItem] = []
    @Published var selectedSource: String? = nil   // nil = 全部
    @Published var selectedItem: ContentItem? = nil
    @Published var minScore: Int = 0               // 评分筛选 0=不限
    @Published var totalCount: Int = 0
    @Published var showTranslated: Bool = false    // 阅读区显示原文/翻译

    private let db = Database.shared

    init() {
        // 评分/翻译完成后刷新列表与当前选中项
        NotificationCenter.default.addObserver(
            forName: .contentUpdated, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentId = self.selectedItem?.id
                self.reload()
                if let cid = currentId {
                    self.selectedItem = self.items.first { $0.id == cid }
                }
            }
        }
    }

    func loadAll() {
        totalCount = db.totalCount()
        sourceGroups = db.fetchSourceGroups()
        reload()
    }

    func reload() {
        let minS: Int? = minScore > 0 ? minScore : nil
        items = db.fetchContents(source: selectedSource, minScore: minS, limit: 300)
        if let sel = selectedItem, !items.contains(sel) {
            selectedItem = nil
        }
    }

    func selectSource(_ source: String?) {
        selectedSource = source
        reload()
    }
}
