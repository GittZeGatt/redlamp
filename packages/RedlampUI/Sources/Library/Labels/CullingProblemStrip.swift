import SwiftUI

/// Over the top of the Library's photos, a culling change some of them didn't get (`EditorModel.cullingProblem`): how
/// many and which, and why, with Select, Try Again and Close (LIB-15).
struct CullingProblemStrip: View {
    let model: EditorModel

    var body: some View {
        if model.module == .library, let problem = model.cullingProblem {
            HStack(spacing: 10) {
                Label {
                    Text(problem.message)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .symbolRenderingMode(.multicolor)
                .help(problem.message)
                .accessibilityIdentifier("library.cullingProblem.message")
                Button("Select") { model.selectCullingProblem() }
                    .buttonStyle(.borderless)
                    .help("Select the photos it wasn't saved to")
                    .accessibilityIdentifier("library.cullingProblem.select")
                Button("Try Again") { model.retryCulling() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("library.cullingProblem.retry")
                Button {
                    model.closeCullingProblem()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
                .accessibilityIdentifier("library.cullingProblem.close")
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.cullingProblem")
        }
    }
}
