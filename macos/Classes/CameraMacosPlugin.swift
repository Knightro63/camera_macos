import Cocoa
import FlutterMacOS
import AVFoundation

public class CameraMacosPlugin: NSObject, FlutterPlugin, FlutterTexture, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    
    
    
    let registry: FlutterTextureRegistry
    
    // Texture id of the camera preview
    var textureId: Int64!
    
    // Capture session of the camera
    var captureSession: AVCaptureSession!
    
    // The selected camera
    var device: AVCaptureDevice!
    
    // Image to be sent to the texture
    var latestBuffer: CVImageBuffer!
    
    // Output channel for calling Flutter-code methods
    var outputChannel: FlutterMethodChannel!
    
    // Semaphore variable
    var isTakingPicture: Bool = false
    var isRecording: Bool = false
    
    init(_ registry: FlutterTextureRegistry, _ outputChannel: FlutterMethodChannel) {
        self.registry = registry
        self.outputChannel = outputChannel
        super.init()
    }
   
    public static func register(with registrar: FlutterPluginRegistrar) {
        let inputChannel = FlutterMethodChannel(name: "camera_macos", binaryMessenger: registrar.messenger)
        let outputChannel = FlutterMethodChannel(name: "camera_macos", binaryMessenger: registrar.messenger)
        let instance = CameraMacosPlugin(registrar.textures, outputChannel)
        registrar.addMethodCallDelegate(instance, channel: inputChannel)
    }
    
    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        if latestBuffer == nil {
            return nil
        }
        return Unmanaged<CVPixelBuffer>.passRetained(latestBuffer)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            guard let arguments = call.arguments as? Dictionary<String, Any> else {
                result(FlutterError(code: "INVALID_ARGS", message: "", details: nil))
                return
            }
            initCamera(arguments, result)
        case "takePicture":
            takePicture(result)
        case "startRecording":
            startRecording(result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    func initCamera(_ arguments: Dictionary<String, Any>, _ result: @escaping FlutterResult) {
        textureId = registry.register(self)
        captureSession = AVCaptureSession()
        var isPhoto: Bool = true
        if let sessionPresetArg = arguments["type"] as? Int {
            switch(sessionPresetArg) {
            case 0:
                captureSession.sessionPreset = .photo
            case 1:
                captureSession.sessionPreset = .hd1280x720
                isPhoto = false
            default:
                captureSession.sessionPreset = .photo
            }
        }
        guard let newCameraObject: AVCaptureDevice = AVCaptureDevice.captureDevice(with: .front) else {
            result(FlutterError(code: "CAMERA_INITIALIZATION_ERROR", message: "Could not find a suitable camera on this device", details: nil))
            return
        }
        device = newCameraObject
        guard let device = device else {
            result(FlutterError(code: "CAMERA_INITIALIZATION_ERROR", message: "Could not find a suitable camera on this device", details: nil))
            return
        }
        do {
            let focusPoint: CGPoint = .init(x: 0.5, y: 0.5)
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = focusPoint
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = focusPoint
                device.exposureMode = AVCaptureDevice.ExposureMode.continuousAutoExposure
            }
            device.unlockForConfiguration()
            
            let input = try AVCaptureDeviceInput(device: device)
            
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            var outputInitialized: Bool = false
            if isPhoto {
                // Add camera output
                var pictureOutput: AVCaptureOutput!
                if #available(macOS 10.15, *) {
                    pictureOutput = AVCapturePhotoOutput()
                } else {
                    pictureOutput = AVCaptureStillImageOutput()
                }
                if let pictureOutput = pictureOutput, captureSession.canAddOutput(pictureOutput) {
                    outputInitialized = true
                    captureSession.addOutput(pictureOutput)
                    for connection in pictureOutput.connections {
                        if connection.isVideoMirroringSupported {
                            connection.isVideoMirrored = true
                        }
                    }
                }
            } else {
                // Add video output.
                let videoOutput = AVCaptureMovieFileOutput()
                
                if captureSession.canAddOutput(videoOutput) {
                    outputInitialized = true
                    captureSession.addOutput(videoOutput)
                    
                    for connection in videoOutput.connections {
                        if connection.isVideoMirroringSupported {
                            connection.isVideoMirrored = true
                        }
                    }
                }
            }
            
            guard outputInitialized else {
                result(FlutterError(code: "CAMERA_INITIALIZATION_ERROR", message: "Could not initialize output for camera", details: nil))
                return
            }
            
            captureSession.commitConfiguration()
            captureSession.startRunning()
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let size = ["width": Double(dimensions.width), "height": Double(dimensions.height)]
            let answer: [String : Any?] = ["textureId": textureId, "size": size]
            result(answer)
            
        } catch(let error) {
            result(FlutterError(code: "CAMERA_INITIALIZATION_ERROR", message: error.localizedDescription, details: nil))
            return
        }
        
        
    }
    
    func takePicture(_ result: @escaping FlutterResult) {
        var output: AVCaptureOutput?
        if #available(macOS 10.15, *) {
            output = captureSession.outputs.first as? AVCapturePhotoOutput
        } else {
            output = captureSession.outputs.first as? AVCaptureStillImageOutput
        }
        guard let output = output else {
            result(FlutterError(code: "CAMERA_INITIALIZATION_ERROR", message: "captureSession Output not found", details: nil))
            return
        }
        guard let outputChannel = outputChannel else {
            result(FlutterError(code: "CAMERA_INITIALIZATION_ERROR", message: "Missing output channel", details: nil))
            return
        }
        if(!isTakingPicture) {
            isTakingPicture = true
            if #available(macOS 10.15, *) {
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                (output as! AVCapturePhotoOutput).capturePhoto(with: settings, delegate: self)
                result(true)
            } else {
                guard let connection = output.connections.first else {
                    result(false)
                    outputChannel.invokeMethod("onPictureTaken", arguments: ["error": FlutterError(code: "AVConnection object error", message: "Already taking picture", details: nil)])
                    return
                }
                (output as! AVCaptureStillImageOutput).captureStillImageAsynchronously(from: connection) { buffer, error in
                    if let error = error {
                        outputChannel.invokeMethod("onPictureTaken", arguments: ["error": FlutterError(code: "PHOTO_OUTPUT_ERROR", message: error.localizedDescription, details: nil) ])
                    } else if let buffer = buffer, let imageNSData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(buffer) {
                        outputChannel.invokeMethod("onPictureTaken", arguments: ["imageData": Data(imageNSData), "error": nil])
                    }
                }
                result(true)
            }
            isTakingPicture = false
        } else {
            result(FlutterError(code: "CONCURRENCY_ERROR", message: "Already taking picture", details: nil))
        }
    }
    
    @available(macOS 10.15,*)
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let outputChannel = outputChannel else {
            fatalError("Missing output channel")
        }
        if let error = error {
            outputChannel.invokeMethod("onPictureTaken", arguments: ["error": FlutterError(code: "PHOTO_OUTPUT_ERROR", message: error.localizedDescription, details: nil)])
        } else {
            guard let imageData = photo.fileDataRepresentation(), !imageData.isEmpty
                else {
                outputChannel.invokeMethod("onPictureTaken", arguments: ["error": FlutterError(code: "PHOTO_OUTPUT_ERROR", message: "imageData is empty or invalid", details: nil)])
                return
            }
            outputChannel.invokeMethod("onPictureTaken", arguments: ["imageData": imageData, "error": nil])
        }
    }
    
    func startRecording(_ result: @escaping FlutterResult) {
        guard let output = captureSession.outputs.first as? AVCaptureMovieFileOutput else {
            result(FlutterError(code: "CAMERA_INITIALIZATION_ERROR", message: "captureSession Output not found", details: nil))
            return
        }
        if(!isRecording) {
            isRecording = true
            let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            let fileUrl = paths[0].appendingPathComponent("output.mp4")
            try? FileManager.default.removeItem(at: fileUrl)
            output.startRecording(to: fileUrl, recordingDelegate: self)
            result(true)
            isRecording = false
        } else {
            result(FlutterError(code: "CONCURRENCY_ERROR", message: "Already recording video", details: nil))
        }
    }
    
    
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        guard let outputChannel = outputChannel else {
            fatalError("Missing output channel")
        }
        if let error = error {
            outputChannel.invokeMethod("onVideoTaken", arguments: ["error": FlutterError(code: "VIDEO_OUTPUT_ERROR", message: error.localizedDescription, details: nil)])
        } else {
            guard let videoNSData = NSData(contentsOf: outputFileURL), !videoNSData.isEmpty
                else {
                outputChannel.invokeMethod("onVideoTaken", arguments: ["error": FlutterError(code: "VIDEO_OUTPUT_ERROR", message: "imageData is empty or invalid", details: nil)])
                return
            }
            let videoData = Data(videoNSData)
            outputChannel.invokeMethod("onVideoTaken", arguments: ["videoData": videoData, "error": nil])
        }
    }
    
}
