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
// Really good data requires 250-1000Hz we're using 240Hz

///////////////////////////////////////////////////////////////////////////////
// To do and bugs
//
// windowSize/fps should give window time frame for using to convert to bpm etc
// number isn't quite correct
//
// clean up code this is a rat's nest


///////////////////////////////////////////////////////////////////////////////


import UIKit
import Foundation
import AVFoundation
import QuartzCore
import CoreMedia
import Accelerate
import MobileCoreServices



////////////////////////////////////////////////////////////////////////////////
// constants
////////////////////////////////////////////////////////////////////////////////

// keep this here, since we are hard coding everything to save processing cycles
// this makes it easier to change iamge dimension information
let pixelsLuma = 1280 * 720             // Luma buffer (brightness)


// same thing, hard coded FFT numbers, better to change them once here
// lower numbers converge faster and remain steady, but increase the error size
let windowSize = 4096             // granularity of the measurement, error
let windowSizeOverTwo = 2048         // for fft

let cameraFPS:Float = 240.0
let secondsPerWindow = 17       // 4096/240fps ~17 seconds per window


// used for band pass filter
let minBPM:Float = 30.0
let maxBPM:Float = 200.0






class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate
{
    
    
    // UI stuff
    @IBOutlet var graphView: GraphView!
    @IBOutlet var timeLabel: UILabel!
    @IBOutlet var pulseLabel: UILabel!
    
    @IBOutlet var HFBandLabel: UILabel!
    @IBOutlet var LFBandLabel: UILabel!
    @IBOutlet var ratioLabel: UILabel!
    
    @IBOutlet var avnnLabel: UILabel!
    @IBOutlet var sdnnLabel: UILabel!
    @IBOutlet var rmssdLabel: UILabel!
    @IBOutlet var pnn50Label: UILabel!
    @IBOutlet var n50Label: UILabel!
    @IBOutlet var rrIntervalLabel:UILabel!
    @IBOutlet var peaksPerMinuteLabel:UILabel!
    

    var timeElapsedStart:NSDate!
    
 
    
    // camera stuff
    var session:AVCaptureSession!                                           // setup, start and stop camera
    var videoInput : AVCaptureDeviceInput!                                  // camera
    var videoDevice:AVCaptureDevice!                                        // camera

    
    
    // put this here instead of buffer processing func 
    // to keep the processing loop as lean as possible
    // image processing stuff
    var lumaVector:[Float] = Array(count: pixelsLuma, repeatedValue: 0.0)   // brightness pixel data
    var averageLuma:Float = 0.0                                             // avearge brightness per frame

    
    
    // used to compute actual frames per second
    // put this up here so it doesn't get reset every function call
    var newDate:NSDate = NSDate()
    var oldDate:NSDate = NSDate()

    
    
    
    
    // FFT setup stuff, also used in pulse calculations
    // keeping things lean and outside of the image processing functions
    var log2n:vDSP_Length = 0
    var fps:Float = cameraFPS                                           // fps === hz, we're recalculating this on the fly in image loop
    var setup:COpaquePointer!                                           // setup memory once, then call each time we FFT
    
    
    
    
    
    // collects data from image and stores for fft
    var dataCount = 0                   // tracks how many data points we have ready for fft
    var fftLoopCount = 0                // how often we grab data between fft calls

    var inputSignal:[Float] = Array(count: windowSize, repeatedValue: 0.0)// raw input data
    var fpsData:[Float] = Array(count: windowSize, repeatedValue: 0.0)      // averages fps
    
  
    
    
    
    // measure low frequency/ high frequency ratio
    // moved here to minimize calculations inside processing loop
    var binHz:Float!
    var lowPowerBinStart:Int!
    var lowPowerBinEnd:Int!
    var highPowerBinStart:Int!
    var highPowerBinEnd:Int!
    
    
    // stores heart beats per minute for use in HRV calculations
    var numberOfPeaksArray:[Float] = Array(count:1, repeatedValue: 0.0)
    var rrIntervalArray:[Float] = Array(count: 1, repeatedValue: 0.0)
    
    
    // set up filter array once, then reuse
    var bandpassFilter:[Float] = Array(count: 5, repeatedValue: 0.0)
    
    
    
    
    
    // set up
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupGraphs()

        setupFFT()
        
        setupBandpassFilter()
        
        setupHFLFConstants()
    }
    
    
    // setup memory for FFT before first call to vDSP FFT
    func setupFFT(){
        log2n = vDSP_Length(log2(Double(windowSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    
    // needed on start and when restarting camera
    func setupGraphs(){
        
        // init graphs
        graphView.setupGraphView()

    }
    
    
    
    // high / low frequency calculated once each second, only need
    // to calculate this once
    func setupHFLFConstants(){
        // set up constants for measuring LF/HF HRV
        binHz = 1.0 / Float(windowSize) * cameraFPS
        
        lowPowerBinStart = Int(0.05/binHz)
        lowPowerBinEnd = Int(0.15/binHz)
        highPowerBinStart = Int(0.15/binHz) + 1
        highPowerBinEnd = Int(0.5/binHz)
        print("bin size: \(binHz)  lf bins \(lowPowerBinStart) ... \(lowPowerBinEnd), hf bins \(highPowerBinStart) ... \(highPowerBinEnd)")
    
    }
    
    
    
    // set up filter constants on start, no need to call each second
    func setupBandpassFilter(){
    
        // http://blog.mackerron.com/2014/02/04/vdsp_deq22-bandpass-filter/
        // http://www.earlevel.com/main/2013/10/13/biquad-calculator-v2/
        // try ? vdsp_deq22 bandpass filter
        
        let highestFrequency = maxBPM
        let lowestFrequency = minBPM
        let samplingRate:Float = cameraFPS
        
        let centerFrequency:Float = sqrt ( lowestFrequency * highestFrequency)
        let Quality:Float = centerFrequency / (highestFrequency - lowestFrequency)
        let K:Float = tan(Float(M_PI) * centerFrequency/samplingRate )  // gain constant
        
        let Ksquared:Float = K * K
        let norm = 1.0 / (1.0 + K/Quality + Ksquared)
        
        print("top \(highestFrequency), low \(lowestFrequency), samplingRate \(samplingRate), center freq \(centerFrequency), quality \(Quality), K \(K)")
        
        bandpassFilter[0] = (K / Quality * norm)
        bandpassFilter[1] = 0.0
        bandpassFilter[2] = -bandpassFilter[0]
        bandpassFilter[3] = 2.0 * (Ksquared - 1.0) * norm
        bandpassFilter[4] = ((1.0 - K/Quality + Ksquared) * norm)
    }
    
    
    
    
    
    
      
    func setupCamera(setFPS:Float){
    
        
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
        
        
        
        // formats that support 240 fps
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
    // we're using 240 fps
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
        
        
        // sum brightness from this frame
        vDSP_vfltu8(dataBufferLuma, 1, &lumaVector, 1, vDSP_Length(pixelsLuma))
        vDSP_meamgv(&lumaVector, 1, &averageLuma, vDSP_Length(pixelsLuma))

        
        
    
        // send to graph, fft, etc
        // fft graph settles down when lock on pulse is good
        dispatch_async(dispatch_get_main_queue()){
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
            vDSP_meamgv(&fpsData, 1, &fps, vDSP_Length(windowSize))
            
            FFT()   // fft uses the inputSignal array we've been building here
            
        }else{  fftLoopCount++  }
        
    }
    
    
    
    
    
    func FFT(){
        
        
        ////////////////////////////////////////////////////////////////////////////////////////////
        // FFT
        
        // parse data input into complex vector
        var zerosR = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        var zerosI = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        var cplxData = DSPSplitComplex( realp: &zerosR, imagp: &zerosI )

        // cast smoothed data as complex
        let xAsComplex = UnsafePointer<DSPComplex>( inputSignal.withUnsafeBufferPointer { $0.baseAddress } )
        vDSP_ctoz( xAsComplex, 2, &cplxData, 1, vDSP_Length(windowSizeOverTwo) )

        
        //perform fft - float, real, discrete, in place
        vDSP_fft_zrip( setup, &cplxData, 1, log2n, FFTDirection(kFFTDirection_Forward) )
        
        //calculate power                                                                   
        var powerVector = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        vDSP_zvmags(&cplxData, 1, &powerVector, 1, vDSP_Length(windowSizeOverTwo))
        
        //////////////////////////////////////////////////////////////////////////////////////////
        
        
        
        // perform other calculations once camera is up to speed
        // unlike the FFT these calculations are much better with filtered data
        if fps >= 240 {
            
            
            
            
            findPeaks()

            calculateStats()
            
            calculateHeartRate(powerVector)
            
            calculateHF_LF(powerVector)
        
        }
        
        
        
        // update graphs
       // graphView.addAll(inputSignal)
        let timeElapsed = NSDate().timeIntervalSinceDate(timeElapsedStart)
        timeLabel.text = NSString(format: "Seconds: %d", Int(timeElapsed)) as String


    }
    
    
  
    

    
    // incoming raw data 4096 frames
    // at 240 fps ~17 seconds
    func findPeaks() {
    

        // bandpass filter
        var smoothedData:[Float] = Array(count: windowSize, repeatedValue: 0.0)
        vDSP_deq22(inputSignal, 1, bandpassFilter, &smoothedData, 1, vDSP_Length(windowSize-2))

        
        // smooth data
        let maxPoints = 320

        var rollingAverage:[Float] = Array(count: maxPoints, repeatedValue: 0.0)     // use if commenting out rolling average
        var scale = Float(1000.0)
        let stride = windowSize / maxPoints
        
        // scale and shrink it
        vDSP_vsmul(smoothedData, stride, &scale, &rollingAverage, 1, vDSP_Length(maxPoints))
        
        
        
        // shift up to remove noise away from zero for zero crossing count
        var max:Float = 0
        vDSP_maxv(rollingAverage, 1, &max, vDSP_Length(maxPoints))
        
        var halfMax = max / 2.0
        vDSP_vsadd(rollingAverage, 1, &halfMax, &rollingAverage, 1, vDSP_Length(maxPoints))
        
        
        
        // draw cleaned up signal
        graphView.addAll(rollingAverage)
        
        
        
        // count times we cross zero on x axis
        var rollingAverageZeros:vDSP_Length = 0
        var lastZero:vDSP_Length = 0
        
        vDSP_nzcros(rollingAverage, 1, vDSP_Length(maxPoints), &lastZero, &rollingAverageZeros, vDSP_Length(maxPoints))
        
        // convert number of zero crossings into heart rate
        let peaksPerMinute = (rollingAverageZeros / 2) * (60 / 17)  // each peak/dip crosses zero twice, then adjust for 17 seconds/1 minute
        
        peaksPerMinuteLabel.text = ("Peaks/Min: \(peaksPerMinute)")
        
        numberOfPeaksArray.append(Float(peaksPerMinute))
        
        
        // find RR Interval
        let rr = rrIntervalFromBPM(Float(peaksPerMinute))
        rrIntervalLabel.text = ("RR Interval: \(rr)")
        rrIntervalArray.append(rr)
        if rrIntervalArray.count >= secondsPerWindow { rrIntervalArray.removeAtIndex(0) }

        


        
        
        // rolling data, use current window only for statistics
        if numberOfPeaksArray.count >= secondsPerWindow { numberOfPeaksArray.removeAtIndex(0) }
        
        
        
        
        // find pNN50
        // use peaks to find time differences
        let peakArray = rollingAverage.map(threshold)
        pnn50(peakArray)
        
        
        
        // misc calculations
        calculateStats()
        
      
    }
    
    func threshold(value:Float)->Float{ if value >= 0 { return 0.0 }else{ return 1.0 } }
    
    
    
    
    
    
    // number of heart beats differing by more than 50ms
    func pnn50(peaksArray:[Float]){
    
        let arrayLength = peaksArray.count
        
       
        // raw data is 240fps ~ 0.00416 seconds, about 12 frames for 50 ms
        // smoothed data is about 3 frames for 50 ms
        
        // need frames between peaks
        // frames between next peak
        // if frames1 - frames2 >= 3 add to n50
        var distance1 = 0       // n-1 difference
        var distance2 = 0       // n difference
        var n50 = 0             // accumlate total beats with high variability
        
        
        for i in 0..<arrayLength {
            
            if peaksArray[i] == 0.0 {
                distance1++
            }
            
            if peaksArray[i] == 1.0 {
                if abs(distance2 - distance1) >= 3 { n50++ }
                distance2 = distance1
                distance1 = 0
            }
        }
        
        // total beats - used to get % nn50 beats
        var totalPeaks:Float = 0.0
        vDSP_sve(peaksArray, 1, &totalPeaks, vDSP_Length(arrayLength))
        
        
        if totalPeaks > 0 {
            let pNN50 = Int(Float(n50) / (totalPeaks) * 100.0)
        
            n50Label.text = ("n50: \(n50)")
            pnn50Label.text = ("pNN50 \(pNN50)")
        }
    }
    
    
    
    
    
    
    
    
    
    
    func calculateStats (){
    
        
        // AVNN - mean NN
        var avnn:Float = 0.0
        vDSP_meanv(rrIntervalArray, 1, &avnn, vDSP_Length(rrIntervalArray.count))
        avnnLabel.text = ("AVNN: \(avnn)")
        
        
        // SDNN - standard deviation
        // vDSP_rmsqv ? of  sqrt ( sum (NN - AVNN)^2 / n )
        //     remove median
        var negativeAVNN = -avnn
        var nnLessMedian:[Float] = Array(count: 10, repeatedValue: 0.0)
        vDSP_vsadd(rrIntervalArray, 1, &negativeAVNN, &nnLessMedian, 1, vDSP_Length(10))
        
        // compute rms
        var sdnn:Float = 0.0
        vDSP_rmsqv(nnLessMedian, 1, &sdnn, vDSP_Length(10))
        sdnnLabel.text = ("SDNN: \(sdnn)")
        
        
        
        // rMSSD - root mean square of NN intervals
        // sqrt ( sum ( NN(x) - NN(x-1) )^2 )/(n-1) )
        var rmssd:Float = 0.0
        var nnDiff:[Float] = Array(count: 10, repeatedValue: 0.0)
        vDSP_vsub(&rrIntervalArray+1, 1, rrIntervalArray, 1, &nnDiff, 1, vDSP_Length(9))
        vDSP_rmsqv(nnDiff, 1, &rmssd, 9)
        rmssdLabel.text = ("rMSSD: \(rmssd)")
        
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
        HFBandLabel.text = ("HF: \(powerHigh)")
        LFBandLabel.text = ("LF: \(powerLow)")
        ratioLabel.text = ("Ratio: \(ratio)")
        
    }
    
    
    
    
    // looks good
    // send power spectrum to here after FFT
    func calculateHeartRate (powerVector:[Float]){
    
        let binSizeBPM = 1.0 / Float(windowSize) * (cameraFPS * 60.0)

        // find peak power and bin
        var power = 0.0 as Float
        var bin = 0 as vDSP_Length
        var powerData = powerVector
        
        // remove anything lower than our lowest bpm and higher than our highest bpm
        // this make the bpm converge faster
        let minHRBinNumber = Int(minBPM / binSizeBPM)
        let maxHRBinNumber = vDSP_Length(maxBPM / binSizeBPM )


        //  calculate heart beats per minute ( pulse )
        // We're looking for the bin with the highest power ( strongest frequency )
        vDSP_maxvi(&powerData+minHRBinNumber, 1, &power, &bin, maxHRBinNumber)
        let selectedBin = Int(bin) +  Int(minHRBinNumber)
        
        
        // push heart rate data to the user
        let bpm = Float(selectedBin) * binSizeBPM
        pulseLabel.text = NSString(format: "%d BPM ", Int(bpm)) as String
    }
    
    
    
    
    func rrIntervalFromBPM(bpm:Float) ->Float { return (60.0/bpm) * 1000.0 }
    
    
    
    
    //////////////////////////////////////////////////////////////
    // UI start/stop camera
    //////////////////////////////////////////////////////////////
    @IBAction func stop(){
        session.stopRunning()           // stop camera
    }
    
    
    
    @IBAction func start(){
        
        // init graphs
        setupGraphs()                   // refresh the view

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

