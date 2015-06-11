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


import UIKit
import Foundation
import AVFoundation
import QuartzCore
import CoreMedia
import Accelerate




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
  
    
    // image information, computered when we start camera
    var height = 0
    var width = 0
    var numberOfPixels = 0
    
    
    // used to compute frames per second
    var newDate:NSDate = NSDate()
    var oldDate:NSDate = NSDate()
    
    
    
    // needed to init image context
    var context:CIContext!
    
    
    
    // FFT setup stuff, also used in pulse calculations
    let windowSize = 512               // granularity of the measurement, error
    var log2n:vDSP_Length = 0
    let windowSizeOverTwo = 256         // for fft
    var fps:Float = 30.0                // fps === hz
    var setup:COpaquePointer!
    
    
    // collects data from image and stores for fft
    var dataCount = 0           // tracks how many data points we have ready for fft
    var fftLoopCount = 0        // how often we grab data between fft calls
    var inputSignal:[Float] = Array(count: 512  , repeatedValue: 0.0)
    
    
    
    // data smoothing
    var movingAverageArray:[CGFloat] = [0.0, 0.0, 0.0, 0.0, 0.0]      // used to store rolling average
    var movingAverageCount:CGFloat = 5.0                              // window size
    
    
  
    
    
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
    

    
      
    
    
    
    // set up to grab live images from the camera
    func setupCaptureSession () {
        
        var error: NSError?
        var videoDevice:AVCaptureDevice!
        let videoDevices = AVCaptureDevice.devicesWithMediaType(AVMediaTypeVideo)
        
        
        // inputs - find and use back facing camera
        for device in videoDevices{
            if device.position == AVCaptureDevicePosition.Back {
                videoDevice = device as! AVCaptureDevice
            }
        }
        
        
        let videoInput = AVCaptureDeviceInput(device: videoDevice, error: &error )
        let dataOutput = AVCaptureVideoDataOutput()
        
        
        // output format
        dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        
        
        // set up session
        let sessionQueue = dispatch_queue_create("AVSessionQueue", DISPATCH_QUEUE_SERIAL)
        dataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        
        session = AVCaptureSession()
        
        
        // measure pulse from 40-230bpm = ~.5 - 4bps * 2 to remove aliasing need 8 frames/sec minimum
        // preset352x288 ~ 30fps
        session.sessionPreset = AVCaptureSessionPreset352x288
        height = 352
        width = 288
        numberOfPixels = height * width
        
        
        // turn on light
        session.beginConfiguration()
        videoDevice.lockForConfiguration(&error)
        videoDevice.setTorchModeOnWithLevel(AVCaptureMaxAvailableTorchLevel, error: &error)
        videoDevice.unlockForConfiguration()
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
        
        
        // get the image from the camera
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        
        
        // lock buffer
        CVPixelBufferLockBaseAddress(pixelBuffer!, 0);
        
        // grab image info
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        
        // get pointer to the pixel array
        let src_buff = CVPixelBufferGetBaseAddress(imageBuffer!)
        let dataBuffer = UnsafeMutablePointer<UInt8>(src_buff)
        
        // unlock buffer
        CVPixelBufferUnlockBaseAddress(imageBuffer!, 0)
        
        
        
        // compute the brightness for reg, green, blue and total
        // pull out color values from pixels ---  image is BGRA
        var greenVector:[Float] = Array(count: numberOfPixels, repeatedValue: 0.0)
        var blueVector:[Float] = Array(count: numberOfPixels, repeatedValue: 0.0)
        var redVector:[Float] = Array(count: numberOfPixels, repeatedValue: 0.0)
        
        vDSP_vfltu8(dataBuffer, 4, &blueVector, 1, vDSP_Length(numberOfPixels))
        vDSP_vfltu8(dataBuffer+1, 4, &greenVector, 1, vDSP_Length(numberOfPixels))
        vDSP_vfltu8(dataBuffer+2, 4, &redVector, 1, vDSP_Length(numberOfPixels))
        
        
        
        // compute average per color
        var redAverage:Float = 0.0
        var blueAverage:Float = 0.0
        var greenAverage:Float = 0.0
        
        vDSP_meamgv(&redVector, 1, &redAverage, vDSP_Length(numberOfPixels))
        vDSP_meamgv(&greenVector, 1, &greenAverage, vDSP_Length(numberOfPixels))
        vDSP_meamgv(&blueVector, 1, &blueAverage, vDSP_Length(numberOfPixels))
        
        
        
        // convert to HSV ( hue, saturation, value )
        // this gives faster, more accurate answer
        var hue: CGFloat = 0.0
        var saturation: CGFloat = 0.0
        var brightness: CGFloat = 0.0
        var alpha: CGFloat = 1.0
        
        var color: UIColor = UIColor(red: CGFloat(redAverage/255.0), green: CGFloat(greenAverage/255.0), blue: CGFloat(blueAverage/255.0), alpha: alpha)
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        
        
        // ******* need Power Spectral Density
        
        
        //  ******************************************************************************************
        // ? vDSP_vswsum ? --- convert this to a vDSP function
        // 5 count rolling average
        let currentHueAverage = hue/movingAverageCount
        movingAverageArray.removeAtIndex(0)
        movingAverageArray.append(currentHueAverage)
        
        let movingAverage = movingAverageArray[0] + movingAverageArray[1] + movingAverageArray[2] + movingAverageArray[3] + movingAverageArray[4]

        
        
        
        // send to graph and fft
        // fft graph settles down when lock on pulse is good
        dispatch_async(dispatch_get_main_queue()){
            self.graphView.addX(Float(movingAverage))
            self.collectDataForFFT(Float(movingAverage), green: Float(saturation), blue: Float(brightness))
        }
    }
    
    
    
    
    // grab data points from image
    // stuff the data points into an array
    // call fft after we collect a window worth of data points
    //
    // one color is plenty for heart rate
    // others are here only as setup for future projects
    func collectDataForFFT( red: Float, green: Float, blue: Float ){
        
        // first fill up array
        if  dataCount < windowSize {
            inputSignal[dataCount] = red
            dataCount++
            
            // then pop oldest off top push newest onto end
        }else{
            
            inputSignal.removeAtIndex(0)
            inputSignal.append(red)
        }
        
        
        
        // call fft ~ once per second
        if  fftLoopCount > Int(fps) {
            fftLoopCount = 0
            FFT()
            
        }else{ fftLoopCount++; }
        
        
    }
    
    
    
    
    
    func FFT(){
        
        
        // parse data input into complex vector
        var zerosR = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        var zerosI = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        var cplxData = DSPSplitComplex( realp: &zerosR, imagp: &zerosI )

       
        // filter data - sliding window sum?
        var filteredData:[Float] = Array(count: windowSize, repeatedValue: 0.0)
        var smoothSize:Float = 1.0
        vDSP_vswsum(inputSignal, 1, &filteredData, 1, vDSP_Length(windowSize), vDSP_Length(30))
        vDSP_vsdiv(filteredData, 1, &smoothSize, &filteredData, 1, vDSP_Length(windowSize))
        
        powerView.addAll(filteredData)
        
        
        // use raw unfiltered data
         let xAsComplex = UnsafePointer<DSPComplex>( inputSignal.withUnsafeBufferPointer { $0.baseAddress } )
         vDSP_ctoz( xAsComplex, 2, &cplxData, 1, vDSP_Length(windowSizeOverTwo) )
        

        // use filtered data
        // let xAsComplex = UnsafePointer<DSPComplex>( filteredData.withUnsafeBufferPointer { $0.baseAddress } )
        // vDSP_ctoz( xAsComplex, 2, &cplxData, 1, vDSP_Length(windowSizeOverTwo) )
        
        
        
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
        // filter out the edges - anything lower than 35bpm or greater than 225 bpm
        // this speed up time to get a good reading even if data is filtered
        let minHeartRate = 10                                      // skip anything lower ~35 bpm
        let maxHeartRate = 85                                       // skip anything over ~300 bpm
        vDSP_maxvi(&powerVector+minHeartRate, 1, &power, &bin, vDSP_Length(maxHeartRate))
        bin += vDSP_Length(minHeartRate)
                
        
        // push heart rate data to the user
        let timeElapsed = NSDate().timeIntervalSinceDate(timeElapsedStart)
        timeLabel.text = NSString(format: "Seconds: %d", Int(timeElapsed)) as String
        
        let binSize = fps * 60.0 / Float(windowSize)
        let errorSize = fps * 60.0 / Float(windowSize)
        
        let bpm = Float(bin) / Float(windowSize) * (fps * 60.0)
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

        var powerLow = powerVector[1] + powerVector[2] + powerVector[3]
        var powerHigh = powerVector[3] + powerVector[4] + powerVector[5] + powerVector[6] + powerVector[7] + powerVector[8] + powerVector[9]
        var totalPower = powerLow + powerHigh
        
        // clean up and send to user
        powerLow = powerLow/totalPower
        powerHigh = powerHigh/totalPower
        let ratio = log(powerLow/powerHigh)
        powerLow *= 100.0
        powerHigh *= 100.0
        HFBandLabel.text = ("High Frequency \(Int(powerHigh))")
        LFBandLabel.text = ("Low Frequency \(Int(powerLow))")
        
        
        
        
        
        ///////////////////////////////////////////////////////////////////////////////////////////////////////
        // Heart rate variability
       
        
        // do we have another way to count peaks per minute?
        // find derivative, count sign changes?
        let dataPointsPerTenSeconds = Int(fps * 10)         // need to keep this smaller than our window size
        
        
       // var smoothedData:[Float] = Array(count: dataPointsPerTenSeconds, repeatedValue: 0.0)
        
        
        
        
        var x1:[Float] = inputSignal
        x1.removeAtIndex(0)
        
        var dx:[Float] = Array(count: dataPointsPerTenSeconds, repeatedValue: 0.0)
        vDSP_vsub(inputSignal, 1, x1, 1, &dx, 1, vDSP_Length(dataPointsPerTenSeconds))
        
        var indexCrossing:vDSP_Length = 0
        var numberOfCrossings:vDSP_Length = 0
        
        vDSP_nzcros(dx, 1, vDSP_Length(dataPointsPerTenSeconds), &indexCrossing, &numberOfCrossings, vDSP_Length(dataPointsPerTenSeconds))
        var heartRate = Int(numberOfCrossings / 2) * 6      // 10 * 6 = 60 seconds, two crossings per peak
        
        
        
        
        
        var sumPowerVector:Float = 0.0
        vDSP_sve(&powerVector+1, 1, &sumPowerVector, vDSP_Length(windowSize))
        
        if  sumPowerVector < 1.0 { println("locked ") }
        
        
        
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

