import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Typing into a web text field with the iPhone keyboard.
extension BrowserScreen {
    /// A real click can submit or navigate as usual. The keyboard fallback
    /// also hit-tests the tapped field, since WebKit may not give it focus.
    func offerPhoneEditor(at point: CGPoint? = nil, frame: WKFrameInfo? = nil) {
        guard active, receivesInput, !native.phoneHosted, !phonePageActive,
            !BrowserDestination.supportsDirectPhoneSignIn(web.url), popup == nil, !addressEditing
        else {
            return
        }
        let request = UUID()
        editorState.request = request
        var normalized: Any = NSNull()
        if let point, web.bounds.width > 0, web.bounds.height > 0 {
            let x = point.x / web.bounds.width, y = point.y / web.bounds.height
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                return
            }
            normalized = ["x": Double(x), "y": Double(y)]
        }
        func evaluate(_ target: WKFrameInfo?) {
            web.callAsyncJavaScript(
                "return globalThis.vxrOfferEditor?.(id,currentID,point,fromTap) ?? null;",
                arguments: [
                    "id": request.uuidString, "currentID": phoneEditor?.id.uuidString ?? "",
                    "point": normalized, "fromTap": target != nil
                ], in: target, in: editorWorld
            ) { [weak self] result in
                guard let self, self.active, self.receivesInput, !self.addressEditing,
                    self.editorState.request == request,
                    !self.phonePageActive, self.popup == nil
                else {
                    return
                }
                guard case .success(let value) = result, let fields = value as? [String: Any] else {
                    if target != nil {
                        evaluate(nil)
                    } else if case .success = result {
                        self.closePhoneEditor()
                    }
                    return
                }
                if fields["same"] as? Bool == true {
                    self.phoneEditorFocusRevision &+= 1
                    return
                }
                guard let text = fields["text"] as? String, let type = fields["type"] as? String else {
                    return
                }
                if let old = self.phoneEditor {
                    self.clearPhoneField(old.id, frame: self.editorState.fieldFrame)
                }
                self.editorState.fieldFrame = target
                self.phoneEditor = PhoneEditor(
                    id: request, text: text, type: type, mode: fields["mode"] as? String ?? "")
            }
        }
        evaluate(frame)
    }

    func updatePhoneEditor(_ text: String) {
        guard receivesInput, !phonePageActive, !BrowserDestination.supportsDirectPhoneSignIn(web.url),
            var editor = phoneEditor, text.count <= 8192
        else {
            return
        }
        editor.text = text
        phoneEditor = editor
        web.callAsyncJavaScript(
            "return globalThis.vxrWriteEditor?.(id,text) ?? false;",
            arguments: ["id": editor.id.uuidString, "text": text], in: editorState.fieldFrame, in: editorWorld
        ) { [weak self] result in
            guard let self, self.phoneEditor?.id == editor.id else {
                return
            }
            if case .success(let value) = result, value as? Bool == true {
                return
            }
            self.inputStatus = "The selected field changed. Tap it to type again."
            self.showNotice(self.inputStatus)
            self.closePhoneEditor()
        }
    }

    func submitPhoneEditor() {
        guard receivesInput, !phonePageActive, !BrowserDestination.supportsDirectPhoneSignIn(web.url),
            let editor = phoneEditor
        else {
            return
        }
        web.callAsyncJavaScript(
            "return globalThis.vxrSubmitEditor?.(id) ?? false;",
            arguments: ["id": editor.id.uuidString], in: editorState.fieldFrame, in: editorWorld, completionHandler: nil
        )
        closePhoneEditor()
    }

    private func clearPhoneField(_ id: UUID, frame: WKFrameInfo?) {
        web.callAsyncJavaScript(
            "globalThis.vxrCloseEditor?.(id);", arguments: ["id": id.uuidString],
            in: frame, in: editorWorld, completionHandler: nil)
    }

    func closePhoneEditor() {
        editorState.request = UUID()
        editorState.tapStarted = nil
        editorState.tapFrame = nil
        if let editor = phoneEditor {
            clearPhoneField(editor.id, frame: editorState.fieldFrame)
        }
        phoneEditor = nil
        editorState.fieldFrame = nil
    }
}
