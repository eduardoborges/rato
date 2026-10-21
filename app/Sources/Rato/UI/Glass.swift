import SwiftUI

// Liquid Glass do macOS 26 em diante, só nos controles, como pede a Apple. O conteúdo fica nas superfícies do sistema.
// Antes do 26, os mesmos controles têm fundo chapado. Com Reduzir Transparência, o sistema troca o vidro por um fundo
// opaco.

extension View {
    /// Vidro tingido quando há cor. Antes do macOS 26, a própria cor ou o cinza do sistema.
    @ViewBuilder func glass(tint: Color?, in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            let g: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            glassEffect(g.interactive(), in: shape)
        } else {
            background(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.quaternary), in: shape)
        }
    }

    /// Junta vidros vizinhos para o sistema desenhá-los como uma peça só.
    @ViewBuilder func glassGroup(spacing: CGFloat = 6) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Escolha entre poucos valores, como um controle segmentado: um trilho com a opção escolhida em vidro na cor de
/// destaque do sistema.
struct Chips<Value: Hashable>: View {
    let values: [Value]
    let selection: Value?
    let label: (Value) -> String
    let pick: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { v in
                let on = v == selection
                Button { if !on { pick(v) } } label: {
                    let text = Text(label(v))
                        .font(.callout.weight(on ? .semibold : .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Capsule())
                    if on { text.glass(tint: .accentColor, in: Capsule()) } else { text }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .glassGroup()
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}
