/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

import UIKit
import Metal
import QuartzCore

class IOSMetalLayer: CAMetalLayer {
    weak var common: IOSCommon?
    private var displayLink: CADisplayLink?
    private var lastDrawableSize: CGSize = .zero
    
    // Prevent drawable size from being set to 1x1 (workaround for various issues)
    override var drawableSize: CGSize {
        get { return super.drawableSize }
        set {
            if newValue.width > 1 && newValue.height > 1 {
                super.drawableSize = newValue
                lastDrawableSize = newValue
            }
        }
    }
    
    init(common: IOSCommon) {
        self.common = common
        super.init()
        
        // Configure layer for optimal video playback
        self.pixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.presentsWithTransaction = false
        self.backgroundColor = UIColor.black.cgColor
        
        // Enable EDR/HDR if available
        if #available(iOS 16.0, *) {
            self.wantsExtendedDynamicRangeContent = true
            if self.wantsExtendedDynamicRangeContent {
                self.pixelFormat = .rgba16Float
                self.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            }
        }
        
        // Set initial drawable size based on screen
        let screen = UIScreen.main
        let scale = screen.scale
        let bounds = screen.bounds
        self.contentsScale = scale
        self.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        
        setupDisplayLink()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // Handle layer copying when the containing view changes
    override init(layer: Any) {
        guard let oldLayer = layer as? IOSMetalLayer else {
            fatalError("init(layer:) passed an invalid layer")
        }
        self.common = oldLayer.common
        super.init(layer: layer)
    }
    
    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback))
        displayLink?.add(to: .current, forMode: .common)
        
        // Match display refresh rate
        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: 24,
                maximum: Float(UIScreen.main.maximumFramesPerSecond),
                preferred: Float(UIScreen.main.maximumFramesPerSecond)
            )
        }
    }
    
    @objc private func displayLinkCallback() {
        common?.displayLinkCallback(displayLink: displayLink)
    }
    
    func updateDrawableSize(for view: UIView) {
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let newSize = CGSize(width: view.bounds.width * scale,
                           height: view.bounds.height * scale)
        
        if newSize != lastDrawableSize && newSize.width > 0 && newSize.height > 0 {
            self.drawableSize = newSize
            self.frame = view.bounds
        }
    }
    
    func cleanup() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

@objc class IOSCommon: NSObject {
    weak var vo: UnsafeMutablePointer<vo>?
    var metalLayer: IOSMetalLayer?
    var view: UIView?
    var vsyncCallback: ((Double, Double) -> Void)?
    
    @objc init(vo: UnsafeMutablePointer<vo>) {
        self.vo = vo
        super.init()
        setupView()
    }
    
    private func setupView() {
        DispatchQueue.main.sync {
            if let window = UIApplication.shared.keyWindow {
                view = UIView(frame: window.bounds)
                view?.backgroundColor = .black
                view?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                
                metalLayer = IOSMetalLayer(common: self)
                if let metalLayer = metalLayer {
                    view?.layer.addSublayer(metalLayer)
                    metalLayer.frame = view!.bounds
                }
                
                window.rootViewController?.view.addSubview(view!)
            }
        }
    }
    
    @objc func config() -> Bool {
        guard let view = view, let metalLayer = metalLayer else {
            return false
        }
        
        DispatchQueue.main.sync {
            metalLayer.updateDrawableSize(for: view)
        }
        
        return true
    }
    
    @objc func uninit() {
        DispatchQueue.main.sync {
            metalLayer?.cleanup()
            metalLayer?.removeFromSuperlayer()
            metalLayer = nil
            
            view?.removeFromSuperview()
            view = nil
        }
    }
    
    @objc func swapBuffer() {
        // Metal handles presentation through command buffer
    }
    
    @objc func fillVsyncInfo(_ info: UnsafeMutablePointer<vo_vsync_info>) {
        let fps = Double(UIScreen.main.maximumFramesPerSecond)
        info.pointee.vsync_duration = Int64(1.0 / fps * 1e9)
        info.pointee.skipped_vsyncs = 0
        info.pointee.last_queue_display_time = Int64(CACurrentMediaTime() * 1e9)
    }
    
    @objc func isVisible() -> Bool {
        return view?.window != nil
    }
    
    func displayLinkCallback(displayLink: CADisplayLink?) {
        guard let displayLink = displayLink else { return }
        
        let timestamp = displayLink.timestamp
        let targetTimestamp = displayLink.targetTimestamp
        let duration = displayLink.duration
        
        vsyncCallback?(timestamp, duration)
    }
}

// Bridge functions for C interop
@_cdecl("ios_metal_layer_create")
public func ios_metal_layer_create(_ vo: UnsafeMutablePointer<vo>) -> UnsafeMutableRawPointer? {
    let common = IOSCommon(vo: vo)
    return Unmanaged.passRetained(common).toOpaque()
}

@_cdecl("ios_metal_layer_destroy")
public func ios_metal_layer_destroy(_ common_ptr: UnsafeMutableRawPointer) {
    let common = Unmanaged<IOSCommon>.fromOpaque(common_ptr).takeRetainedValue()
    common.uninit()
}

@_cdecl("ios_metal_layer_get_metal_layer")
public func ios_metal_layer_get_metal_layer(_ common_ptr: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let common = Unmanaged<IOSCommon>.fromOpaque(common_ptr).takeUnretainedValue()
    guard let layer = common.metalLayer else { return nil }
    return Unmanaged.passUnretained(layer).toOpaque()
}