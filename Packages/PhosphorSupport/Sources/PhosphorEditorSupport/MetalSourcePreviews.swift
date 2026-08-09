#if DEBUG
import SourceEditor
import SwiftUI

private let sampleSource = """
/* phosphor:environment
output = "image"
*/
// tiny kernel
kernel void image(uint2 gid [[thread_position_in_grid]]) {
    float v = 0.5;
    if (gid.x > 100) { v = 1.0; }
}
"""

#Preview("Read-only") {
    SourceEditorView(text: sampleSource, language: .metal)
        .frame(width: 480, height: 240)
}

#Preview("Editable") {
    @Previewable @State var source = sampleSource
    SourceEditorView(text: $source, language: .metal)
        .frame(width: 480, height: 240)
}

#Preview("Dark with backdrop") {
    SourceEditorView(text: sampleSource, language: .metal, palette: .darkWithBackdrop)
        .frame(width: 480, height: 240)
        .background(.black)
}
#endif
