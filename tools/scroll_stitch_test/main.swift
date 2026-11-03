// Exercises ScrollCapture.stitch (macos/Runner/Shell/ScrollCapture.swift) with synthetic pages: plain, sticky
// header/footer, a page that scrolls less than asked, a blank stretch, a Retina-sized page, one that doesn't
// scroll, one shorter than a scroll. Every stitched picture must equal the page pixel for pixel.
// Run: tools/scroll_stitch_test/run.sh
import AppKit

enum Toast { static func show(_ m: String, symbol: String = "", detail: String? = nil, footnote: String? = nil) { print("toast: \(m) \(detail ?? "")") } }
enum Capture { static let cacheFolder = FileManager.default.temporaryDirectory
               static func newCaptureURL(prefix: String) -> URL { cacheFolder.appendingPathComponent("\(prefix).png") } }
enum RegionCapture {
    static func pick(completion: @escaping (CGRect?, NSScreen?) -> Void, fallback: @escaping () -> Void) { completion(nil, nil) }
    static func showOutline(_ r: CGRect) -> NSWindow { NSWindow() }
}
final class PermissionGuide { static let shared = PermissionGuide(); func show() { print("permission guide shown") } }

/// A tall "page": random text-like rows and boxes, with optional sticky header/footer painted over every view.
struct Page {
    let w: Int, hs: Int, view: Int, header: Int, footer: Int
    let source: CGImage, headerImg: CGImage?, footerImg: CGImage?
    init(w: Int, hs: Int, view: Int, header: Int, footer: Int, blank: Range<Int>? = nil, seed: UInt64 = 7) {
        self.w = w; self.hs = hs; self.view = view; self.header = header; self.footer = footer
        var rng = SplitMix(seed)
        func draw(_ width: Int, _ height: Int, _ body: (CGContext) -> Void) -> CGImage {
            let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            body(c); return c.makeImage()!
        }
        source = draw(w, hs) { c in
            c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: hs))
            var y = 10
            while y < hs - 10 {
                let rowH = 8 + Int(rng.next() % 30)
                if let blank, blank.contains(y) { y += rowH; continue }
                var x = 20
                while x < w - 40 {
                    let len = 10 + Int(rng.next() % 120)
                    let g = Double(rng.next() % 200) / 255
                    c.setFillColor(CGColor(red: g, green: Double(rng.next() % 255) / 255, blue: 0.3, alpha: 1))
                    c.fill(CGRect(x: x, y: hs - y - rowH + 2, width: min(len, w - 40 - x), height: rowH - 4))   // CG is bottom-up
                    x += len + 6 + Int(rng.next() % 20)
                }
                y += rowH + 2
            }
        }
        headerImg = header > 0 ? draw(w, header) { c in c.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: header)); c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 20, y: header / 3, width: 200, height: header / 3)) } : nil
        footerImg = footer > 0 ? draw(w, footer) { c in c.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: footer)); c.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: w / 2, y: footer / 4, width: 120, height: footer / 2)) } : nil
    }
    var maxOffset: Int { hs - view }
    /// Static side columns (with content) painted over every view: only the middle scrolls, like a feed.
    var sidebars: Int = 0
    func paintSides(_ c: CGContext, height: Int) {
        guard sidebars > 0 else { return }
        for x in [0, w - sidebars] {
            c.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)); c.fill(CGRect(x: x, y: 0, width: sidebars, height: height))
            c.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
            for i in 0..<6 { c.fill(CGRect(x: x + 20, y: height - 60 - i * 70, width: sidebars - 40, height: 30)) }
        }
    }
    func frame(at off: Int) -> ScrollCapture.Frame {
        let c = CGContext(data: nil, width: w, height: view, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let slice = source.cropping(to: CGRect(x: 0, y: off, width: w, height: view))!
        c.draw(slice, in: CGRect(x: 0, y: 0, width: w, height: view))
        paintSides(c, height: view)
        if let h = headerImg { c.draw(h, in: CGRect(x: 0, y: view - header, width: w, height: header)) }
        if let f = footerImg { c.draw(f, in: CGRect(x: 0, y: 0, width: w, height: footer)) }
        return ScrollCapture.Frame(c.makeImage()!)!
    }
    /// What a perfect stitch gives: header once, the content between the bars, footer once.
    func expected() -> ScrollCapture.Frame {
        let c = CGContext(data: nil, width: w, height: hs, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(source, in: CGRect(x: 0, y: 0, width: w, height: hs))
        if let h = headerImg { c.draw(h, in: CGRect(x: 0, y: hs - header, width: w, height: header)) }
        if let f = footerImg { c.draw(f, in: CGRect(x: 0, y: 0, width: w, height: footer)) }
        return ScrollCapture.Frame(c.makeImage()!)!
    }
}
struct SplitMix { var s: UInt64; init(_ s: UInt64) { self.s = s }
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }

func check(_ name: String, page: Page, step: Int, actualStep: (Int) -> Int) async {
    var off = 0
    let first = page.frame(at: 0)
    let r = await ScrollCapture.stitch(first: first, scale: 1, step: step,
        next: { page.frame(at: off) }, scroll: { off = min(page.maxOffset, off + actualStep(off)) }, cancelled: { false })
    let got = ScrollCapture.Frame(r.stitcher.image(width: page.w)!)!
    let want = page.expected()
    var bad = 0
    let x0 = r.stitcher.crop?.lowerBound ?? 0
    if got.h == want.h {
        // Compared column by column (the stitched picture may be cropped to the scrolling columns)
        // (a cropped picture keeps a little of the static sides as padding; only the scrolling columns are compared)
        let cols = (0..<got.w).filter { x0 + $0 >= page.sidebars && x0 + $0 < page.w - page.sidebars }
        for y in 0..<got.h where got.rowDiff(y, want, y, cols: cols, offset: x0) > 2 { bad += 1 }
    }
    let widthOK = page.sidebars == 0 ? got.w == page.w : (got.w < page.w - page.sidebars && got.w >= page.w - 2 * page.sidebars - 1)
    let ok = got.h == want.h && bad == 0 && widthOK
    print("\(ok ? "PASS" : "FAIL") \(name): \(r.frames) shots, \(got.w)×\(got.h) (want \(page.sidebars == 0 ? page.w : page.w - 2 * page.sidebars)+×\(want.h)), rows off \(bad), reason '\(r.reason)'")
}

extension ScrollCapture.Frame {
    /// rowDiff against `other` with this frame's column x matching other's column x + offset.
    func rowDiff(_ ya: Int, _ other: ScrollCapture.Frame, _ yb: Int, cols: [Int], offset: Int) -> Int {
        var sum = 0, n = 0
        px.withUnsafeBufferPointer { a in other.px.withUnsafeBufferPointer { b in
            for x in cols { let i = (ya * w + x) * 4, j = (yb * other.w + x + offset) * 4
                sum += abs(Int(a[i]) - Int(b[j])) + abs(Int(a[i+1]) - Int(b[j+1])) + abs(Int(a[i+2]) - Int(b[j+2])); n += 3 } } }
        return n == 0 ? 0 : sum / n
    }
}

@main struct Harness2 { static func main() async {
    var feed = Page(w: 1200, hs: 3200, view: 800, header: 60, footer: 0, seed: 11); feed.sidebars = 300
    await check("feed between static sidebars (Facebook)", page: feed, step: 480, actualStep: { _ in 480 })
    await check("not scrollable (one view tall)", page: Page(w: 800, hs: 700, view: 700, header: 0, footer: 0), step: 420, actualStep: { _ in 420 })
    await check("shorter than one scroll", page: Page(w: 800, hs: 900, view: 700, header: 40, footer: 0), step: 420, actualStep: { _ in 420 })
    await check("plain page, no bars", page: Page(w: 800, hs: 3000, view: 700, header: 0, footer: 0), step: 420, actualStep: { _ in 420 })
    await check("sticky header + footer", page: Page(w: 800, hs: 3000, view: 700, header: 56, footer: 36), step: 420, actualStep: { _ in 420 })
    await check("sluggish page (scrolls 70% of the ask)", page: Page(w: 800, hs: 2600, view: 700, header: 56, footer: 0), step: 420, actualStep: { _ in 294 })
    await check("blank stretch in the middle", page: Page(w: 800, hs: 3200, view: 700, header: 0, footer: 36, blank: 1200..<2100), step: 420, actualStep: { _ in 420 })
    await check("retina-ish wide page", page: Page(w: 2280, hs: 4000, view: 1850, header: 120, footer: 0, seed: 3), step: 1110, actualStep: { _ in 1110 })
    exit(0)
} }
