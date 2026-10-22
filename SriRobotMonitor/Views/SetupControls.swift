import SwiftUI

/// `TextField` de los formularios del onboarding.
///
/// Los campos de configuración usan `textFieldStyle(.plain)` dentro de una
/// caja dibujada por `LabeledField`. Se envuelve aquí para que todos los
/// formularios se comporten igual: sin animación implícita y con el mismo
/// tipado monoespaciado que los valores de AWS.
struct SetupTextField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .animation(nil, value: text)
    }
}

/// Campo de secreto que se puede revelar sin perder el foco.
///
/// Intercambiar `SecureField` por `TextField` destruye la vista: SwiftUI
/// desmonta el control, el foco salta al siguiente campo y la pantalla se
/// sacude. Aquí el campo se declara una sola vez y solo cambia su superficie
/// de dibujo, así que el cursor se queda donde estaba.
struct SecretTextField: View {
    let placeholder: String
    @Binding var text: String
    var revealed: Bool

    init(_ placeholder: String, text: Binding<String>, revealed: Bool) {
        self.placeholder = placeholder
        self._text = text
        self.revealed = revealed
    }

    var body: some View {
        Group {
            if revealed {
                TextField(placeholder, text: $text)
            } else {
                SecureField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        // Sin transición ni animación: revelar el secreto no debe re-layoutar
        // el resto del formulario.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

/// Botón único de los flujos de configuración.
///
/// Antes convivían tres estilos (`glassProminent` grande, `glass` regular y
/// texto suelto) y cada uno cambiaba de altura y de peso óptico dentro de la
/// misma fila. Todos los botones de un paso pasan ahora por este componente,
/// con el formato de *Continuar*.
struct SetupButton: View {
    enum Role {
        /// Acción principal: continuar, guardar, empezar.
        case primary
        /// Acción de apoyo: probar, comprobar, atrás.
        case secondary
    }

    let title: String
    var symbol: String?
    var role: Role = .primary
    var loading = false
    var minWidth: CGFloat = 130
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .frame(minWidth: minWidth)
        }
        .buttonStyle(.glassProminent)
        .tint(role == .primary ? Palette.green : Palette.blue)
        .foregroundStyle(.black.opacity(role == .primary ? 0.86 : 0.82))
        .controlSize(.large)
    }
}
