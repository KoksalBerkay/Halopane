import AVFoundation
import CoreGraphics
import ImageIO
import MetalKit
import SpatialMath
import UniformTypeIdentifiers

@main struct NativeMediaSmoke {
    @MainActor static func main() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Check.gpu
        }
        let renderer = try NativeMediaRenderer(device: device)
        let red: [UInt8] = [0, 0, 255, 255]
        let blue: [UInt8] = [255, 0, 0, 255]
        let black: [UInt8] = [0, 0, 0, 255]

        func texture(width: Int, height: Int, paint: (Int, Int) -> [UInt8]) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .shared
            let t = device.makeTexture(descriptor: descriptor)!
            let bytes = (0..<height).flatMap { y in (0..<width).flatMap { x in paint(x, y) } }
            t.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
            return t
        }

        var surface: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferBytesPerRowAlignmentKey as String: 256,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let result = CVPixelBufferCreate(nil, 67, 17, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &surface)
        guard result == kCVReturnSuccess, let surface else {
            throw Check.gpu
        }
        func fillSurface(red: Bool) {
            precondition(CVPixelBufferLockBaseAddress(surface, []) == kCVReturnSuccess)
            defer {
                CVPixelBufferUnlockBaseAddress(surface, [])
            }
            let stride = CVPixelBufferGetBytesPerRow(surface)
            precondition(stride > 67 * 4)
            let base = CVPixelBufferGetBaseAddress(surface)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<17 {
                for x in 0..<67 {
                    let offset = y * stride + x * 4
                    base[offset] = red && y == 16 ? 0 : 255
                    base[offset + 1] = 0
                    base[offset + 2] = red && y == 16 ? 255 : 0
                    base[offset + 3] = 255
                }
            }
        }
        fillSurface(red: true)
        guard let frozenEye = renderer.snapshotEye(surface) else {
            throw Check.gpu
        }
        precondition(
            MediaLuma.difference(MediaLuma.grid(surface), MediaLuma.grid(frozenEye)) == "mean 0.00, max 0.00 / 255")
        fillSurface(red: false)

        var settings = NativeMediaRenderer.Presentation()
        settings.stereo = true
        settings.safeArea.top = 0.25
        func render(_ left: MTLTexture, _ right: MTLTexture? = nil) throws -> MTLTexture {
            let output = texture(width: 128, height: 72) { _, _ in
                black
            }
            guard let command = queue.makeCommandBuffer() else {
                throw Check.gpu
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            guard
                renderer.encode(
                    command: command, pass: pass, size: CGSize(width: 128, height: 72),
                    left: left, right: right, presentation: settings)
            else {
                throw Check.gpu
            }
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error {
                throw error
            }
            return output
        }
        func pixel(_ texture: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return bytes
        }

        precondition(pixel(frozenEye, 64, 16) == red && pixel(frozenEye, 64, 15) == blue)
        precondition(
            MediaLuma.difference(MediaLuma.grid(surface), MediaLuma.grid(frozenEye)) != "mean 0.00, max 0.00 / 255")
        guard let image = MediaLuma.image(frozenEye) else {
            throw Check.gpu
        }
        precondition(
            MediaLuma.difference(MediaLuma.grid(image), MediaLuma.grid(frozenEye)) == "mean 0.00, max 0.00 / 255")
        print("Paused image path matches the Metal texture without redecoding")
        print("Stereo texture remained intact after reusing a padded decoder buffer")
        let sbs = texture(width: 64, height: 24) { x, _ in
            x < 32 ? red : blue
        }
        settings.layout = .sideBySide
        let packed = try render(sbs)
        precondition(pixel(packed, 32, 46) == red && pixel(packed, 96, 46) == blue)
        precondition(pixel(packed, 32, 8) == black)
        settings.swapped = true
        let swapped = try render(sbs)
        precondition(pixel(swapped, 32, 46) == blue && pixel(swapped, 96, 46) == red)
        settings.swapped = false
        settings.layout = .overUnder
        let ou = try render(
            texture(width: 40, height: 48) { _, y in
                y < 24 ? red : blue
            })
        precondition(pixel(ou, 32, 46) == red && pixel(ou, 96, 46) == blue)
        let separateLeft = texture(width: 32, height: 24) { _, _ in
            red
        }
        let separateRight = texture(width: 32, height: 24) { _, _ in
            blue
        }
        settings.layout = .separateEyes
        let separate = try render(separateLeft, separateRight)
        precondition(pixel(separate, 32, 46) == red && pixel(separate, 96, 46) == blue)
        settings.eyePreview = .rightOnly
        let rightOnly = try render(separateLeft, separateRight)
        precondition(pixel(rightOnly, 32, 46) == blue && pixel(rightOnly, 96, 46) == blue)
        settings.eyePreview = .leftOnly
        let leftOnly = try render(separateLeft, separateRight)
        precondition(pixel(leftOnly, 32, 46) == red && pixel(leftOnly, 96, 46) == red)
        settings.eyePreview = .stereo
        settings.stereo = false
        let mono = try render(separateLeft, separateRight)
        precondition(pixel(mono, 64, 46) == red)
        settings.stereo = true
        settings.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        settings.projection = .halfSphere
        let back = try render(separateLeft, separateRight)
        precondition(pixel(back, 32, 46) == black && pixel(back, 96, 46) == black)
        settings.projection = .sphere
        let sphere = try render(separateLeft, separateRight)
        precondition(pixel(sphere, 32, 46) == red && pixel(sphere, 96, 46) == blue)
        print("Metal verified: SBS, over-under, separate eyes, swap, mono, visible area and panorama back hemisphere")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let photo = directory.appendingPathComponent("eyes.heic")
        try makeStereoPhoto(at: photo)
        guard let pair = NativePhotoFrames.read(photo), let right = pair.1 else {
            throw Check.photo
        }
        let leftRGB = samplePhoto(pair.0)
        let rightRGB = samplePhoto(right)
        precondition(leftRGB[0] > 180 && leftRGB[2] < 50 && rightRGB[2] > 180 && rightRGB[0] < 50)
        print("HEIC stereo pair decoded in eye order even with the right eye stored first")
        let stillFile = try LocalPanelFile.openOriginal(photo)
        let stereoOpensInPlayer = await MediaFormat.prefersSpatialPlayer(for: stillFile)
        precondition(stereoOpensInPlayer)
        let ordinary = directory.appendingPathComponent("ordinary.jpg")
        guard let jpeg = CGImageDestinationCreateWithURL(ordinary as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw Check.photo
        }
        CGImageDestinationAddImage(jpeg, pair.0, nil)
        guard CGImageDestinationFinalize(jpeg) else {
            throw Check.photo
        }
        let jpegFile = try LocalPanelFile.openOriginal(ordinary)
        let photoOpensInPlayer = await MediaFormat.prefersSpatialPlayer(for: jpegFile)
        precondition(!photoOpensInPlayer)
        let movieURL = URL(fileURLWithPath: "Resources/web-test.mp4").standardizedFileURL
        let movieFile = try LocalPanelFile.openOriginal(movieURL)
        let movieOpensInPlayer = await MediaFormat.prefersSpatialPlayer(for: movieFile)
        precondition(!movieOpensInPlayer)
        let panoramicURL = directory.appendingPathComponent("demo_VR180_SBS.jpg")
        try FileManager.default.copyItem(at: ordinary, to: panoramicURL)
        let panoramicFile = try LocalPanelFile.openOriginal(panoramicURL)
        let panoramaOpensInPlayer = await MediaFormat.prefersSpatialPlayer(for: panoramicFile)
        precondition(panoramaOpensInPlayer)
        print(
            "Picker routing verified: stereo HEIC and tagged panorama use the player; plain JPEG and MP4 stay in panels"
        )
        let movieSession = NativeMediaSession()
        movieSession.open(movieFile, autoplay: true)
        for _ in 0..<150 {
            if movieSession.position > 0 || movieSession.error != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard movieSession.position > 0, movieSession.error == nil else {
            throw Check.movie
        }
        movieSession.pause()
        movieSession.showScrubPreview(movieSession.duration / 2)
        precondition(movieSession.presentationHint(stereo: true, rendererUnavailable: false)?.contains(" / ") == true)
        movieSession.close()
        precondition(movieSession.scrubPreview == nil)
        print("Playback verified: autoplay advances the clock and scrubbing exposes a time prompt")
        let stillSession = NativeMediaSession()
        stillSession.open(stillFile)
        for _ in 0..<100 {
            if !stillSession.loading {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let still = stillSession.photo, let stillRight = still.1 else {
            throw Check.photo
        }
        precondition(samplePhoto(still.0)[0] > 180 && samplePhoto(stillRight)[2] > 180)
        precondition(stillSession.arrangement == .separateEyes && stillSession.usesFlatPhotoSurface)
        precondition(!stillSession.usesLiveImagePresentation)
        stillSession.roomScreen = true
        precondition(!stillSession.usesFlatPhotoSurface)
        stillSession.close()
        precondition(!stillSession.usesFlatPhotoSurface)
        print(
            "A flat spatial photo keeps both decoded eyes and selects the image surface without waiting for a video frame"
        )
        let format = MediaFormat.inferred(from: "example VR180_HSBS.mp4")
        precondition(format.projection == .halfSphere && format.layout == .halfSideBySide)

        if CommandLine.arguments.count > 1 {
            let source = try LocalPanelFile.openOriginal(URL(fileURLWithPath: CommandLine.arguments[1]))
            let session = NativeMediaSession()
            if CommandLine.arguments.contains("--native") {
                session.setStereoDecoder(.playerNative)
            } else if CommandLine.arguments.contains("--bgra") {
                session.setStereoDecoder(.playerBGRA)
            }
            session.open(source)
            session.play()
            var previous = CMTime.invalid
            var pairs = 0
            var distinct = false
            for _ in 0..<180 {
                if let sample = session.sample(hostTime: CACurrentMediaTime(), after: previous) {
                    previous = sample.2
                    if let right = sample.1 {
                        pairs += 1
                        distinct = distinct || sample.0 !== right
                        guard let copiedLeft = renderer.snapshotEye(sample.0),
                            let copiedRight = renderer.snapshotEye(right),
                            copiedLeft.width == copiedRight.width && copiedLeft.height == copiedRight.height
                        else {
                            throw Check.movie
                        }
                        session.diagnostics.record(
                            .init(
                                left: sample.0, right: right, timestamp: sample.2, leftTexture: copiedLeft,
                                rightTexture: copiedRight, route: "smoke upload"), frame: pairs, expectedStereo: true)
                    }
                    if pairs >= 3 && distinct {
                        break
                    }
                }
                if session.error != nil {
                    break
                }
                try await Task.sleep(nanoseconds: 33_000_000)
            }
            print("AVFoundation: " + session.summary)
            guard session.detectedStereo, pairs >= 3, distinct else {
                throw Check.movie
            }
            session.pause()
            await withCheckedContinuation { done in
                session.diagnostics.check(file: source) { _ in
                    done.resume()
                }
            }
            print(session.diagnostics.report)
            let report = session.diagnostics.report
            guard report.contains("decoded→texture"), report.contains("generator Δt"),
                !report.contains(source.url.lastPathComponent)
            else {
                throw Check.movie
            }
            // A paused seek should request fresh pairs from the new range and
            // display the frame nearest the actual player clock.
            if session.stereoDecoder == .trackReader, session.duration > 1.6 {
                let target = 1.25
                session.seek(to: target)
                var landing: StereoDecodedFrame?
                for _ in 0..<100 {
                    if let pair = session.sample(hostTime: CACurrentMediaTime(), after: previous), pair.1 != nil,
                        abs(pair.2.seconds - target) < 0.10
                    {
                        landing = StereoDecodedFrame(left: pair.0, right: pair.1, time: pair.2)
                        break
                    }
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
                guard let landing else {
                    throw Check.movie
                }
                print("Paused track reader seek returned a fresh stereo pair at \(landing.time.seconds) s")
            }
            let comparison: PausedMediaComparison? = await withCheckedContinuation { done in
                session.diagnostics.compare(turns: 0) {
                    done.resume(returning: $0)
                }
            }
            guard let comparison, let image = comparison.right, let texture = comparison.rightTexture,
                image.width == texture.width,
                MediaLuma.difference(MediaLuma.grid(image), MediaLuma.grid(texture)) == "mean 0.00, max 0.00 / 255"
            else {
                throw Check.movie
            }
            print("Latched actual spatial frame at \(comparison.timeLabel) with matching image and texture pixels")
            if session.stereoDecoder == .trackReader, session.duration > 1.6 {
                let images = LiveStereoImageOutput()
                session.seek(to: 0.75)
                for _ in 0..<120 {
                    images.update(session: session, hostTime: CACurrentMediaTime())
                    if let frame = images.frame, abs(frame.timestamp.seconds - 0.75) < 0.10,
                        frame.left.width == frame.right.width
                    {
                        break
                    }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                guard let frame = images.frame, abs(frame.timestamp.seconds - 0.75) < 0.10 else {
                    throw Check.movie
                }
                // Reusing the renderer on the next seek invalidates the old pair.
                session.seek(to: 1.45)
                images.update(session: session, hostTime: CACurrentMediaTime())
                precondition(images.frame == nil)
                session.play()
                var visibleID: UUID?
                var lastPTS = CMTime.invalid
                var advances = 0
                for _ in 0..<150 {
                    images.update(session: session, hostTime: CACurrentMediaTime())
                    if let frame = images.frame, visibleID != frame.id {
                        precondition(frame.timestamp.seconds >= 1.35)
                        precondition(!lastPTS.isValid || frame.timestamp > lastPTS)
                        precondition(frame.left.width == frame.right.width && frame.left.height == frame.right.height)
                        lastPTS = frame.timestamp
                        visibleID = frame.id
                        advances += 1
                    }
                    if advances >= 8 {
                        break
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                guard advances >= 8 else {
                    throw Check.movie
                }
                print("Live image playback advanced through \(advances) synchronized pairs")
                print(
                    "Live image output published a complete pair at \(frame.timestamp.seconds) s and invalidated it on seek"
                )
            }
            session.close()
            precondition(session.diagnostics.report.contains("decoded→texture"))
            precondition(session.file == nil && FileManager.default.fileExists(atPath: source.url.path))
            print("MV-HEVC delivered distinct left/right buffers in successive frames; close left the original intact")
        }
    }

    private static func samplePhoto(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { px in
            let context = CGContext(
                data: px.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private static func makeStereoPhoto(at url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 2, nil)!
        // Deliberately place the right eye first to exercise the Image I/O metadata.
        for left in [false, true] {
            let width = 128
            let graphite = CGColor(red: left ? 1 : 0, green: 0, blue: left ? 0 : 1, alpha: 1)
            let ctx = CGContext(
                data: nil, width: width, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(graphite)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: 128))
            let group: [CFString: Any] = [
                kCGImagePropertyGroupIndex: 0,
                kCGImagePropertyGroupType: kCGImagePropertyGroupTypeStereoPair,
                left ? kCGImagePropertyGroupImageIsLeftImage : kCGImagePropertyGroupImageIsRightImage: true,
                kCGImagePropertyGroupImageDisparityAdjustment: 0
            ]
            let camera: [CFString: Any] = [
                kIIOMetadata_CameraExtrinsicsKey: [
                    kIIOCameraExtrinsics_Position: [left ? 0.0 : 0.064, 0, 0],
                    kIIOCameraExtrinsics_Rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]
                ],
                kIIOMetadata_CameraModelKey: [
                    kIIOCameraModel_ModelType: kIIOCameraModelType_SimplifiedPinhole,
                    kIIOCameraModel_Intrinsics: [110, 0, 64, 0, 110, 64, 0, 0, 1]
                ]
            ]
            let props: [CFString: Any] = [
                kCGImagePropertyGroups: group, kCGImagePropertyHEIFDictionary: camera,
                kCGImagePropertyHasAlpha: false
            ]
            CGImageDestinationAddImage(destination, ctx.makeImage()!, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw Check.photo
        }
    }

    enum Check: Error { case gpu, photo, movie }
}
