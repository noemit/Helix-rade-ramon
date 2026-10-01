import AppKit
import HelixKit
import PDFKit
import SwiftUI

/// Prints views the way Helix did: forms one record per page, lists as pages of rows with the
/// template's header repeated on every page. Pages are rendered to PDF, then printed or saved.
@MainActor
enum ViewPrinter {
    struct Job {
        let title: String
        let template: Template
        let design: Design
        let relation: Relation
        let records: [Record]
        let evaluator: AbacusEvaluator
    }

    /// Printable area of the current page setup, in points.
    static var printable: CGRect {
        let info = NSPrintInfo.shared
        return CGRect(x: info.leftMargin, y: info.bottomMargin,
                      width: info.paperSize.width - info.leftMargin - info.rightMargin,
                      height: info.paperSize.height - info.topMargin - info.bottomMargin)
    }

    static func pdf(_ job: Job) -> Data {
        let paper = NSPrintInfo.shared.paperSize
        let area = printable
        let pages = job.template.repeatElement.map { listPages(job, $0, area.size) } ?? formPages(job, area.size)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: job.title] as CFDictionary)
        else { return Data() }
        for page in pages {
            let renderer = ImageRenderer(content: page.frame(width: area.width, height: area.height, alignment: .topLeading)
                .environment(\.colorScheme, .light))
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: area.minX, y: area.minY)
            renderer.render { _, draw in draw(ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    private static func context(_ job: Job, _ r: Record?) -> TemplateContext {
        var c = TemplateContext(design: job.design, relation: job.relation, record: r, evaluator: job.evaluator)
        c.forPrint = true
        return c
    }

    /// One record per page, scaled down if the template is larger than the page.
    private static func formPages(_ job: Job, _ size: CGSize) -> [AnyView] {
        let b = job.template.contentBounds
        let w = CGFloat(b.right + 4), h = CGFloat(b.bottom + 4)
        let scale = min(1, size.width / w, size.height / h)
        return job.records.map { r in
            AnyView(TemplateCanvas(elements: job.template.elements, context: context(job, r))
                .frame(width: w, height: h, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading))
        }
    }

    /// Header on every page, as many rows as fit, footer (totals) after the last row.
    private static func listPages(_ job: Job, _ rep: TemplateElement, _ size: CGSize) -> [AnyView] {
        let layout = ListLayout(template: job.template, repeatElement: rep)
        let scale = min(1, size.width / layout.width)
        let usable = size.height / scale
        let perPage = max(1, Int((usable - layout.headerHeight - 4) / CGFloat(layout.stride)))
        let chunks = stride(from: 0, to: max(job.records.count, 1), by: perPage).map {
            Array(job.records[$0..<min($0 + perPage, job.records.count)])
        }
        return chunks.enumerated().map { i, rows in
            let last = i == chunks.count - 1
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                TemplateCanvas(elements: layout.header, context: context(job, job.records.first))
                    .frame(width: layout.width, height: layout.headerHeight, alignment: .topLeading)
                ForEach(rows) { r in
                    TemplateCanvas(elements: layout.rowElements, context: context(job, r))
                        .offset(y: CGFloat(-layout.rep.top))
                        .frame(width: layout.width, height: CGFloat(layout.stride), alignment: .topLeading)
                        .clipped()
                }
                if last, !layout.footer.isEmpty {
                    TemplateCanvas(elements: layout.footer, context: context(job, job.records.first))
                        .offset(y: CGFloat(-layout.rep.bottom))
                        .frame(width: layout.width, height: layout.footerHeight, alignment: .topLeading)
                }
                Spacer(minLength: 0)
                Text("\(job.title) — \(i + 1) / \(chunks.count)")
                    .font(.system(size: 8)).foregroundStyle(.gray)
                    .frame(width: layout.width, alignment: .center)
            }
            .frame(width: layout.width, height: usable, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width, height: size.height, alignment: .topLeading))
        }
    }

    static func print(_ job: Job) {
        guard let doc = PDFDocument(data: pdf(job)),
              let op = doc.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleNone, autoRotate: false) else { return }
        op.jobTitle = job.title
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }

    static func savePDF(_ job: Job) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(job.title).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try pdf(job).write(to: url) } catch { NSAlert(error: error).runModal() }
    }
}
