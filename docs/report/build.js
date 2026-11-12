// build.js - turn REPORT.md (a small Markdown subset) into a Word document.
//   node build.js <REPORT.md> <source-root> <out.docx>
const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell,
  HeadingLevel, AlignmentType, WidthType, ShadingType, BorderStyle,
  LevelFormat, Footer, PageNumber, PageBreak, ImageRun,
} = require("docx");

const [, , mdPath, srcRoot, outPath] = process.argv;
const BODY = "Microsoft JhengHei";
const MONO = "Consolas";
const PAGE_W = 11906, MARGIN = 1000, CONTENT_W = PAGE_W - 2 * MARGIN;

const font = (ascii) => ({ ascii, hAnsi: ascii, eastAsia: BODY, cs: ascii });

// `code` and **bold** inside a line of text
function inline(text, base = {}) {
  const runs = [];
  const re = /(`[^`]+`|\*\*[^*]+\*\*)/g;
  let last = 0, m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) runs.push(new TextRun({ text: text.slice(last, m.index), ...base }));
    const tok = m[0];
    if (tok.startsWith("`"))
      runs.push(new TextRun({ text: tok.slice(1, -1), font: font(MONO), size: (base.size || 21) - 1, ...base, }));
    else
      runs.push(new TextRun({ text: tok.slice(2, -2), bold: true, ...base }));
    last = m.index + tok.length;
  }
  if (last < text.length) runs.push(new TextRun({ text: text.slice(last), ...base }));
  return runs;
}

function codeBlock(lines) {
  // trim trailing blank lines
  while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
  while (lines.length && lines[0].trim() === "") lines.shift();
  return lines.map((l, i) => new Paragraph({
    spacing: { before: i === 0 ? 80 : 0, after: i === lines.length - 1 ? 160 : 0, line: 220 },
    shading: { type: ShadingType.CLEAR, fill: "F3F4F6", color: "auto" },
    indent: { left: 100, right: 100 },
    children: [new TextRun({
      text: l.replace(/\t/g, "    ") || " ",
      font: font(MONO), size: 15,
    })],
  }));
}

function table(rows) {
  const ncol = rows[0].length;
  // column widths from content length (CJK counts double), clamped
  const len = (s) => [...s.replace(/[`*]/g, "")].reduce((a, c) => a + (c.charCodeAt(0) > 0x2e7f ? 2 : 1), 0);
  let w = Array(ncol).fill(0);
  rows.forEach((r) => r.forEach((c, i) => { w[i] = Math.max(w[i], Math.min(len(c), 46)); }));
  w = w.map((x) => Math.max(x, 5));
  const total = w.reduce((a, b) => a + b, 0);
  let widths = w.map((x) => Math.floor((x / total) * CONTENT_W));
  widths[ncol - 1] += CONTENT_W - widths.reduce((a, b) => a + b, 0);
  const border = { style: BorderStyle.SINGLE, size: 4, color: "BFC5CC" };
  const borders = { top: border, bottom: border, left: border, right: border };
  return new Table({
    width: { size: CONTENT_W, type: WidthType.DXA },
    columnWidths: widths,
    rows: rows.map((r, ri) => new TableRow({
      tableHeader: ri === 0,
      cantSplit: true,
      children: r.map((c, ci) => new TableCell({
        width: { size: widths[ci], type: WidthType.DXA },
        borders,
        shading: ri === 0 ? { type: ShadingType.CLEAR, fill: "E5E9EE", color: "auto" } : undefined,
        margins: { top: 60, bottom: 60, left: 100, right: 100 },
        children: [new Paragraph({
          spacing: { before: 0, after: 0, line: 300 },
          children: inline(c, { size: 19, bold: ri === 0 }),
        })],
      })),
    })),
  });
}

const md = fs.readFileSync(mdPath, "utf8").replace(/\r/g, "").split("\n");
const out = [];
let i = 0, seenTitle = false, front = true;

const readFile = (rel) => fs.readFileSync(path.join(srcRoot, rel), "utf8").replace(/\r/g, "").split("\n");

while (i < md.length) {
  const line = md[i];

  if (line.startsWith("```")) {
    const buf = [];
    i++;
    while (i < md.length && !md[i].startsWith("```")) buf.push(md[i++]);
    i++;
    out.push(...codeBlock(buf));
    continue;
  }
  if (line.startsWith("@include ")) {
    out.push(...codeBlock(readFile(line.slice(9).trim())));
    i++; continue;
  }
  if (line.startsWith("@image ")) {
    // "@image path" or "@image path max-width-in-pixels"
    const [rel, maxw] = line.slice(7).trim().split(/\s+/);
    const data = fs.readFileSync(path.join(path.dirname(mdPath), rel));
    const w = data.readUInt32BE(16), h = data.readUInt32BE(20);   // PNG IHDR
    const scale = Math.min((Number(maxw) || 658) / w, 860 / h, 1);
    out.push(new Paragraph({
      alignment: AlignmentType.CENTER, spacing: { before: 100, after: 200 },
      children: [new ImageRun({ type: "png", data,
        transformation: { width: Math.round(w * scale), height: Math.round(h * scale) } })],
    }));
    i++; continue;
  }
  if (line.startsWith("@source ")) {
    const rel = line.slice(8).trim();
    out.push(new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun({ text: rel, font: font(MONO) })] }));
    out.push(...codeBlock(readFile(rel)));
    i++; continue;
  }
  if (line.startsWith("| ")) {
    const rows = [];
    while (i < md.length && md[i].startsWith("|")) {
      if (!/^\|[\s:|-]+\|$/.test(md[i]))
        rows.push(md[i].replace(/^\|/, "").replace(/\|\s*$/, "").split("|").map((c) => c.trim()));
      i++;
    }
    out.push(table(rows));
    out.push(new Paragraph({ spacing: { before: 0, after: 120 }, children: [] }));
    continue;
  }
  if (line.startsWith("# ")) {
    const text = line.slice(2);
    if (!seenTitle) {
      seenTitle = true;
      out.push(new Paragraph({ spacing: { before: 3600, after: 300 }, alignment: AlignmentType.CENTER,
        children: [new TextRun({ text, bold: true, size: 52 })] }));
    } else {
      front = false;
      out.push(new Paragraph({ heading: HeadingLevel.HEADING_1, pageBreakBefore: true, children: inline(text) }));
    }
    i++; continue;
  }
  if (line.startsWith("## ")) {
    out.push(new Paragraph({ heading: HeadingLevel.HEADING_2, children: inline(line.slice(3)) }));
    i++; continue;
  }
  if (/^- /.test(line)) {
    out.push(new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { before: 0, after: 60, line: 340 },
      children: inline(line.slice(2)) }));
    i++; continue;
  }
  if (/^\d+\. /.test(line)) {
    out.push(new Paragraph({ numbering: { reference: "numbers", level: 0 }, spacing: { before: 0, after: 60, line: 340 },
      children: inline(line.replace(/^\d+\. /, "")) }));
    i++; continue;
  }
  if (line.trim() === "") { i++; continue; }

  out.push(new Paragraph({
    alignment: front ? AlignmentType.CENTER : AlignmentType.LEFT,
    spacing: { before: 0, after: front ? 240 : 140, line: 340 },
    children: inline(line, front ? { size: 26 } : {}),
  }));
  i++;
}

const doc = new Document({
  styles: {
    default: {
      document: { run: { font: font(BODY), size: 21 } },
      heading1: { run: { font: font(BODY), size: 32, bold: true, color: "1F2937" },
        paragraph: { spacing: { before: 0, after: 200 }, keepNext: true } },
      heading2: { run: { font: font(BODY), size: 25, bold: true, color: "1F2937" },
        paragraph: { spacing: { before: 280, after: 120 }, keepNext: true } },
    },
  },
  numbering: {
    config: [
      { reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 420, hanging: 260 } } } }] },
      { reference: "numbers", levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 420, hanging: 300 } } } }] },
    ],
  },
  sections: [{
    properties: { page: { size: { width: PAGE_W, height: 16838 },
      margin: { top: 1100, bottom: 1100, left: MARGIN, right: MARGIN } } },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
      children: [new TextRun({ children: [PageNumber.CURRENT], size: 18, color: "6B7280" })] })] }) },
    children: out,
  }],
});

Packer.toBuffer(doc).then((buf) => {
  fs.writeFileSync(outPath, buf);
  console.log("wrote", outPath, buf.length, "bytes,", out.length, "blocks");
});
