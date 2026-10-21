// Standalone SwiftUI design preview with synthetic progress, no model downloads.
// Run: swift docs/prototypes/preparation-preview.swift <output-directory>
import AppKit
import SwiftUI

struct PreparationPreview: View {
    let dark: Bool
    private var secondaryText: Color { Color.primary.opacity(0.66) }
    private var accent: Color {
        dark ? Color(red: 0.45, green: 0.72, blue: 1) : Color(red: 0, green: 0.34, blue: 0.76)
    }

    private func model(_ symbol: String, title: String, name: String, status: String, ready: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 23))
                .frame(width: 32, height: 34)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(name).font(.system(size: 14))
                HStack(spacing: 5) {
                    if ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                    Text(status).foregroundStyle(secondaryText)
                }
                .font(.system(size: 13))
            }
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Translate Like Me").font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryText).padding(.bottom, 24)
            Text("Готовим приложение")
                .font(.system(size: 29, weight: .bold))
            Text("Подобрали модели для вашего Mac.\nЗагружаем их на компьютер.")
                .font(.system(size: 15)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(secondaryText).padding(.top, 14)
            HStack(spacing: 8) {
                Image(systemName: "globe")
                Text("Русский ↔ Английский")
            }
            .font(.system(size: 14, weight: .medium)).padding(.top, 20)
            Text("По языкам macOS и раскладкам клавиатуры")
                .font(.system(size: 12)).foregroundStyle(secondaryText).padding(.top, 6)
            VStack(alignment: .leading, spacing: 20) {
                model("mic", title: "Диктовка", name: "Qwen3-ASR",
                      status: "Готово · 2,5 ГБ", ready: true)
                model("character.bubble", title: "Перевод", name: "TranslateGemma 12B",
                      status: "Загружается · 2,1 из 6,7 ГБ", ready: false)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .padding(.top, 20)
            HStack {
                Text("Загрузка моделей").fontWeight(.medium)
                Spacer()
                Text("4,6 из 9,2 ГБ").foregroundStyle(secondaryText)
            }
            .font(.system(size: 13)).padding(.top, 20)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(accent).frame(width: geometry.size.width * 0.5)
                }
            }
            .frame(height: 6).padding(.top, 10)
            Spacer(minLength: 20)
            Text("После загрузки проверим модели и перейдём к разрешениям macOS.")
                .font(.system(size: 13)).lineSpacing(3)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Приостановить").foregroundStyle(accent)
                Spacer()
                Text("Продолжить")
                    .foregroundStyle(secondaryText)
                    .padding(.horizontal, 18).frame(height: 34)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            .font(.system(size: 14, weight: .medium)).padding(.top, 20)
        }
        .frame(width: 488, height: 578, alignment: .topLeading)
        .padding(36)
        .background(dark ? Color(red: 0.14, green: 0.14, blue: 0.15) : Color(red: 0.97, green: 0.97, blue: 0.98))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

MainActor.assumeIsolated {
    for dark in [false, true] {
        let renderer = ImageRenderer(content: PreparationPreview(dark: dark))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { fatalError("Preview did not render") }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let data = bitmap.representation(using: .png, properties: [:])!
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
            .appendingPathComponent("preparation-\(dark ? "dark" : "light").png")
        try! data.write(to: output)
    }
}
