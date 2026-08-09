import ImageIO
import PhosphorModel
import SwiftUI
import UniformTypeIdentifiers

/// Detail pane for a selected image asset: a preview plus the facts a shader
/// author needs — the name to reference it by, and its pixel dimensions,
/// which drive the size of an image-initialised texture.
struct AssetPreviewView: View {
    let asset: PhosphorAsset

    private var image: Image? {
        asset.makeCGImage().map { Image(decorative: $0, scale: 1) }
    }

    private var pixelSize: (width: Int, height: Int)? {
        asset.pixelSize()
    }

    /// The asset's file type, read from the image header rather than guessed
    /// from the name — assets are referenced without an extension.
    private var typeDescription: String? {
        guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else {
            return nil
        }
        return type.localizedDescription ?? type.preferredFilenameExtension?.uppercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            details
        }
        .navigationTitle(asset.name)
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            // Checkerboard so transparent assets read as transparent rather
            // than as whatever the window background happens to be.
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CheckerboardBackground())
        } else {
            ContentUnavailableView {
                Label("Can't Preview", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("\(asset.name) isn't an image format ImageIO recognises.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Name").foregroundStyle(.secondary)
                Text(asset.name).textSelection(.enabled)
            }
            if let pixelSize {
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text("\(pixelSize.width) × \(pixelSize.height) px")
                }
            }
            if let typeDescription {
                GridRow {
                    Text("Format").foregroundStyle(.secondary)
                    Text(typeDescription)
                }
            }
            GridRow {
                Text("Data").foregroundStyle(.secondary)
                Text(asset.data.count.formatted(.byteCount(style: .file)))
            }
            GridRow {
                Text("Use").foregroundStyle(.secondary)
                Text(verbatim: #"init = { kind = "image", file = "\#(asset.name)" }"#)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
    }
}

/// Light grey checkerboard, the conventional backdrop for showing alpha.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let square = 10.0
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0...Int(size.height / square) {
                for column in 0...Int(size.width / square) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: Double(column) * square,
                        y: Double(row) * square,
                        width: square,
                        height: square
                    )
                    context.fill(Path(rect), with: .color(.gray.opacity(0.25)))
                }
            }
        }
    }
}

#Preview {
    AssetPreviewView(asset: PhosphorAsset(name: "unreadable", data: Data([0, 1, 2])))
        .frame(width: 400, height: 400)
}
