import PhosphorSupport
import SwiftUI
import UniformTypeIdentifiers

/// Horizontal thumbnail strip showing every asset in a `.phosphor` bundle.
///
/// Also serves as the drop target for image files: dragging a PNG/JPEG
/// onto the strip adds it to the bundle under its filename stem.
struct PhosphorAssetStrip: View {
    let assets: [String: PhosphorAsset]
    let onAdd: ([URL]) -> Void
    let onRemove: (String) -> Void

    private var sortedAssets: [PhosphorAsset] {
        assets.values.sorted { $0.name < $1.name }
    }

    var body: some View {
        ZStack {
            if assets.isEmpty {
                EmptyAssetStrip()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(sortedAssets, id: \.name) { asset in
                            AssetThumbnail(asset: asset, onRemove: { onRemove(asset.name) })
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(minHeight: 88, maxHeight: 88)
        .background(.background.secondary, in: .rect)
        .overlay(alignment: .top) {
            Divider()
        }
        .dropDestination(for: URL.self) { urls, _ in
            onAdd(urls)
            return !urls.isEmpty
        }
    }
}

/// Placeholder shown when the bundle has no assets yet.
private struct EmptyAssetStrip: View {
    var body: some View {
        Label("Drop images here", systemImage: "photo.on.rectangle.angled")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// Single asset cell: thumbnail + name + hover-revealed remove button.
private struct AssetThumbnail: View {
    let asset: PhosphorAsset
    let onRemove: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ThumbnailImage(asset: asset)
                if isHovering {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.large)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                }
            }
            Text(asset.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 64)
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

/// Renders the asset's bytes as a 56×56 image, falling back to a generic
/// icon if ImageIO can't decode (e.g. a non-image asset slipped in).
private struct ThumbnailImage: View {
    let asset: PhosphorAsset

    var body: some View {
        if let cgImage = asset.makeCGImage() {
            Image(decorative: cgImage, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 4))
        } else {
            Image(systemName: "doc")
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(.background.tertiary, in: .rect(cornerRadius: 4))
        }
    }
}

// MARK: - Previews

#Preview("Empty") {
    PhosphorAssetStrip(assets: [:], onAdd: { _ in }, onRemove: { _ in })
        .frame(width: 420)
}

#Preview("Populated") {
    // Two assets backed by tiny synthetic PNG data so the preview works
    // without a real bundle on disk.
    let red = PhosphorAsset(name: "red", data: tinyPNG(red: 1, green: 0, blue: 0))
    let blue = PhosphorAsset(name: "blue", data: tinyPNG(red: 0, green: 0, blue: 1))
    PhosphorAssetStrip(
        assets: ["red": red, "blue": blue],
        onAdd: { _ in },
        onRemove: { _ in }
    )
    .frame(width: 420)
}

/// Builds a 1×1 PNG of the given color, for preview thumbnails.
private func tinyPNG(red: Double, green: Double, blue: Double) -> Data {
    let renderer = ImageRenderer(content: Rectangle().fill(Color(red: red, green: green, blue: blue)).frame(width: 16, height: 16))
    guard let cgImage = renderer.cgImage,
          let mutableData = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
        return Data()
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
    return mutableData as Data
}
