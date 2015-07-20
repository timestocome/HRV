//
//  GraphView.swift
//  Sensors
//
//  Created by Linda Cobb on 9/22/14.
//  Copyright (c) 2014 TimesToCome Mobile. All rights reserved.
//

import Foundation
import UIKit
import Accelerate



class GraphView: UIView
{
    
    // graph dimensions
    // put up here as globals so we only have to calculate them one time
    var area: CGRect!
    var maxPoints: Int = 320
    var height: CGFloat!
    var halfHeight: CGFloat!

    
    // incoming data to graph
    var dataArrayX:[CGFloat] = Array(count: 320, repeatedValue: 0.0)
    
    
    
    required init( coder aDecoder: NSCoder ){ super.init(coder: aDecoder) }
    
    override init(frame:CGRect){ super.init(frame:frame) }
    
    
    
    func setupGraphView() {
        
        area = frame
        height = CGFloat(area.size.height)
        halfHeight = CGFloat(height/2.0)
        
        setNeedsDisplay()   
        
    }
    
    
    
    
    
    func addAll(x: [Float]){

        
        //***************   get max and figure out a scale ***************//
        dataArrayX = x.map { CGFloat($0 as Float) % self.halfHeight }
        dataArrayX.removeAtIndex(0)
        
        
        
        setNeedsDisplay()
    }

    
    
    
    
    
    func addX(x: Float){
        
        // scale incoming data and insert it into data array
        let xScaled = CGFloat(x * 1.0 % Float(halfHeight))
        
        dataArrayX.insert(xScaled, atIndex: 0)
        dataArrayX.removeLast()
        
        setNeedsDisplay()
    }
    
    
    
    override func drawRect(rect: CGRect) {
        
        let context = UIGraphicsGetCurrentContext()
        CGContextSetStrokeColor(context, [1.0, 0.0, 0.0, 1.0])
        let points = dataArrayX.count
        
        
        for i in 1..<points {
            
            let x1 = CGFloat(i) * 1.0
            let x2 = x1 - 1.0
            
            
            // plot x
            CGContextMoveToPoint(context, x2, halfHeight - self.dataArrayX[i-1] )
            CGContextAddLineToPoint(context, x1, halfHeight - self.dataArrayX[i] )
            
            CGContextSetLineWidth(context, 1.0)
            CGContextStrokePath(context)
                        
        }
    }
    
}









