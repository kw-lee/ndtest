#!/usr/bin/env swift
// Generates AppIcon.png (1024×1024) for Naraeon Dirty Test macOS.
// Run from the macos/ directory:   swift generate-icon.swift
//
// Design: chart-style icon matching the app's actual output —
//   dark rounded-square bg, grid, blue area chart with SSD-style
//   speed cliff, red 50%-average threshold line.

import AppKit
import CoreGraphics

let size: CGFloat = 1024

// ── Offscreen bitmap context ───────────────────────────────────────────────
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

// ── 1. Rounded-square background (near-black, like macOS dark instruments) ─
let cornerR = size * 0.22
let bgPath = CGMutablePath()
bgPath.addRoundedRect(in: CGRect(x: 0, y: 0, width: size, height: size),
                      cornerWidth: cornerR, cornerHeight: cornerR)
ctx.addPath(bgPath)
ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1))
ctx.fillPath()

// Clip everything that follows to the rounded square
ctx.addPath(bgPath)
ctx.clip()

// ── 2. Chart area inset ────────────────────────────────────────────────────
let pad: CGFloat  = size * 0.11   // inset from icon edge
let cX = pad                       // chart origin x
let cY = pad                       // chart origin y (bottom in CG coords)
let cW = size - pad * 2            // chart width
let cH = size - pad * 2            // chart height

// Chart background — slightly lighter dark panel
let panelPath = CGMutablePath()
panelPath.addRect(CGRect(x: cX, y: cY, width: cW, height: cH))
ctx.addPath(panelPath)
ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1))
ctx.fillPath()

// ── 3. Grid lines ─────────────────────────────────────────────────────────
ctx.setStrokeColor(CGColor(red: 0.28, green: 0.28, blue: 0.32, alpha: 1))
ctx.setLineWidth(size * 0.007)

// Vertical grid (5 columns)
let vCols = 5
for i in 1 ..< vCols {
    let x = cX + cW * CGFloat(i) / CGFloat(vCols)
    ctx.move(to:    CGPoint(x: x, y: cY))
    ctx.addLine(to: CGPoint(x: x, y: cY + cH))
}
// Horizontal grid (4 rows)
let hRows = 4
for j in 1 ..< hRows {
    let y = cY + cH * CGFloat(j) / CGFloat(hRows)
    ctx.move(to:    CGPoint(x: cX,      y: y))
    ctx.addLine(to: CGPoint(x: cX + cW, y: y))
}
ctx.strokePath()

// ── 4. Speed curve data ────────────────────────────────────────────────────
// Mimic a real SSD dirty-test result:
//   left ~40% of x-axis: high speed with light noise
//   cliff at ~40% of x-axis
//   right ~60%: very low flat speed
//
// x goes left-to-right = 100% free → 0% free (matches Windows chart)
// CG y=0 is bottom; higher value = higher on screen.

let highY: CGFloat  = cH * 0.78   // SLC cache speed  (~78% of chart height)
let lowY:  CGFloat  = cH * 0.065  // TLC speed        (~6.5%)
let cliffX: CGFloat = cW * 0.40   // cliff at 40% across

// Deterministic noise helper (no Foundation random seeding needed)
func noise(_ i: Int, _ amplitude: CGFloat) -> CGFloat {
    let v = sin(CGFloat(i) * 137.508 + CGFloat(i * i) * 0.031) * 0.5 + 0.5
    return (v - 0.5) * amplitude
}

// Build the area path: start bottom-left, trace top, end bottom-right
let chartPath = CGMutablePath()
let steps = 300
chartPath.move(to: CGPoint(x: cX, y: cY))  // bottom-left

for step in 0 ... steps {
    let t  = CGFloat(step) / CGFloat(steps)
    let px = cX + t * cW

    let rawY: CGFloat
    if t < cliffX / cW - 0.01 {
        // High-speed region — noisy but high
        rawY = highY + noise(step, cH * 0.07)
    } else if t < cliffX / cW + 0.015 {
        // Cliff — steep drop in a narrow band
        let blend = (t - (cliffX / cW - 0.01)) / 0.025
        rawY = highY * (1 - blend) + lowY * blend + noise(step, cH * 0.04)
    } else {
        // Low-speed flat region — tiny ripple
        rawY = lowY + noise(step, cH * 0.025)
    }

    let py = cY + max(0, min(cH, rawY))
    if step == 0 {
        chartPath.move(to: CGPoint(x: px, y: cY))
        chartPath.addLine(to: CGPoint(x: px, y: py))
    } else {
        chartPath.addLine(to: CGPoint(x: px, y: py))
    }
}
chartPath.addLine(to: CGPoint(x: cX + cW, y: cY))  // bottom-right
chartPath.closeSubpath()

// Fill with solid blue
ctx.addPath(chartPath)
ctx.setFillColor(CGColor(red: 0.22, green: 0.55, blue: 0.92, alpha: 1))
ctx.fillPath()

// Blue top-edge stroke for crispness
ctx.addPath(chartPath)
ctx.setStrokeColor(CGColor(red: 0.35, green: 0.68, blue: 1.0, alpha: 1))
ctx.setLineWidth(size * 0.009)
ctx.setLineJoin(.round)
ctx.strokePath()

// ── 5. Red 50%-average threshold line ─────────────────────────────────────
// Visually at ~30% of chart height (between low and high, closer to low)
let redLineY = cY + cH * 0.29

ctx.setStrokeColor(CGColor(red: 0.92, green: 0.18, blue: 0.18, alpha: 1))
ctx.setLineWidth(size * 0.014)
ctx.setLineDash(phase: 0, lengths: [])   // solid, matching screenshot
ctx.move(to:    CGPoint(x: cX,      y: redLineY))
ctx.addLine(to: CGPoint(x: cX + cW, y: redLineY))
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

// ── Save PNG ───────────────────────────────────────────────────────────────
let outPath = URL(fileURLWithPath: "AppIcon.png")
guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("Error: could not encode PNG\n", stderr)
    exit(1)
}
do {
    try data.write(to: outPath)
    print("AppIcon.png written to \(outPath.path)")
} catch {
    fputs("Error writing file: \(error)\n", stderr)
    exit(1)
}
