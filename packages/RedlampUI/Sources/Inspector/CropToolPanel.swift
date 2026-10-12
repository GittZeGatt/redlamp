import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Crop & Straighten tool's options, above its Angle slider: the aspect (the presets and those
/// typed in), its lock and the swap between portrait and landscape, the overlay and which overlays
/// and ratios it uses, Constrain to Image, quarter turns and flips, and Reset.
struct CropToolPanel: View {
    @Environment(EditorModel.self) private var model
    @State private var choosingOverlays = false
    @State private var enteringAspect = false

    /// What the Aspect menu chooses: an aspect, or one of its commands.
    private enum AspectChoice: Hashable {
        case aspect(CropAspect)
        case enterCustom
        case clearCustom
    }

    var body: some View {
        @Bindable var model = model
        let custom = model.customCropAspects
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(EditTool.crop.title, systemImage: EditTool.crop.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.value)
                Spacer()
                Button("Reset") { model.resetCrop() }
                    .controlSize(.small)
                    .disabled(model.recipe.crop.isFull && model.recipe.orientation.isIdentity
                        && model.recipe.isDefault(.cropAngle))
            }

            HStack(spacing: 6) {
                Text("Aspect")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.label)
                Picker("Aspect", selection: aspectChoice(custom)) {
                    ForEach(CropAspect.builtIn, id: \.self) { aspect in
                        Text(aspect.title).tag(AspectChoice.aspect(aspect))
                    }
                    if !custom.isEmpty {
                        Divider()
                        ForEach(custom, id: \.self) { aspect in
                            Text(aspect.title).tag(AspectChoice.aspect(.custom(aspect)))
                        }
                    }
                    Divider()
                    Text("Enter Custom…").tag(AspectChoice.enterCustom)
                    if !custom.isEmpty {
                        Text("Clear Custom Aspects").tag(AspectChoice.clearCustom)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .automationIdentifier("crop.aspect")
                .popover(isPresented: $enteringAspect, arrowEdge: .leading) {
                    CropAspectEntry()
                        .environment(model)
                }
                Button {
                    model.cropAspectLocked.toggle()
                } label: {
                    Image(systemName: model.cropAspectLocked ? "lock" : "lock.open")
                }
                .buttonStyle(.borderless)
                .help(model.cropAspectLocked ? "Unlock the aspect (A)" : "Lock the aspect (A)")
                let aspect = model.pixelAspect(of: model.recipe.crop)
                Button {
                    model.swapCropOrientation()
                } label: {
                    Image(systemName: aspect < 1 ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                }
                .buttonStyle(.borderless)
                .disabled(abs(aspect - 1) < 0.005)
                .help("Swap the crop between portrait and landscape (X)")
                .automationIdentifier("crop.aspect.swap")
            }

            HStack(spacing: 6) {
                Text("Overlay")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.label)
                Picker("Overlay", selection: $model.cropOverlay) {
                    ForEach(CropOverlay.allCases, id: \.self) { overlay in
                        Text(overlay.title).tag(overlay)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .help("O cycles the chosen overlays, ⇧O turns it")
                Button {
                    choosingOverlays.toggle()
                } label: {
                    Image(systemName: "checklist")
                }
                .buttonStyle(.borderless)
                .help("Choose Overlays to Cycle and Aspect Ratios")
                .popover(isPresented: $choosingOverlays, arrowEdge: .leading) {
                    CropOverlayChooser()
                        .environment(model)
                }
            }

            Toggle("Constrain to Image", isOn: $model.constrainCropToImage)
                .toggleStyle(.checkbox)
                .font(Theme.labelFont)

            HStack(spacing: 4) {
                iconButton("rotate.left", "Rotate Left (⌘[)") { model.rotate(clockwise: false) }
                iconButton("rotate.right", "Rotate Right (⌘])") { model.rotate(clockwise: true) }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip Horizontal") {
                    model.flip(horizontally: true)
                }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip Vertical") {
                    model.flip(horizontally: false)
                }
                Button {
                    model.isStraightening.toggle()
                } label: {
                    Image(systemName: "level")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(model.isStraightening ? Color.accentColor : Theme.label)
                .help("Straighten: draw along a horizon or vertical (or ⌘-drag in the crop)")
                Spacer()
                Button("Done") { model.activeTool = .edit }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(Theme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// The aspect chosen, shown as Custom once it's one typed in that has since been cleared (in
    /// another editor, say); choosing a command runs it and leaves the aspect as it was.
    private func aspectChoice(_ custom: [CustomCropAspect]) -> Binding<AspectChoice> {
        Binding {
            if case let .custom(aspect) = model.cropAspect, !custom.contains(aspect) {
                return .aspect(.free)
            }
            return .aspect(model.cropAspect)
        } set: { choice in
            switch choice {
            case let .aspect(aspect): model.setCropAspect(aspect)
            case .enterCustom: enteringAspect = true
            case .clearCustom: model.clearCustomCropAspects()
            }
        }
    }
}

/// Lightroom's Enter Custom…: an aspect typed in as a ratio or a size in pixels, which crops as
/// typed and is kept in the Aspect menu.
struct CropAspectEntry: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let aspect = CustomCropAspect(text)
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter Custom Aspect").font(.headline)
            TextField("21 × 9 or 1080 × 1350", text: $text)
                .focused($focused)
                .onSubmit(enter)
                .automationIdentifier("crop.aspect.custom")
            Text(caption(aspect))
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: enter)
                    .keyboardShortcut(.defaultAction)
                    .disabled(aspect == nil)
                    .automationIdentifier("crop.aspect.add")
            }
        }
        .font(Theme.labelFont)
        .padding(14)
        .frame(width: 240)
        .takesKeys()
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }

    /// What the field holds: how to fill it, why it won't do, or which way the crop will be.
    private func caption(_ aspect: CustomCropAspect?) -> String {
        if let aspect {
            return aspect.ratio > 1 ? "A landscape crop." : aspect.ratio < 1 ? "A portrait crop." : "A square crop."
        }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return "A ratio or a size in pixels. It crops as typed, and stays in the Aspect menu."
        }
        if let (width, height) = CustomCropAspect.numbers(in: text), width > 0, height > 0 {
            return "One side can be at most \(Int(CustomCropAspect.longest)) times the other."
        }
        return "Two numbers, such as 21 × 9 or 1080 × 1350."
    }

    private func enter() {
        guard let aspect = CustomCropAspect(text) else { return }
        model.enterCropAspect(aspect)
        dismiss()
    }
}

/// Lightroom's Choose Overlays to Cycle and Choose Aspect Ratios, side by side. The last one
/// checked in each list can't be cleared.
struct CropOverlayChooser: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let choices = model.cropOverlayChoices
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                heading("Overlays to Cycle", "O steps through these")
                ForEach(CropOverlay.allCases, id: \.self) { overlay in
                    Toggle(overlay.title, isOn: $model.cropOverlayChoices[overlay])
                        .disabled(choices.overlays == [overlay])
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                heading("Aspect Ratios", "For the Aspect Ratios overlay")
                ForEach(CropOverlay.AspectRatio.allCases, id: \.self) { ratio in
                    Toggle(ratio.title, isOn: $model.cropOverlayChoices[ratio])
                        .disabled(choices.ratios == [ratio])
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
    }

    private func heading(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }
}
