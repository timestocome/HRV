//
//  GraphView.swift
//  Sensors
//
//  Created by Linda Cobb on 9/22/14.
//  Copyright (c) 2014 TimesToCome Mobile. All rights reserved.
//

import Foundation
import UIKit


class GraphView: UIView
{
    
    // graph dimensions
    // put up here as globals so we only have to calculate them one time
    var area: CGRect!
    var maxPoints: Int!
    var width: CGFloat!
    var height: CGFloat!
    var halfHeight: CGFloat!
    var scale:Float = 1.0

    
    // incoming data to graph
    var dataArrayX:[CGFloat]!
    
    
    
    required init( coder aDecoder: NSCoder ){ super.init(coder: aDecoder) }
    
    override init(frame:CGRect){ super.init(frame:frame) }
    
    
    
    func setupGraphView() {
        
        area = frame
        maxPoints = Int(area.size.width)
        height = CGFloat(area.size.height)
        halfHeight = CGFloat(height/2.0)

        
        dataArrayX = [CGFloat](count:maxPoints, repeatedValue: 0.0)
        scale = Float(area.height) * 10.0       // view height /max possible value * scaled up to show small details
        
        setNeedsDisplay()   
        
    }
    
    
    
    
    
    func addAll(x: [Float]){
        
        //***************   get max and figure out a scale ***************//
        dataArrayX = x.map { CGFloat($0 as Float) * 1000.0 % self.height }
        dataArrayX.removeAtIndex(0)
        
        maxPoints = dataArrayX.count
        
        setNeedsDisplay()
    }

    
    
    
    
    
    func addX(x: Float){
        
        
        // scale incoming data and insert it into data array
        let xScaled = CGFloat(x * scale % Float(halfHeight))
        
        dataArrayX.insert(xScaled, atIndex: 0)
        dataArrayX.removeLast()
        
        setNeedsDisplay()
    }
    
    
    
    override func drawRect(rect: CGRect) {
        
        let context = UIGraphicsGetCurrentContext()
        CGContextSetStrokeColor(context, [1.0, 0.0, 0.0, 1.0])
        
        for i in 1..<maxPoints {
            
            let x1 = CGFloat(i) * 3.0
            let x2 = CGFloat(i-1) * 3.0
            
            // plot x
            CGContextMoveToPoint(context, x2, halfHeight - self.dataArrayX[i-1] )
            CGContextAddLineToPoint(context, x1, halfHeight - self.dataArrayX[i] )
            
            CGContextSetLineWidth(context, 2.0)
            CGContextStrokePath(context)
                        
        }
    }
    
}









