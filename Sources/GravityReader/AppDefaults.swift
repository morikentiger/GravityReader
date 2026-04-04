import Foundation

/// アプリ専用の UserDefaults suite（他アプリとのキー衝突を防ぐ）
enum AppDefaults {
    static let suite = UserDefaults(suiteName: "com.gravityreader.app.settings")!

    /// UserDefaults.standard から suite への一回限りマイグレーション
    static func migrateFromStandardIfNeeded() {
        let migrationKey = "GR_MigratedToSuite"
        guard !suite.bool(forKey: migrationKey) else { return }

        let keysToMigrate = [
            "YUiOpenAIAPIKey",
            "YUiUseMinModel",
            "YUiFrequency",
            "YUiLonelinessEnabled",
            "YUiAizuchiEnabled",
            "YUiMemoryDuration",
            "YUiPersonality_responseFrequency",
            "YUiPersonality_dialogueStance",
            "YUiPersonality_attitude",
            "YUiPersonality_autoMode",
            "GR_VoiceMode",
            "GR_VoicevoxURL",
            "GR_SpeechRate",
            "GR_UserVoiceMap",
            "GR_ReadingDictionary",
            "GR_NotificationRules",
        ]

        let standard = UserDefaults.standard
        for key in keysToMigrate {
            if let value = standard.object(forKey: key) {
                suite.set(value, forKey: key)
            }
        }

        suite.set(true, forKey: migrationKey)
        NSLog("[GR] UserDefaults migration to suite completed")
    }
}
