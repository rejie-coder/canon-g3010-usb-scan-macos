import AppKit
import CoreImage
import ImageIO
import SwiftUI
import Vision

enum Paper: String, CaseIterable {
    case auto = "Auto detect", a4 = "A4", a5 = "A5", letter = "US Letter", photo = "4 × 6 in", full = "Full flatbed"
    var mm: CGSize? {
        switch self {
        case .a4: return CGSize(width: 210, height: 297)
        case .a5: return CGSize(width: 148, height: 210)
        case .letter: return CGSize(width: 215.9, height: 279.4)
        case .photo: return CGSize(width: 101.6, height: 152.4)
        default: return nil
        }
    }
}

// Clockwise, with a top-left origin throughout the preview and editor.
struct PageOutline: Equatable {
    var corners: [CGPoint]
    static let full = rectangle(1, 1)
    static func rectangle(_ width: CGFloat, _ height: CGFloat) -> Self {
        Self(corners: [.zero, CGPoint(x: width,y: 0), CGPoint(x: width,y: height), CGPoint(x: 0,y: height)])
    }
    var area: CGFloat {
        (0..<4).reduce(0) { sum, i in
            let p = corners[i], q = corners[(i + 1) % 4]
            return sum + p.x * q.y - p.y * q.x
        } / 2
    }
    var valid: Bool {
        guard area >= 0.006 else { return false }
        return (0..<4).allSatisfy { i in
            let a = corners[i], b = corners[(i+1)%4], c = corners[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y) - (b.y-a.y)*(c.x-b.x) > 0.001
        }
    }

    func pixels(in size: CGSize) -> CGSize {
        func length(_ a: Int, _ b: Int) -> CGFloat {
            hypot((corners[a].x-corners[b].x)*size.width, (corners[a].y-corners[b].y)*size.height)
        }
        return CGSize(width: ((length(0,1)+length(3,2))/2).rounded(),
                      height: ((length(0,3)+length(1,2))/2).rounded())
    }

    init(corners: [CGPoint]) { self.corners = corners }
    init(_ observation: VNRectangleObservation) {
        corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            .map { CGPoint(x: max(0,min(1,$0.x)), y: max(0,min(1,1-$0.y))) }
    }
}

// Reject interior text boxes when the apparent exterior still contains a lot of ink.
private struct BedSamples {
    let length = 160
    var values = [UInt8](repeating: 0, count: 160 * 160)
    init(_ image: CGImage) {
        values.withUnsafeMutableBytes { data in
            guard let ctx = CGContext(data: data.baseAddress, width: 160, height: 160, bitsPerComponent: 8,
                                      bytesPerRow: 160, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return }
            ctx.draw(image, in: CGRect(x: 0,y: 0,width: 160,height: 160))
        }
    }
    func plausible(_ outline: PageOutline) -> Bool {
        guard outline.valid else { return false }
        if outline.area > 0.92 { return true }
        var histogram = [Int](repeating: 0, count: 256)
        var count = 0
        for y in stride(from: 2, to: length-2, by: 2) {
            for x in stride(from: 2, to: length-2, by: 2) {
                let p = CGPoint(x: CGFloat(x)/CGFloat(length),y: CGFloat(y)/CGFloat(length))
                let outside = (0..<4).contains { i in
                    let a = outline.corners[i], b = outline.corners[(i+1)%4]
                    return (b.x-a.x)*(p.y-a.y) - (b.y-a.y)*(p.x-a.x) < -0.012
                }
                if outside { histogram[Int(values[y*length+x])] += 1; count += 1 }
            }
        }
        if count < 12 { return true }
        var sum = 0
        let median = histogram.indices.first { sum += histogram[$0]; return sum >= count/2 } ?? 255
        let uniform = histogram[max(0,median-25)...min(255,median+25)].reduce(0,+)
        guard Double(uniform)/Double(count) > 0.90 else { return false }
        // Compare strips beyond the border line itself. A printed frame often
        // has the same paper on both sides; a loose sheet has a backing outside.
        var visibleSides = 0
        var contrastingSides = 0
        for i in 0..<4 {
            let a = outline.corners[i], b = outline.corners[(i+1)%4]
            let dx = b.x-a.x, dy = b.y-a.y, distance = hypot(dx,dy)
            var differences = [Int]()
            for n in 2...10 {
                let t = CGFloat(n)/12
                let x = a.x + dx*t, y = a.y + dy*t
                let nx = -dy/distance * 0.022, ny = dx/distance * 0.022
                func value(_ x: CGFloat, _ y: CGFloat) -> Int? {
                    guard x >= 0, x < 1, y >= 0, y < 1 else { return nil }
                    return Int(values[Int(y*CGFloat(length))*length + Int(x*CGFloat(length))])
                }
                if let inside = value(x+nx,y+ny), let outside = value(x-nx,y-ny) {
                    differences.append(abs(inside-outside))
                }
            }
            if differences.count >= 4 {
                visibleSides += 1
                if differences.sorted()[differences.count/2] >= 5 { contrastingSides += 1 }
            }
        }
        return visibleSides > 0 && contrastingSides >= min(visibleSides,2)
    }
}

func detectPage(_ image: CGImage) -> PageOutline? {
    let samples = BedSamples(image)
    let handler = VNImageRequestHandler(cgImage: image)
    let document = VNDetectDocumentSegmentationRequest()
    if (try? handler.perform([document])) != nil, let result = document.results?.first, result.confidence >= 0.55 {
        let quad = PageOutline(result)
        if samples.plausible(quad) { return quad }
    }
    let rectangles = VNDetectRectanglesRequest()
    rectangles.maximumObservations = 12
    rectangles.minimumSize = 0.14
    rectangles.minimumAspectRatio = 0.2
    rectangles.maximumAspectRatio = 1
    rectangles.minimumConfidence = 0.65
    rectangles.quadratureTolerance = 15
    try? handler.perform([rectangles])
    return (rectangles.results ?? []).map(PageOutline.init).filter { samples.plausible($0) }.max { $0.area < $1.area }
}

func croppedPage(_ image: CGImage, outline: PageOutline, size: CGSize) throws -> CGImage {
    let original = CGSize(width: image.width, height: image.height)
    let w = max(1,size.width.rounded()), h = max(1,size.height.rounded())
    if outline == .full && w == original.width && h == original.height { return image }
    let input = CIImage(cgImage: image)
    let points = outline.corners.map { CIVector(x: $0.x * original.width, y: (1-$0.y) * original.height) }
    let corrected = input.applyingFilter("CIPerspectiveCorrection", parameters: [
        "inputTopLeft": points[0], "inputTopRight": points[1], "inputBottomRight": points[2], "inputBottomLeft": points[3]
    ])
    let box = corrected.extent
    guard box.width > 0, box.height > 0 else { throw ScanError(message: "Move the crop handles farther apart.") }
    let resized = corrected.transformed(by: CGAffineTransform(translationX: -box.minX,y: -box.minY))
        .transformed(by: CGAffineTransform(scaleX: w/box.width, y: h/box.height))
    guard let output = CIContext().createCGImage(resized, from: CGRect(x: 0,y: 0,width: w,height: h)) else {
        throw ScanError(message: "Could not apply the page edges.")
    }
    return output
}

struct PageEditor: View {
    let image: NSImage
    @Binding var outline: PageOutline
    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width/image.size.width, geo.size.height/image.size.height)
            let size = CGSize(width: image.size.width*scale, height: image.size.height*scale)
            let points = outline.corners.map { CGPoint(x: $0.x*size.width,y: $0.y*size.height) }
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().frame(width: size.width,height: size.height)
                let border = Path { path in
                    path.move(to: points[0]); for p in points.dropFirst() { path.addLine(to: p) }; path.closeSubpath()
                }
                Path { path in path.addRect(CGRect(origin: .zero,size: size)); path.addPath(border) }
                    .fill(Color.black.opacity(0.36), style: FillStyle(eoFill: true))
                border.stroke(Color.accentColor,lineWidth: 2)
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(.white).overlay(Circle().stroke(Color.accentColor,lineWidth: 3))
                        .frame(width: 13,height: 13).frame(width: 30,height: 30)
                        .contentShape(Rectangle()).position(points[i])
                        .gesture(DragGesture(minimumDistance: 0,coordinateSpace: .named("flatbed")).onChanged { event in
                            var candidate = outline
                            candidate.corners[i] = CGPoint(x: max(0,min(1,event.location.x/size.width)),
                                                            y: max(0,min(1,event.location.y/size.height)))
                            if candidate.valid { outline = candidate }
                        })
                }
            }.frame(width: size.width,height: size.height).coordinateSpace(name: "flatbed")
             .position(x: geo.size.width/2,y: geo.size.height/2)
        }.padding(24)
    }
}
