//
//  VectorGraph.swift
//  Swift HRV
//
//  Created by Linda Cobb on 6/9/15.
//  Copyright (c) 2015 TimesToCome Mobile. All rights reserved.
//


import Foundation
import UIKit


class VectorGraph: UIView
{
    
    // graph dimensions
    // put up here as globals so we only have to calculate them one time
    var area: CGRect!
    var maxPoints: Int!
    var height: CGFloat!
    var halfHeight: CGFloat!
    var width: CGFloat!
    var scale:Float = 1.0
    var xScale:CGFloat = 1.0
    var numberOfDataPoints = 1
    
    
    // incoming data to graph
    var dataArrayX:[CGFloat]!
    
    
    
    required init( coder aDecoder: NSCoder ){ super.init(coder: aDecoder) }
    
    override init(frame:CGRect){ super.init(frame:frame) }
    
    
    
    func setupGraphView() {
        
        area = frame
        maxPoints = Int(area.size.width)
        height = CGFloat(area.size.height)
        halfHeight = height/2.0
        width = CGFloat(area.size.width)
        
        dataArrayX = [CGFloat](count:maxPoints, repeatedValue: 0.0)
        scale = Float(area.height)       // view height /max possible value * scaled up to show small details

        
        setNeedsDisplay()
        
    }
    
    
    
    
    
    
    
    func addAll(x: [Float]){
        
        //***************   get max and figure out a scale ***************//
        dataArrayX = x.map { CGFloat($0 as Float) * 100.0 % self.halfHeight }
        dataArrayX.removeAtIndex(0)
        
        numberOfDataPoints = dataArrayX.count
        xScale = CGFloat(numberOfDataPoints)/width
                
        setNeedsDisplay()
    }
    
    
    
    
    
    
    override func drawRect(rect: CGRect) {
        
        let context = UIGraphicsGetCurrentContext()
        CGContextSetStrokeColor(context, [1.0, 0.0, 0.0, 1.0])
        let xScale = CGFloat(5.0)
        
        for i in 1..<numberOfDataPoints {
            
            let mark = CGFloat(i) * xScale
            
            // plot x
            CGContextMoveToPoint(context, mark, height - self.dataArrayX[i] )
            CGContextAddLineToPoint(context, mark-xScale, height - self.dataArrayX[i-1] )
            
            CGContextSetLineWidth(context, 3.0)
            CGContextStrokePath(context)
            
        }
    }
    
}









