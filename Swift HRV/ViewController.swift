//
//  ViewController.swift
//  Swift HRV
//
//  Created by Linda Cobb on 6/4/15.
//  Copyright (c) 2015 TimesToCome Mobile. All rights reserved.
//

// papers
// http://circ.ahajournals.org/content/91/7/1918.full
// http://www.journalsleep.org/Articles/220807.pdf
// http://www.atcormedical.com/pdf/TN13%20-%20HRV%20Performing%20and%20Understanding%20HRV%20Measurements.pdf


// wiki
// http://en.wikipedia.org/wiki/Heart_rate_variability

// HRV = variation in the time between heart beats
// Need 5 mins to 24 hours to obtain a true reading
// User must be stationary during data aquisition
// Really good data requires 250-1000Hz we're using 30Hz
// Should be able to bump phone video up to 120Hz **** look into this

///////////////////////////////////////////////////////////////////////////////
// To do and bugs
// graph is ugly - try spreading out points see if that helps
// redo power spectrum calcs now that we're processing at a good speed
// calculate HRV and all associated statisical data ...
// RR Interval
// LF Power
// SDNN
// RMSSD
// NN50
// Total Power
// HRV
///////////////////////////////////////////////////////////////////////////////


import UIKit
import Foundation
import AVFoundation
import QuartzCore
import CoreMedia
import Accelerate
import MobileCoreServices



// keep this here, since we are hard coding everything to save processing cycles
// this makes it easier to change iamge dimension information
let pixelsLuma = 1280 * 720             // Luma buffer (brightness)
let pixelsChroma = 174 * 144            // Chromiance buffer (color)
let pixelsUorVChroma = 25056 / 2        // split color into U and V


// same thing, hard coded FFT numbers, better to change them once here
let windowSize = 1024               // granularity of the measurement, error
let windowSizeOverTwo = 512         // for fft



class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate
{
    
    
    // UI stuff
    @IBOutlet var graphView: GraphView!
    @IBOutlet var powerView: VectorGraph!
    @IBOutlet var timeLabel: UILabel!
    @IBOutlet var pulseLabel: UILabel!
    @IBOutlet var HFBandLabel: UILabel!
    @IBOutlet var LFBandLabel: UILabel!

    var timeElapsedStart:NSDate!
    
 
    // camera stuff
    var session:AVCaptureSession!
    var videoInput : AVCaptureDeviceInput!
    var videoDevice:AVCaptureDevice!

    
    // put this here instead of buffer processing func 
    // to keep the processing loop as lean as possible
    // image processing stuff
    var lumaVector:[Float] = Array(count: pixelsLuma, repeatedValue: 0.0)   // brightness pixel data
    var averageLuma:Float = 0.0                                             // avearge brightness per frame

    
    
    // used to compute frames per second
    // put this up here so it doesn't get reset every function call
    var newDate:NSDate = NSDate()
    var oldDate:NSDate = NSDate()

    
    
    // needed to init image context
    var context:CIContext!
    
    
    
    // FFT setup stuff, also used in pulse calculations
    // keeping things lean and outside of the image processing functions
    var log2n:vDSP_Length = 0
    var fps:Float = 240.0                 // fps === hz, we're recalculating this on the fly in image loop
    var averageFPS:Float = 240.0
    var setup:COpaquePointer!
    
    
    // collects data from image and stores for fft
    var dataCount = 0                   // tracks how many data points we have ready for fft
    var fftLoopCount = 0                // how often we grab data between fft calls
    var inputSignal:[Float] = Array(count: windowSize, repeatedValue: 0.0)
    var fpsData:[Float] = Array(count: windowSize, repeatedValue: 0.0)
    
    
    // data smoothing
    // way too slow - maybe after every thing else is working I'll revisit this
   // var movingAverageArray:[CGFloat] = [0.0, 0.0, 0.0, 0.0, 0.0]      // used to store rolling average
   // var movingAverageCount:CGFloat = 5.0                              // window size
    
    
  
    
    
    // set up
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // set up memory for FFT
        log2n = vDSP_Length(log2(Double(windowSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        
        // init graphs
        graphView.setupGraphView()
        powerView.setupGraphView()
    }
    

    
      
    func setupCamera (){
    
        let videoDevices = AVCaptureDevice.devicesWithMediaType(AVMediaTypeVideo)
        
        
        // inputs - find and use back facing camera
        for device in videoDevices{
            if device.position == AVCaptureDevicePosition.Back {
                videoDevice = device as! AVCaptureDevice
            }
        }
        
        
        // set video input to back camera
        do { videoInput = try AVCaptureDeviceInput(device: videoDevice) } catch { return }
        
        
        
        // supporting formats 240 fps
        var bestFormat = AVCaptureDeviceFormat()
        var bestFrameRate = AVFrameRateRange()
        
        for format in videoDevice.formats {
            let ranges = format.videoSupportedFrameRateRanges as! [AVFrameRateRange]
            
            for range in ranges {
                if range.maxFrameRate >= 240 {
                    bestFormat = format as! AVCaptureDeviceFormat
                    bestFrameRate = range
                }
            }
        }
        
        
        
        // set highest fps
        do { try videoDevice.lockForConfiguration()
            
            videoDevice.activeFormat = bestFormat
            
            videoDevice.activeVideoMaxFrameDuration = bestFrameRate.maxFrameDuration
            videoDevice.activeVideoMinFrameDuration = bestFrameRate.minFrameDuration
            
            
            videoDevice.unlockForConfiguration()
        } catch { return }
    }
    
    
    
    
    
    
    
    
    // set up to grab live images from the camera
    func setupCaptureSession () {
        
        let dataOutput = AVCaptureVideoDataOutput()

        // set up session
        let sessionQueue = dispatch_queue_create("AVSessionQueue", DISPATCH_QUEUE_SERIAL)
        dataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        
        // no longer works in Swift 2.0 for iOS
        //dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey : kCVPixelFormatType_32BGRA]
        
        session = AVCaptureSession()
        
        
        // measure pulse from 40-230bpm = ~.5 - 4bps * 2 to remove aliasing need 8 frames/sec minimum
        // preset352x288 ~ 30fps
        // let's try 240 fps?
        session.sessionPreset = AVCaptureSessionPresetInputPriority
        
        
        
        
        // turn on light
        session.beginConfiguration()
        
        do { try videoDevice.lockForConfiguration()
        
            do { try videoDevice.setTorchModeOnWithLevel(AVCaptureMaxAvailableTorchLevel )
            } catch { return }      // torch mode
        
            videoDevice.unlockForConfiguration()

        } catch  { return }         // lock for config
        
        session.commitConfiguration()
        
        
        // start session
        session.addInput(videoInput)
        session.addOutput(dataOutput)
        session.startRunning()
        
    }
    
    
    
    
    
    
    // grab each camera image,
    // split into red, green, blue pixels,
    // compute average red, green blue pixel value per frame
    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
        
        
        // calculate our actual fps
        newDate = NSDate()
        fps = 1.0/Float(newDate.timeIntervalSinceDate(oldDate))
        oldDate = newDate
        
        
        // get the CVImageBuffer from the sample stream
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)

        // lock buffer
        CVPixelBufferLockBaseAddress(imageBuffer!, 0)
        
        
    
        //*************************************************************************
        // incoming is YUV format - get format info using this
        // let description = CMSampleBufferGetFormatDescription(sampleBuffer)
        //print(description)
        
        
        // yes you can grab the data every frame but we really need speed here so hard code every thing we can
        // we're also going to declare as many things as we can once as globals rather than recreate each pass
        // through the loop
        // 2 planes
        // width, height plane 0
        // width/2, height/2 plane 1
        // bits per block 8
        // CVImageBufferYCbCrMatrix
        
        
        //let height = CVPixelBufferGetHeight(imageBuffer!)
        //let width = CVPixelBufferGetWidth(imageBuffer!)
        //let numberOfPixels = height * width
        
        
        
        // collect brightness data
        let baseAddressLuma = CVPixelBufferGetBaseAddressOfPlane(imageBuffer!, 0)
        let dataBufferLuma = UnsafeMutablePointer<UInt8>(baseAddressLuma)

        
        // collect color data
        // not now luma is giving good data and much faster to process
       // let baseAddressChroma = CVPixelBufferGetBaseAddressOfPlane(imageBuffer!, 1)
        //let dataBufferChroma = UnsafeMutablePointer<UInt8>(baseAddressChroma)
        
        
        
        
        CVPixelBufferUnlockBaseAddress(imageBuffer!, 0)
        
        
        
        
        //* can use luma, chroma, chromaU or chromaV to get correct answer in 20 seconds
        //  none of the graphs look good. May need to pull out RGB for UI
        
        
        // get pixel data
        // brightness
        vDSP_vfltu8(dataBufferLuma, 1, &lumaVector, 1, vDSP_Length(pixelsLuma))
        vDSP_meamgv(&lumaVector, 1, &averageLuma, vDSP_Length(pixelsLuma))

        
        
        /*
        // pixel color data
        var chromaVector:[Float] = Array(count: pixelsChroma, repeatedValue: 0.0)
        vDSP_vfltu8(dataBufferChroma, 1, &chromaVector, 1, vDSP_Length(pixelsChroma))
        var averageChroma:Float = 0.0
        vDSP_meamgv(&chromaVector, 1, &averageChroma, vDSP_Length(pixelsChroma))

        // split color into U/V
        var chromaUVector:[Float] = Array(count: pixelsUorVChroma, repeatedValue: 0.0)  // Cb
        var chromaVVector:[Float] = Array(count: pixelsUorVChroma, repeatedValue: 0.0)  // Cr
        
        vDSP_vfltu8(dataBufferChroma, 2, &chromaUVector, 1, vDSP_Length(pixelsUorVChroma))
        vDSP_vfltu8(dataBufferChroma+1, 2, &chromaVVector, 1, vDSP_Length(pixelsUorVChroma))
        
        var averageUChroma:Float = 0.0
        var averageVChroma:Float = 0.0
        
        vDSP_meamgv(&chromaUVector, 1, &averageUChroma, vDSP_Length(pixelsUorVChroma))
        vDSP_meamgv(&chromaVVector, 1, &averageVChroma, vDSP_Length(pixelsUorVChroma))
        */
        
        
        
        // send to graph and fft
        // fft graph settles down when lock on pulse is good
        dispatch_async(dispatch_get_main_queue()){
            self.graphView.addX(Float(self.averageLuma))
            self.collectDataForFFT(Float(self.averageLuma))
        }

        
        // ? use this to convert image if the luma/chroma doesn't work ?
        // dunno - seen several formulas on difference sites, check this
        // ? R = Y - 1.403V'
        // B = Y + 1.770U'
        // G = Y - 0.344U' - 0.714V'

    }
    
    
    
    
    
    
    
    
    // grab data points from image
    // stuff the data points into an array
    // call fft after we collect a window worth of data points
    // Using total brightness rather than any one color to save processing cycles
    func collectDataForFFT( brightness: Float){
        
        
        // first fill up array
        if  dataCount < windowSize {
            inputSignal[dataCount] = brightness
            fpsData[dataCount] = fps
            
            dataCount++
            
            // then pop oldest off top push newest onto end
        }else{
            
            inputSignal.removeAtIndex(0)
            inputSignal.append(brightness)
            
            fpsData.removeAtIndex(0)
            fpsData.append(fps)
        }
        
        // call fft ~ once per second
        if  fftLoopCount > Int(fps) {
            
            vDSP_meamgv(&fpsData, 1, &averageFPS, vDSP_Length(windowSize))
            fftLoopCount = 0
            FFT()
        }else{
            fftLoopCount++;
        }
        
        
    }
    
    
    
    
    
    func FFT(){
        
        
        // parse data input into complex vector
        var zerosR = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        var zerosI = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        var cplxData = DSPSplitComplex( realp: &zerosR, imagp: &zerosI )

        
        // use raw unfiltered data
         let xAsComplex = UnsafePointer<DSPComplex>( inputSignal.withUnsafeBufferPointer { $0.baseAddress } )
         vDSP_ctoz( xAsComplex, 2, &cplxData, 1, vDSP_Length(windowSizeOverTwo) )
        
        
        //perform fft - float, real, discrete, in place
        vDSP_fft_zrip( setup, &cplxData, 1, log2n, FFTDirection(kFFTDirection_Forward) )
        
        
        
        //calculate power                                                                   
        var powerVector = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        vDSP_zvmags(&cplxData, 1, &powerVector, 1, vDSP_Length(windowSizeOverTwo))
        
        // find peak power and bin
        var power = 0.0 as Float
        var bin = 0 as vDSP_Length
        

        ///////////////////////////////////////////////////////////////////////////////
        //  calculate heart beats per minute
        // We're looking for the bin with the highest power ( strongest frequency )
        vDSP_maxvi(&powerVector+1, 1, &power, &bin, vDSP_Length(windowSizeOverTwo))
        bin += 1
        
        
        // push heart rate data to the user
        let timeElapsed = NSDate().timeIntervalSinceDate(timeElapsedStart)
        timeLabel.text = NSString(format: "Seconds: %d", Int(timeElapsed)) as String
        
        
        //let binSize = fps * 60.0 / Float(windowSize)
        //let errorSize = fps * 60.0 / Float(windowSize)
        
        // FPS are bouncy - use an avearge to calculate HR
        let bpm = Float(bin) / Float(windowSize) * (averageFPS * 60.0)
        pulseLabel.text = NSString(format: "%d BPM ", Int(bpm)) as String
        
        powerView.addAll(powerVector)

        
        
        /////////////////////////////////////////////////////////////////////////////
        //  are we drifting off to sleep?
        // heart rate between sympathetic and parasympathetic
        // transition to sleep drops power percent in low frequency band from 62-44% to 46-36%
        // measure total power between 0.04 hz and 0.5 hz
        // power low = 0.04-0.15 hz sympathetic activity   (bins 1..3)      // prepare body for action
        // power high = 0.15-0.5 hz parasympathetic activity (bins 3..9)    // tranquil functions, rest and digest, feed and breed
        // * We have a bit of overlap here, a window size of 512 isn't samll enough to sharply divide the two bands

        //var powerLow = powerVector[1] + powerVector[2] + powerVector[3]
        //var powerHigh = powerVector[3] + powerVector[4] + powerVector[5] + powerVector[6] + powerVector[7] + powerVector[8] + powerVector[9]
        //let totalPower = powerLow + powerHigh
        
        // clean up and send to user
       // powerLow = powerLow/totalPower
       // powerHigh = powerHigh/totalPower
      //  let ratio = log(powerLow/powerHigh)
       // powerLow *= 100.0
       // powerHigh *= 100.0
      //  HFBandLabel.text = ("High Frequency \(Int(powerHigh))")
       // LFBandLabel.text = ("Low Frequency \(Int(powerLow))")
        
        
        
        
        
        ///////////////////////////////////////////////////////////////////////////////////////////////////////
        // Heart rate variability
       
        
        // do we have another way to count peaks per minute?
        // find derivative, count sign changes?
        //let dataPointsPerTenSeconds = Int(fps * 10)         // need to keep this smaller than our window size
        
        
       // var smoothedData:[Float] = Array(count: dataPointsPerTenSeconds, repeatedValue: 0.0)
        
        
        
        /*
        var x1:[Float] = inputSignal
        x1.removeAtIndex(0)
        
        var dx:[Float] = Array(count: dataPointsPerTenSeconds, repeatedValue: 0.0)
        vDSP_vsub(inputSignal, 1, x1, 1, &dx, 1, vDSP_Length(dataPointsPerTenSeconds))
        
        var indexCrossing:vDSP_Length = 0
        var numberOfCrossings:vDSP_Length = 0
        
        vDSP_nzcros(dx, 1, vDSP_Length(dataPointsPerTenSeconds), &indexCrossing, &numberOfCrossings, vDSP_Length(dataPointsPerTenSeconds))
       // var heartRate = Int(numberOfCrossings / 2) * 6      // 10 * 6 = 60 seconds, two crossings per peak
        
        
        
        
        
        var sumPowerVector:Float = 0.0
        vDSP_sve(&powerVector+1, 1, &sumPowerVector, vDSP_Length(windowSize))
        
        if  sumPowerVector < 1.0 { print("locked ") }
        */
        
        
        /*
        
        let pointerToPowerVector = UnsafeMutablePointer<Float>(powerVector)

        var lowPower:Float = 0.0
        vDSP_sve(pointerToPowerVector+7, 1, &lowPower, vDSP_Length(20))     // sum low frequencies

        var highPower:Float = 0.0
        vDSP_sve(pointerToPowerVector+27, 1, &highPower, vDSP_Length(65))

            
            
        let logLowHigh = log(lowPower/highPower)
            
        //println("High \(highPower), low \(lowPower), log \(logLowHigh)")
            
        var lowBottom = 2.0 / Float(windowSize) * fps
        var border = 10.0 / Float(windowSize) * fps
        var highTop = 20.0 / Float(windowSize) * fps
            
       // println(" bottom \(lowBottom), border \(border), top \(highTop)")
        
        
*/
        
        
        

    }
    
    
    
    
    
    
    
    
    //////////////////////////////////////////////////////////////
    // UI start/stop camera
    //////////////////////////////////////////////////////////////
    @IBAction func stop(){
        session.stopRunning()           // stop camera
    }
    
    
    
    @IBAction func start(){
        
        // init graphs
        graphView.setupGraphView()
        powerView.setupGraphView()

        timeElapsedStart = NSDate()     // reset clock
        setupCamera()                   // setup device
        setupCaptureSession()           // start camera
    }
    
    
    
    
    
    
    //////////////////////////////////////////////////////////
    //    cleanup           //////////////////////////////////
    //////////////////////////////////////////////////////////
    override func viewDidDisappear(animated: Bool){
        
        super.viewDidDisappear(animated)
        stop()
    }
    
    
    
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    
}

