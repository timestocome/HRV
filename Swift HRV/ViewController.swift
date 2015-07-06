//
//  ViewController.swift
//  Swift HRV
//
//  Created by Linda Cobb on 6/4/15.
//  Copyright (c) 2015 TimesToCome Mobile. All rights reserved.
//

// papers, texts etc
// http://www.hrv4training.com/blog/heart-rate-variability-a-primer
//http://www.hrv4training.com/blog/heart-rate-variability-using-the-phones-camera

// wiki
// http://en.wikipedia.org/wiki/Heart_rate_variability

// HRV = variation in the time between heart beats
// Need 5 mins to 24 hours to obtain a true reading
// User must be stationary during data aquisition
// Really good data requires 250-1000Hz we're using 30Hz
// Should be able to bump phone video up to 120Hz **** look into this

///////////////////////////////////////////////////////////////////////////////
// To do and bugs
//
// calculate HRV and all associated statisical data ...
// HRV - heart rate variability - differences between R peaks in pulse
// higher stress lower HRV, lower stress greater HRV

// RR Interval - time difference between R peaks
// LF - power difference between 0.05-0.15hz (sympathetic)
// * HF - power band between 0.15-0.5Hz (parasympathetic)
// NN - RR invterval with any peak <> 20% of previous time diff discarded
// SDNN - standard deviation of NN intervals
// AVNN - mean of NN
// * rMSSD - root mean square of NN intervals
// pNN50 number of NN pairs differing by > 50 ms
//
// - if all is working well 1 minute of smoothed data should be sufficient

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


// same thing, hard coded FFT numbers, better to change them once here
// lower numbers converge faster and remain steady, but increase the error size
let windowSize = 4096             // granularity of the measurement, error
let windowSizeOverTwo = 2048         // for fft


let cameraFPS:Float = 240.0


// fastest, more accurate HR measurment uses
// 60 fps, window size of 1024
// minHRBin of 17 and max of 256 when finding max power



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
    var fps:Float = cameraFPS                                           // fps === hz, we're recalculating this on the fly in image loop
    var averageFPS:Float = cameraFPS
    var setup:COpaquePointer!
    
    
    
    // windowing stuff - used to remove high and low end of range
    // acts like a bandwidth filter and makes a dramatic difference in 
    // time it take sto get a firm HR reading
    let binSizeBPM = 1.0 / Float(windowSize) * (cameraFPS * 60.0)
    
    
    
    // adjust constants to remove hr <30bpm and > 300 bpm
    var minHRBinNumber:Int!
    var maxHRBinNumber:vDSP_Length!

    
    
    // collects data from image and stores for fft
    var dataCount = 0                   // tracks how many data points we have ready for fft
    var fftLoopCount = 0                // how often we grab data between fft calls
    var inputSignal:[Float] = Array(count: windowSize, repeatedValue: 0.0)
    var fpsData:[Float] = Array(count: windowSize, repeatedValue: 0.0)
    
    
    
    // measure low frequency/ high frequency ratio
    // moved here to minimize calculations inside processing loop
    var binHz:Float!
    var lowPowerBinStart:Int!
    var lowPowerBinEnd:Int!
    var highPowerBinStart:Int!
    var highPowerBinEnd:Int!
    
    
    // bandpass filter
    var bandpassFilter:[Float] = [0.0, 0.0, 0.0, 0.0, 0.0]

    
    
    // set up
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupFFT()
        setupBandpassFilter()
        
        setupGraphs()
        
        setupHRConstants()
        setupHFLFConstants()
    }
    
    
    
    func setupFFT(){
        // set up memory for FFT
        log2n = vDSP_Length(log2(Double(windowSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    
    
    func setupGraphs(){
        
        // init graphs
        graphView.setupGraphView()
        powerView.setupGraphView()

    }
    
    
    
    func setupHRConstants(){
        // adjust a few fps dependent constants
        // needed to calculate HR
        // adjust constants to remove hr <30bpm and > 300 bpm
        
        minHRBinNumber = Int(30.0 / binSizeBPM)
        maxHRBinNumber = vDSP_Length( 300.0 / binSizeBPM )

    }
    
    
    
    func setupHFLFConstants(){
        // set up constants for measuring LF/HF HRV
        binHz = 1.0 / Float(windowSize) * cameraFPS
        
        lowPowerBinStart = Int(0.05/binHz)
        lowPowerBinEnd = Int(0.15/binHz)
        highPowerBinStart = Int(0.15/binHz)
        highPowerBinEnd = Int(0.5/binHz)
    }
    
    
    
    func setupBandpassFilter(){
    
        // http://blog.mackerron.com/2014/02/04/vdsp_deq22-bandpass-filter/
        // try ? vdsp_deq22 bandpass filter
        
        let Ftop:Float = 300.0
        let Fbtm:Float = 30.0
        let samplingRate:Float = cameraFPS
        let centerFrequency:Float = sqrt(Fbtm * Ftop)
        let Q:Float = centerFrequency / (Ftop - Fbtm)
        let K:Float = tan(Float(M_PI) * centerFrequency/samplingRate )
        let Ksquared:Float = K * K
        let norm = 1.0 / (1.0 + K/Q + Ksquared)
        
        bandpassFilter[0] = (K / Q * norm)
        bandpassFilter[1] = 0.0
        bandpassFilter[2] = -bandpassFilter[0]
        bandpassFilter[3] = 2.0 * (Ksquared - 1.0) * norm
        bandpassFilter[4] = ((1.0 - K/Q + Ksquared) * norm)
    
    }
    
    
    
      
    func setupCamera( setFPS:Float){
    
        fps = Float(setFPS)
        
        let videoDevices = AVCaptureDevice.devicesWithMediaType(AVMediaTypeVideo)
        
        
        // inputs - find and use back facing camera
        for device in videoDevices{
            if device.position == AVCaptureDevicePosition.Back {
                videoDevice = device as! AVCaptureDevice
            }
        }
        
        
        // set video input to back camera
        do {
            videoInput = try AVCaptureDeviceInput(device: videoDevice) } catch { return }
        
        
        
        // supporting formats 240 fps
        var bestFormat = AVCaptureDeviceFormat()
        var bestFrameRate = AVFrameRateRange()
        
        for format in videoDevice.formats {
            let ranges = format.videoSupportedFrameRateRanges as! [AVFrameRateRange]
            
            for range in ranges {
                if range.maxFrameRate >= Float64(setFPS) {
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
    
    
    
    
    
    
    // grab each camera image, 200 hz is usually used on ECG
    //
    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
        
        
        // calculate our actual fps
        newDate = NSDate()
        fps = 1.0/Float(newDate.timeIntervalSinceDate(oldDate))
        oldDate = newDate
        
        
        // get the CVImageBuffer from the sample stream
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)

        // lock buffer
        CVPixelBufferLockBaseAddress(imageBuffer!, 0)
        
        
        // collect brightness data
        let baseAddressLuma = CVPixelBufferGetBaseAddressOfPlane(imageBuffer!, 0)
        let dataBufferLuma = UnsafeMutablePointer<UInt8>(baseAddressLuma)

        
        CVPixelBufferUnlockBaseAddress(imageBuffer!, 0)
        
        
        // get pixel data brightness
        vDSP_vfltu8(dataBufferLuma, 1, &lumaVector, 1, vDSP_Length(pixelsLuma))
        vDSP_meamgv(&lumaVector, 1, &averageLuma, vDSP_Length(pixelsLuma))

        
        
    
        // send to graph and fft
        // fft graph settles down when lock on pulse is good
        dispatch_async(dispatch_get_main_queue()){
          //  self.graphView.addX(Float(self.averageLuma))
            self.collectDataForFFT(Float(self.averageLuma))
        }

        
        

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

            fftLoopCount = 0

            // fps?
            vDSP_meamgv(&fpsData, 1, &averageFPS, vDSP_Length(windowSize))
        
            
            // need to smooth it here, butterworth band pass to remove dc component and HF noise
            var smoothedData:[Float] = Array(count: windowSize, repeatedValue: 0.0)
            vDSP_deq22(inputSignal, 1, bandpassFilter, &smoothedData, 1, vDSP_Length(windowSize-2))
            
            // fft and graph
            if ( dataCount >= windowSize ){
                graphView.addAll(smoothedData)
            }
            FFT(smoothedData)
            
        }else{
            fftLoopCount++;
        }
        
        
    }
    
    
    
    
    
    func FFT(smoothedData:[Float]){
        
        // peak detection slope inversion algorithm? * look this up
        // or just use derivative? need to avoid double peaks counting as two
        
        
        // ditch artifacts
        // he used a 10 second window and ditched peaks <> 20% of previous
        // also ditched windows with less than 4 peaks or more than 50% of peaks removed
        

        
        // parse data input into complex vector
        var zerosR = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        var zerosI = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        var cplxData = DSPSplitComplex( realp: &zerosR, imagp: &zerosI )

        
        // Heart rate variability
        
        // collect RR intervals in time domain
        
        // remove RR intervals <> 20% of previous time diff
        
        // interpolate NN at 4Hz ( 1 point every 250 ms) ( need evenly spaced data for fft )
        // vDSP_lint?
        
        // remove DC component
        
        // convert to seconds
        
        
        ////////////////////////////////////////////////////////////////////////////////////////////
        // FFT
        // cast smoothed data as complex
        let xAsComplex = UnsafePointer<DSPComplex>( smoothedData.withUnsafeBufferPointer { $0.baseAddress } )
        vDSP_ctoz( xAsComplex, 2, &cplxData, 1, vDSP_Length(windowSizeOverTwo) )

        
        // cast original data as complex
       //  let xAsComplex = UnsafePointer<DSPComplex>( inputSignal.withUnsafeBufferPointer { $0.baseAddress } )
       //  vDSP_ctoz( xAsComplex, 2, &cplxData, 1, vDSP_Length(windowSizeOverTwo) )
        
        //perform fft - float, real, discrete, in place
        vDSP_fft_zrip( setup, &cplxData, 1, log2n, FFTDirection(kFFTDirection_Forward) )
        
        //calculate power                                                                   
        var powerVector = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        vDSP_zvmags(&cplxData, 1, &powerVector, 1, vDSP_Length(windowSizeOverTwo))
        
        
        
        
        calculateHeartRate(powerVector)

        calculateHF_LF(powerVector)
        
        calculateStats()
        

    }
    
    
    
    
    func calculateStats (){
    
        // RR interval, need time difference between R peaks
        
        // NN is RR interval with junk cleaned out (diff > 20%)
        
        
        // AVNN - mean NN - use
        // vDSP_meanv ?
        
        
        // SDNN - standard deviation
        // vDSP_rmsqv ? of  sqrt ( sum (NN - AVNN)^2 / n )
        
        
        // rMSSD - root mean square of NN intervals
        // sqrt ( sum ( NN(x) - NN(x-1) )^2 )/(n-1) )
        // vDSP_rmsqv ?
        
        
        // pNN50 - number of NN pairs > 50ms different than previous
        // n50 / n * 100
        
    }
    
    
    
    
    // heart rate between sympathetic and parasympathetic
    // transition to sleep drops power percent in low frequency band from 62-44% to 46-36%
    // athletes have high HRV, couch potatoes low
    // can also be used to measure if we are over training
    // power low = 0.05-0.15 hz sympathetic activity                    // prepare body for action
    // power high = 0.15-0.5 hz parasympathetic activity                // tranquil functions, rest and digest, feed and breed
    func calculateHF_LF(powerVector:[Float]){
    
        
        let powerLowVector = Array(powerVector[lowPowerBinStart...lowPowerBinEnd])
        let powerHighVector = Array(powerVector[highPowerBinStart...highPowerBinEnd])
        var powerLow:Float = 0.0
        var powerHigh:Float = 0.0
        vDSP_sve(powerLowVector, 1, &powerLow, vDSP_Length(powerLowVector.count))
        vDSP_sve(powerHighVector, 1, &powerHigh, vDSP_Length(powerHighVector.count))
    
    
        let totalPower = powerLow + powerHigh
    
        // clean up and send to user
        powerLow = powerLow/totalPower
        powerHigh = powerHigh/totalPower
        let ratio = log(powerLow/powerHigh)
        powerLow *= 100.0
        powerHigh *= 100.0
        HFBandLabel.text = ("High Frequency \(Int(powerHigh))")
        LFBandLabel.text = ("Low Frequency \(Int(powerLow))")
    
    
      //  print("Ratio: \(ratio) PowerLow \(powerLow), PowerHigh \(powerHigh)")

    
    }
    
    
    
    
    func calculateHeartRate (powerVector:[Float]){
    
        
        // find peak power and bin
        var power = 0.0 as Float
        var bin = 0 as vDSP_Length
        var powerData = powerVector
        

        //  calculate heart beats per minute ( pulse )
        // We're looking for the bin with the highest power ( strongest frequency )
        vDSP_maxvi(&powerData+minHRBinNumber, 1, &power, &bin, maxHRBinNumber)
        let selectedBin = Int(bin) +  Int(minHRBinNumber)
        
        
        // push heart rate data to the user
        let timeElapsed = NSDate().timeIntervalSinceDate(timeElapsedStart)
        timeLabel.text = NSString(format: "Seconds: %d", Int(timeElapsed)) as String
        
        
        
        // dump reasonable data to user
        let bpm = Float(selectedBin) * binSizeBPM
        if bpm > 35 && bpm < 250 {
            pulseLabel.text = NSString(format: "%d BPM ", Int(bpm)) as String
        }
        
        
        // draw power graph
        let startPosition:Int = minHRBinNumber
        let endPosition = minHRBinNumber + Int(maxHRBinNumber)
        let pulsePowerVector = Array(powerVector[startPosition..<endPosition])
        powerView.addAll(pulsePowerVector)

    
    }
    
    
    
    
    //////////////////////////////////////////////////////////////
    // UI start/stop camera
    //////////////////////////////////////////////////////////////
    @IBAction func stop(){
        session.stopRunning()           // stop camera
    }
    
    
    
    @IBAction func start(){
        
        // init graphs
        setupGraphs()

        timeElapsedStart = NSDate()     // reset clock
        setupCamera(cameraFPS)          // setup device with preferred frames per second
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

