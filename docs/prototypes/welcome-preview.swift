// Standalone SwiftUI design preview. No preferences, downloads, or permissions are changed.
// Run: swift docs/prototypes/welcome-preview.swift <output-directory>
import AppKit
import SwiftUI

struct WelcomePreview: View {
    let dark: Bool
    private var secondaryText: Color { Color.primary.opacity(0.66) }

    private func instruction(_ symbol: String, title: String, shortcut: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .frame(width: 32, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    Spacer(minLength: 12)
                    Text(shortcut)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.14)))
                }
                Text(detail)
                    .font(.system(size: 14)).lineSpacing(4)
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Translate Like Me").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryText)
                Spacer()
            }
            .padding(.bottom, 24)
            Text("Диктуйте и переводите")
                .font(.system(size: 29, weight: .bold)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Диктуйте в поля ввода.\nПереводите выделенные фрагменты.")
                .font(.system(size: 15)).lineSpacing(4)
                .foregroundStyle(secondaryText)
                .padding(.top, 14)
            VStack(spacing: 28) {
                instruction("mic", title: "Диктуйте", shortcut: "Правый ⌥",
                    detail: "Поставьте курсор в поле ввода. Удерживайте правый Option, говорите и отпустите клавишу.")
                instruction("character.bubble", title: "Переводите", shortcut: "⌥ ⌘ F",
                    detail: "Выделите текст и нажмите сочетание клавиш. Если вставка недоступна, скопируйте перевод из окна результата.")
            }
            .padding(.top, 34)
            Spacer(minLength: 28)
            Divider()
            Text("Модели, языки и другие параметры можно изменить в Настройках. Чтобы открыть их, нажмите значок Translate Like Me в строке меню.")
                .font(.system(size: 13)).lineSpacing(3)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
            // Preview-only representation of the primary native action.
            Text("Начать пользоваться")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(dark ? Color.black : Color.white)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(dark ? Color(red: 0.45, green: 0.72, blue: 1) : Color(red: 0, green: 0.34, blue: 0.76),
                            in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 20)
        }
        .frame(width: 488, height: 578, alignment: .topLeading)
        .padding(36)
        .background(dark ? Color(red: 0.14, green: 0.14, blue: 0.15) : Color(red: 0.97, green: 0.97, blue: 0.98))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

@MainActor
func render() {
    let directory = CommandLine.arguments[1]
    for dark in [false, true] {
        let renderer = ImageRenderer(content: WelcomePreview(dark: dark))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { fatalError("Preview did not render") }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let data = bitmap.representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("welcome-\(dark ? "dark" : "light").png"))
    }
}
MainActor.assumeIsolated { render() }
