// Standalone SwiftUI design preview. Does not request or change OS permissions.
// Run: swift docs/prototypes/permissions-preview.swift <output-directory>
import AppKit
import SwiftUI

struct PermissionsPreview: View {
    enum Stage: String, CaseIterable {
        case microphone = "permissions"
        case accessibility = "permissions-accessibility"
        case ready = "permissions-ready"
    }

    let dark: Bool
    let stage: Stage
    private var secondaryText: Color { Color.primary.opacity(0.66) }
    private var accent: Color {
        dark ? Color(red: 0.45, green: 0.72, blue: 1) : Color(red: 0, green: 0.34, blue: 0.76)
    }

    private func permission(_ symbol: String, title: String, detail: String,
                            status: String, ready: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 24)).frame(width: 32, height: 34)
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(detail).font(.system(size: 14)).lineSpacing(4)
                    .foregroundStyle(secondaryText).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    if ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                    Text(status).foregroundStyle(secondaryText)
                }
                .font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var introduction: String {
        switch stage {
        case .microphone:
            "Модели готовы. Осталось предоставить\nдва разрешения macOS."
        case .accessibility:
            "Микрофон готов. Теперь предоставьте\nдоступ к работе с текстом."
        case .ready:
            "Модели готовы, оба доступа предоставлены.\nМожно переходить к началу работы."
        }
    }

    private var explanation: String {
        switch stage {
        case .microphone:
            "«Продолжить» откроет системный запрос доступа к микрофону. Решение вы примете в диалоге macOS."
        case .accessibility:
            "В открывшемся списке включите Translate Like Me, затем вернитесь в приложение."
        case .ready:
            "Оба доступа предоставлены. Далее покажем, как диктовать и переводить текст."
        }
    }

    private var action: String {
        stage == .accessibility ? "Открыть Системные настройки…" : "Продолжить"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Translate Like Me").font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryText).padding(.bottom, 24)
            Text("Доступ для диктовки\nи вставки текста")
                .font(.system(size: 29, weight: .bold)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(introduction)
                .font(.system(size: 15)).lineSpacing(4)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            VStack(alignment: .leading, spacing: 28) {
                permission("mic", title: "Микрофон",
                           detail: "Для распознавания речи, пока вы удерживаете клавишу диктовки.",
                           status: stage == .microphone ? "Требуется разрешение" : "Доступ предоставлен",
                           ready: stage != .microphone)
                permission("hand.raised", title: "Универсальный доступ",
                           detail: "Для чтения выделенного текста и вставки результата в приложение, где вы работаете.",
                           status: stage == .ready ? "Доступ предоставлен"
                               : (stage == .microphone ? "Следующий шаг" : "Требуется разрешение"),
                           ready: stage == .ready)
            }
            .padding(.top, 34)
            Spacer(minLength: 20)
            Divider()
            Text(explanation)
                .font(.system(size: 13)).lineSpacing(3)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 20)
                .frame(height: 72, alignment: .top)
            // Preview-only action. Actual consent always belongs to macOS.
            Text(action)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(dark ? Color.black : Color.white)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(accent, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 20)
        }
        .frame(width: 488, height: 578, alignment: .topLeading)
        .padding(36)
        .background(dark ? Color(red: 0.14, green: 0.14, blue: 0.15) : Color(red: 0.97, green: 0.97, blue: 0.98))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

MainActor.assumeIsolated {
    for dark in [false, true] {
        for stage in PermissionsPreview.Stage.allCases {
            let renderer = ImageRenderer(content: PermissionsPreview(dark: dark, stage: stage))
            renderer.scale = 2
            guard let cgImage = renderer.cgImage else { fatalError("Preview did not render") }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let data = bitmap.representation(using: .png, properties: [:])!
            let output = URL(fileURLWithPath: CommandLine.arguments[1])
                .appendingPathComponent("\(stage.rawValue)-\(dark ? "dark" : "light").png")
            try! data.write(to: output)
        }
    }
}
