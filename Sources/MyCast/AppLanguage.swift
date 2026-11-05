import Foundation

/// 用户可选的界面语言。未保存偏好时，根据 macOS 的首选语言选择。
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static var preferred: AppLanguage {
        let identifier = Bundle.preferredLocalizations(from: allCases.map(\.rawValue),
                                                       forPreferences: Locale.preferredLanguages).first
        return identifier.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    var title: String { text("English", "简体中文") }

    func text(_ english: String, _ chinese: String) -> String {
        self == .english ? english : chinese
    }
}

/// 保留两种诊断文案，让已经记录的消息也能随界面语言切换。
struct AppMessage: Equatable {
    /// 英文文案，也用于只提供原始文本的系统或播放器错误。
    let english: String
    /// 简体中文文案。
    let chinese: String

    init(_ english: String, _ chinese: String? = nil) {
        self.english = english
        self.chinese = chinese ?? english
    }

    func text(in language: AppLanguage) -> String { language.text(english, chinese) }
}
