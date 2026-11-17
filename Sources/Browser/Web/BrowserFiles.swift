import Foundation
import UIKit
import WebKit

extension BrowserScreen {
    var canZoomLocalPhoto: Bool { localFile?.kind == .image && localFile?.matches(web.url) == true }

    func openLocalFile(_ file: LocalPanelFile, from source: BrowserScreen, replacingPresentation: UUID? = nil) {
        guard self === owner, active, source.active, allPanels.contains(where: { $0 === source }),
            signInSession == nil, source.popup == nil
        else {
            return
        }
        if let replacingPresentation {
            guard file.isPDF, let current = source.localFile, current.id == replacingPresentation,
                current.isPresentation
            else {
                return
            }
            selectPanel(source.panelNumber)
            source.loadLocalFile(file)
            return
        }
        if canAddWebPanel, allPanels.count < 4, !source.isHome {
            addPanel(selectNewScreen: true)
            selectedSession.loadLocalFile(file)
        } else {
            selectPanel(source.panelNumber)
            source.loadLocalFile(file)
        }
    }

    func openNativeMedia(_ file: LocalPanelFile, from source: BrowserScreen) {
        guard self === owner, active, source.active, file.kind != .document,
            allPanels.contains(where: { $0 === source }), signInSession == nil, source.popup == nil
        else {
            return
        }
        for panel in allPanels {
            panel.cancelScroll()
            panel.cancelTaps()
            panel.closePhoneEditor()
            panel.addressEditing = false
            panel.web.pauseAllMediaPlayback()
        }
        nativeMediaSource = source
        GlassesDisplay.shared.nativeMedia.open(file, autoplay: true)
    }

    func returnNativeMediaToPanel() {
        guard self === owner, active, signInSession == nil, let file = GlassesDisplay.shared.nativeMedia.file else {
            return
        }
        let source =
            nativeMediaSource.flatMap { origin in allPanels.contains { $0 === origin } ? origin : nil }
            ?? selectedSession
        GlassesDisplay.shared.nativeMedia.close()
        nativeMediaSource = nil
        if source.localFile === file {
            selectPanel(source.panelNumber)
        } else {
            openLocalFile(file, from: source)
        }
    }

    func loadLocalFile(_ file: LocalPanelFile) {
        media.setCinema(false)
        closePhoneEditor()
        cancelTaps()
        cancelScroll()
        navigationFinished = false
        isLoadingPage = true
        didAttemptProcessReload = false
        sourceReady = true
        browserNotice = ""
        lastRecordedAddress = nil
        localPhotoZoom = 1
        localFile = file
        epoch = UUID()
        if let page = file.moviePageURL {
            pendingLocalNavigation = web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else if let html = file.moviePageHTML {
            pendingLocalNavigation = web.loadHTMLString(html, baseURL: file.url)
        } else {
            pendingLocalNavigation = web.loadFileURL(file.url, allowingReadAccessTo: file.url)
        }
        if pendingLocalNavigation == nil {
            localFile = nil
            isLoadingPage = false
            showNotice("The selected file could not be opened.")
        }
    }

    func zoomLocalPhoto(by delta: CGFloat) {
        guard canZoomLocalPhoto, receivesInput, delta.isFinite, delta > 0 else {
            return
        }
        let scale = min(6, max(1, localPhotoZoom * delta))
        guard abs(scale - localPhotoZoom) > 0.002 else {
            return
        }
        localPhotoZoom = scale
        web.callAsyncJavaScript(
            """
            const img = document.querySelector('img');
            if (img) {
                img.style.transform = 'scale('+scale+')';
            }
            """, arguments: ["scale": Double(scale)], in: nil, in: editorWorld, completionHandler: nil)
    }

    func fitLocalMediaInPanel() {
        guard let file = localFile, file.matches(web.url), file.kind != .document else {
            return
        }
        web.evaluateJavaScript(
            """
            (() => {
                const item = document.querySelector('video,img');
                if (!item || location.protocol !== 'file:') {
                    return;
                }
                // Fill the screen with the photo or video on a black background.
                Object.assign(document.documentElement.style, {
                    width: '100%', height: '100%', background: '#000'
                });
                Object.assign(document.body.style, {
                    margin: '0', width: '100%', height: '100%', overflow: 'hidden', background: '#000'
                });
                Object.assign(item.style, {
                    width: '100%', height: '100%', display: 'block', objectFit: 'contain',
                    position: 'static', margin: '0'
                });
                if (item instanceof HTMLVideoElement) {
                    item.playsInline = true;
                    item.controls = true;
                }
            })();
            """, completionHandler: nil)
    }
}
