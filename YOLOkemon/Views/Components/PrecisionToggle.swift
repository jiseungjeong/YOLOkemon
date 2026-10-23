import SwiftUI

/// Three-way segmented picker for model precision (FP32 / FP16 / INT8).
/// Calls `onChange` with the newly selected precision so the owner can
/// trigger `DetectionEngine.switchPrecision(to:)` and update any
/// precision-dependent UI (model size label, status text, etc).
///
/// The delegate axis is fixed to CPU (XNNPACK) — see DetectionEngine's
/// class docstring for rationale — so there is no companion `DelegateToggle`.
struct PrecisionToggle: View {
    @Binding var selection: Precision
    var disabled: Bool = false
    var onChange: (Precision) -> Void

    var body: some View {
        Picker("Precision", selection: $selection) {
            ForEach(Precision.allCases) { p in
                Text(p.display).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .disabled(disabled)
        .onChange(of: selection) { _, new in
            onChange(new)
        }
    }
}

#Preview {
    @Previewable @State var prec: Precision = .fp32
    return VStack(spacing: 16) {
        PrecisionToggle(selection: $prec) { _ in }
    }
    .padding()
}
