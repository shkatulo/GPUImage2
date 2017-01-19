import AVFoundation

public class MovieInput: ImageSource {
    public let targets = TargetContainer()
    public var runBenchmark = false
    
    public let ErrorDomain = "MovieInputError"
    public let ErrorCodeLoadValues = 1
    public let ErrorCodeAssetReader = 2
    public let ErrorCodeStartReading = 2
    
    let yuvConversionShader:ShaderProgram
    let asset:AVAsset
    var assetReader:AVAssetReader?
    public let playAtActualSpeed:Bool
    public var loop:Bool = false
    public var playSound:Bool = true
    public var soundVolume:Float = 1.0 {
        didSet {
            self.audioPlayer?.volume = self.soundVolume
        }
    }
    var videoEncodingIsFinished = false
    var audioEncodingIsFinished = false
    var previousFrameTime = kCMTimeZero
    var previousActualFrameTime = CFAbsoluteTimeGetCurrent()
    
    var readerVideoTrackOutput:AVAssetReaderOutput?
    var readerAudioTrackOutput:AVAssetReaderOutput?

    var numberOfFramesCaptured = 0
    var totalFrameTimeDuringCapture:Double = 0.0
    var hasAudioTrack:Bool = false
    
    var audioPlayer: AVAudioPlayer?
    var startActualFrameTime: CFAbsoluteTime = 0.0
    var currentVideoTime: Double = 0.0
    
    public private(set) var duration: Double = 0.0
    public private(set) var currentTime: Double = 0.0
    public var onFinish: ((MovieInput) -> Void)?
    public var onFail: ((MovieInput, Error) -> Void)?
    public var onProgressChange: ((MovieInput) -> Void)?
    
    public var audioEncodingTarget:AudioEncodingTarget? {
        didSet {
            guard audioEncodingTarget != nil else {
                self.removeAudioInputsAndOutputs()
                return
            }
            
            do {
                try self.addAudioInputsAndOutputs()
                audioEncodingTarget?.activateAudioTrack()
            }
            catch {
                fatalError("ERROR: Could not connect audio target with error: \(error)")
            }
        }
    }
    

    // TODO: Add movie reader synchronization
    // TODO: Someone will have to add back in the AVPlayerItem logic, because I don't know how that works
    public init(asset:AVAsset, playAtActualSpeed:Bool = false, loop:Bool = false, playSound:Bool = true) throws {
        self.asset = asset
        self.playAtActualSpeed = playAtActualSpeed
        self.loop = loop
        self.playSound = playSound
        self.yuvConversionShader = crashOnShaderCompileFailure("MovieInput"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader:YUVConversionFullRangeFragmentShader)}
        
        self.initAssetReader()
    }

    public convenience init(url:URL, playAtActualSpeed:Bool = false, loop:Bool = false, playSound:Bool = true) throws {
        let inputOptions = [AVURLAssetPreferPreciseDurationAndTimingKey:NSNumber(value:true)]
        let inputAsset = AVURLAsset(url:url, options:inputOptions)
        try self.init(asset:inputAsset, playAtActualSpeed:playAtActualSpeed, loop:loop, playSound:playSound)
    }
    
    private func initAssetReader() {
        self.assetReader = try? AVAssetReader(asset:self.asset)
        
        let outputSettings:[String:AnyObject] = [(kCVPixelBufferPixelFormatTypeKey as String):NSNumber(value:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))]
        let videoTrack = self.asset.tracks(withMediaType: AVMediaTypeVideo)[0]
        readerVideoTrackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings:outputSettings)
        readerVideoTrackOutput!.alwaysCopiesSampleData = false
        assetReader?.add(readerVideoTrackOutput!)
        
        duration = CMTimeGetSeconds(videoTrack.timeRange.duration)
        currentTime = 0.0
        
        // Prepare audio
        if self.playSound {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: (asset as! AVURLAsset).url)
            }
            catch let error as NSError {
                NSLog("Failed to initialise sound with error: %@", error)
            }
            
            audioPlayer?.prepareToPlay()
        }
    }

    // MARK: -
    // MARK: Playback control

    public func start() {
        if self.assetReader == nil {
            self.initAssetReader()
        }
        
        // Audio
        currentVideoTime = 0.0
        videoEncodingIsFinished = false
        audioEncodingIsFinished = (self.readerAudioTrackOutput == nil || self.audioEncodingTarget == nil)
        
        // Play video
        asset.loadValuesAsynchronously(forKeys:["tracks"], completionHandler:{
            guard (self.asset.statusOfValue(forKey: "tracks", error:nil) == .loaded) else {
                self.onFail?(self, NSError(domain: self.ErrorDomain, code: self.ErrorCodeLoadValues, userInfo: nil))
                return
            }
            guard self.assetReader != nil else {
                self.onFail?(self, NSError(domain: self.ErrorDomain, code: self.ErrorCodeAssetReader, userInfo: nil))
                return
            }
            
            let finishBlock = {
                if (self.assetReader?.status == .completed) {
                    self.assetReader!.cancelReading()
                    
                    self.onFinish?(self)

                    if (self.loop) {
                        self.cancel()
                        self.start()
                    }
                    else {
                        self.endProcessing()
                    }
                }
            }
            
            
            // Audio
            let readAudioFunc = {
                if self.readerAudioTrackOutput != nil && self.audioEncodingTarget != nil {
                    DispatchQueue.global().async {
                        // Audio reading
                        while (!self.audioEncodingIsFinished && self.assetReader?.status == .reading) {
                            self.readNextAudioSample(from: self.readerAudioTrackOutput!)
                        }
                        
                        self.audioEncodingTarget?.markAudioAsFinished()
                        
                        finishBlock()
                    }
                }
            }
            
            
            // Video
            DispatchQueue.global().async {
                guard self.assetReader!.startReading() else {
                    self.onFail?(self, NSError(domain: self.ErrorDomain, code: self.ErrorCodeStartReading, userInfo: nil))
                    print("Couldn't start reading")
                    return
                }
                
                // Audio playback
                self.startActualFrameTime = CFAbsoluteTimeGetCurrent() - self.currentVideoTime;

                let audioTracks = self.asset.tracks(withMediaType: AVMediaTypeAudio)
                self.hasAudioTrack = (audioTracks.count > 0)

                if (self.playSound && self.hasAudioTrack) {
                    self.audioPlayer?.currentTime = self.currentVideoTime
                    self.audioPlayer?.play()
                }

                // Video reading
                var audioStarted = false
                while (!self.videoEncodingIsFinished && self.assetReader?.status == .reading) {
                    self.readNextVideoFrame(from:self.readerVideoTrackOutput!)
                    
                    if !audioStarted {
                        audioStarted = true
                        readAudioFunc()
                    }
                }
                
                finishBlock()
            }
        })
    }
    
    public func cancel() {
        objc_sync_enter(self)
        
        assetReader?.cancelReading()
        assetReader = nil
        
        self.endProcessing()
        
        objc_sync_exit(self)
    }
    
    func endProcessing() {
        // Audio
        self.audioPlayer?.stop()
    }
    
    // MARK: -
    // MARK: Internal processing functions
    
    func readNextVideoFrame(from videoTrackOutput:AVAssetReaderOutput) {
        guard (!videoEncodingIsFinished) else { return }
        guard (assetReader?.status == .reading) else { return }
        
        objc_sync_enter(self)
        let sampleBuffer = videoTrackOutput.copyNextSampleBuffer()
        objc_sync_exit(self)
        
        if sampleBuffer != nil {
            let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer!)
            
            currentTime = CMTimeGetSeconds(currentSampleTime)
            onProgressChange?(self)
            
            if (playAtActualSpeed) {
                // Do this outside of the video processing queue to not slow that down while waiting
                let currentActualTime = CFAbsoluteTimeGetCurrent()
                
                // Audio
                let frameTimeOffset = CMTimeGetSeconds(currentSampleTime)
                var actualTimeOffset = currentActualTime - startActualFrameTime
                if (self.playSound && hasAudioTrack && (self.audioPlayer?.isPlaying)!) {
                    actualTimeOffset = (audioPlayer?.currentTime)!
                }
                
                if (frameTimeOffset > actualTimeOffset) {
                    usleep(UInt32(round(1000000.0 * (frameTimeOffset - actualTimeOffset))))
                }
                
                previousFrameTime = currentSampleTime
                previousActualFrameTime = CFAbsoluteTimeGetCurrent()
                
                currentVideoTime = CMTimeGetSeconds(currentSampleTime)
            }

            sharedImageProcessingContext.runOperationSynchronously{
                self.process(movieFrame:sampleBuffer!)
                CMSampleBufferInvalidate(sampleBuffer!)
            }
        } else {
            if (!loop) {
                videoEncodingIsFinished = true
                if (videoEncodingIsFinished && audioEncodingIsFinished) {
                    self.endProcessing()
                }
            }
        }
    }
    
    func process(movieFrame frame:CMSampleBuffer) {
        let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(frame)
        let movieFrame = CMSampleBufferGetImageBuffer(frame)!
    
//        processingFrameTime = currentSampleTime
        self.process(movieFrame:movieFrame, withSampleTime:currentSampleTime)
    }
    
    func process(movieFrame:CVPixelBuffer, withSampleTime:CMTime) {
        let bufferHeight = CVPixelBufferGetHeight(movieFrame)
        let bufferWidth = CVPixelBufferGetWidth(movieFrame)
        CVPixelBufferLockBaseAddress(movieFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))

        let conversionMatrix = colorConversionMatrix601FullRangeDefault
        // TODO: Get this color query working
//        if let colorAttachments = CVBufferGetAttachment(movieFrame, kCVImageBufferYCbCrMatrixKey, nil) {
//            if(CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == .EqualTo) {
//                _preferredConversion = kColorConversion601FullRange
//            } else {
//                _preferredConversion = kColorConversion709
//            }
//        } else {
//            _preferredConversion = kColorConversion601FullRange
//        }
        
        let startTime = CFAbsoluteTimeGetCurrent()

        let luminanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:true)
        luminanceFramebuffer.lock()
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), luminanceFramebuffer.texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(movieFrame, 0))
        
        let chrominanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:true)
        chrominanceFramebuffer.lock()
        glActiveTexture(GLenum(GL_TEXTURE1))
        glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceFramebuffer.texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), 0, GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(movieFrame, 1))
        
        let movieFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:false)
        
        convertYUVToRGB(shader:self.yuvConversionShader, luminanceFramebuffer:luminanceFramebuffer, chrominanceFramebuffer:chrominanceFramebuffer, resultFramebuffer:movieFramebuffer, colorConversionMatrix:conversionMatrix)
        CVPixelBufferUnlockBaseAddress(movieFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))

        movieFramebuffer.timingStyle = .videoFrame(timestamp:Timestamp(withSampleTime))
        self.updateTargetsWithFramebuffer(movieFramebuffer)
        
        if self.runBenchmark {
            let currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime)
            self.numberOfFramesCaptured += 1
            self.totalFrameTimeDuringCapture += currentFrameTime
            print("Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.numberOfFramesCaptured)) ms")
            print("Current frame time : \(1000.0 * currentFrameTime) ms")
        }
    }

    public func transmitPreviousImage(to target:ImageConsumer, atIndex:UInt) {
        // Not needed for movie inputs
    }
    
    
    
    // MARK: -
    // MARK: Audio processing
    
    func addAudioInputsAndOutputs() throws {
        guard (readerAudioTrackOutput == nil) else { return }
        
        let audioTracks = self.asset.tracks(withMediaType: AVMediaTypeAudio)
        if audioTracks.count > 0 {
            readerAudioTrackOutput = AVAssetReaderTrackOutput(track:audioTracks[0], outputSettings:nil)
            readerAudioTrackOutput!.alwaysCopiesSampleData = false
            assetReader?.add(readerAudioTrackOutput!)
        }
    }
    
    
    
    func removeAudioInputsAndOutputs() {
        guard (readerAudioTrackOutput != nil) else { return }
        
        readerAudioTrackOutput = nil
    }
    
    
    
    func readNextAudioSample(from audioTrackOutput:AVAssetReaderOutput) {
        guard (!audioEncodingIsFinished) else { return }
        guard (assetReader!.status == .reading) else { return }
        
        objc_sync_enter(self)
        let audioSampleBufferRef = readerAudioTrackOutput?.copyNextSampleBuffer()
        objc_sync_exit(self)
        
        if audioSampleBufferRef != nil {
            self.audioEncodingTarget?.processAudioBuffer(audioSampleBufferRef!)
        }
        else {
            if (!loop) {
                audioEncodingIsFinished = true
                if (videoEncodingIsFinished && audioEncodingIsFinished) {
                    self.endProcessing()
                }
            }
        }
    }
}
