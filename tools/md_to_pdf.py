#!/usr/bin/env python3
"""Render a Markdown doc as a printable A4 handout.

A small purpose-built Markdown subset renderer (headings, tables, fenced code,
lists, bold/inline code) rather than a general converter, so the hardware spec
prints cleanly with real tables and monospaced request bodies.
"""
import re
import sys

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (BaseDocTemplate, Frame, HRFlowable, KeepTogether,
                                PageTemplate, Paragraph, Preformatted, Spacer,
                                Table, TableStyle)

ACCENT = colors.HexColor('#0D47A1')
INK = colors.HexColor('#1A1A1A')
MUTED = colors.HexColor('#5F5E5A')
RULE = colors.HexColor('#D3D1C7')
CODE_BG = colors.HexColor('#F4F2ED')
WARN_BG = colors.HexColor('#FCEBEB')

ss = getSampleStyleSheet()


def style(name, **kw):
    base = dict(fontName='Helvetica', fontSize=9.5, leading=13.5,
                textColor=INK, alignment=TA_LEFT)
    base.update(kw)
    return ParagraphStyle(name, **base)


S = {
    'title': style('title', fontName='Helvetica-Bold', fontSize=20, leading=24,
                   textColor=ACCENT, spaceAfter=2),
    'sub': style('sub', fontSize=10, leading=14, textColor=MUTED, spaceAfter=10),
    'h2': style('h2', fontName='Helvetica-Bold', fontSize=13, leading=17,
                textColor=ACCENT, spaceBefore=13, spaceAfter=5),
    'h3': style('h3', fontName='Helvetica-Bold', fontSize=10.5, leading=14,
                textColor=INK, spaceBefore=9, spaceAfter=3),
    'body': style('body', spaceAfter=5),
    'li': style('li', leftIndent=11, bulletIndent=2, spaceAfter=2.5),
    'cell': style('cell', fontSize=8.5, leading=11.5),
    'cellh': style('cellh', fontSize=8.5, leading=11.5,
                   fontName='Helvetica-Bold', textColor=colors.white),
    'code': ParagraphStyle('code', fontName='Courier', fontSize=8,
                           leading=10.5, textColor=INK),
}


def inline(t):
    """Markdown inline -> reportlab markup."""
    t = (t.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;'))
    # Inline code uses Courier too, so it needs the same glyph fallback.
    t = re.sub(r'`([^`]+)`',
               lambda m: '<font face="Courier" size="8.5" backColor="#F0EEE9">'
                         + m.group(1).translate(ASCII_FALLBACK) + '</font>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<i>\1</i>', t)
    t = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', t)
    return t


def build_table(rows):
    head, body = rows[0], rows[1:]
    data = [[Paragraph(inline(c), S['cellh']) for c in head]]
    for r in body:
        data.append([Paragraph(inline(c), S['cell']) for c in r])

    ncols = len(head)
    avail = 170 * mm
    # First column narrower for 2-col key/value tables, else even split.
    widths = ([avail * 0.32] + [(avail * 0.68) / (ncols - 1)] * (ncols - 1)
              if ncols > 2 else [avail * 0.34, avail * 0.66])
    t = Table(data, colWidths=widths, repeatRows=1, hAlign='LEFT')
    t.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, 0), ACCENT),
        ('ROWBACKGROUNDS', (0, 1), (-1, -1),
         [colors.white, colors.HexColor('#F7F6F2')]),
        ('GRID', (0, 0), (-1, -1), 0.4, RULE),
        ('VALIGN', (0, 0), (-1, -1), 'TOP'),
        ('LEFTPADDING', (0, 0), (-1, -1), 5),
        ('RIGHTPADDING', (0, 0), (-1, -1), 5),
        ('TOPPADDING', (0, 0), (-1, -1), 3.5),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 3.5),
    ]))
    return t


# The built-in Type1 fonts have no box-drawing or arrow glyphs; ReportLab draws
# those as solid black boxes. Map them to ASCII rather than losing the diagram.
ASCII_FALLBACK = str.maketrans({
    '─': '-', '━': '-', '│': '|', '┃': '|', '└': '\\', '├': '|', '┌': '/',
    '►': '>', '→': '->', '▶': '>', '•': '*', '©': '(c)',
    '—': '--', '–': '-', '“': '"', '”': '"', '‘': "'", '’': "'", '≥': '>=',
    '≤': '<=', '×': 'x',
})


def code_block(lines):
    txt = '\n'.join(lines).translate(ASCII_FALLBACK)
    t = Table([[Preformatted(txt, S['code'])]], colWidths=[170 * mm],
              hAlign='LEFT')
    t.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, -1), CODE_BG),
        ('BOX', (0, 0), (-1, -1), 0.4, RULE),
        ('LEFTPADDING', (0, 0), (-1, -1), 7),
        ('RIGHTPADDING', (0, 0), (-1, -1), 7),
        ('TOPPADDING', (0, 0), (-1, -1), 5),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 5),
    ]))
    return t


def convert(md_path, pdf_path):
    lines = open(md_path).read().split('\n')
    # Title the PDF after the document's own H1 rather than a fixed string, so
    # the footer is right whichever doc is being rendered.
    doc_title = next((ln[2:].strip() for ln in lines if ln.startswith('# ')),
                     'Campus Bus Tracker')
    flow = []
    i = 0
    in_code = False
    code, table = [], []

    def flush_table():
        if table:
            flow.append(Spacer(1, 3))
            flow.append(build_table(list(table)))
            flow.append(Spacer(1, 6))
            table.clear()

    while i < len(lines):
        ln = lines[i]

        if ln.startswith('```'):
            if in_code:
                flow.append(code_block(code))
                flow.append(Spacer(1, 6))
                code.clear()
            in_code = not in_code
            i += 1
            continue
        if in_code:
            code.append(ln)
            i += 1
            continue

        if ln.startswith('|'):
            cells = [c.strip() for c in ln.strip().strip('|').split('|')]
            if not all(set(c) <= set('-: ') for c in cells):
                table.append(cells)
            i += 1
            continue
        flush_table()

        if ln.startswith('# '):
            flow.append(Paragraph(inline(ln[2:]), S['title']))
        elif ln.startswith('## '):
            flow.append(Paragraph(inline(ln[3:]), S['h2']))
            flow.append(HRFlowable(width='100%', thickness=0.5, color=RULE,
                                   spaceBefore=1, spaceAfter=5))
        elif ln.startswith('### '):
            flow.append(Paragraph(inline(ln[4:]), S['h3']))
        elif ln.strip() == '---':
            pass
        elif ln.startswith(('- ', '* ')):
            flow.append(Paragraph(inline(ln[2:]), S['li'], bulletText='•'))
        elif re.match(r'^\d+\. ', ln):
            n, rest = ln.split('. ', 1)
            flow.append(Paragraph(inline(rest), S['li'], bulletText=n + '.'))
        elif ln.strip():
            flow.append(Paragraph(inline(ln), S['body']))
        else:
            flow.append(Spacer(1, 3))
        i += 1

    flush_table()

    def decorate(canvas, doc):
        canvas.saveState()
        canvas.setFont('Helvetica', 7.5)
        canvas.setFillColor(MUTED)
        canvas.drawString(20 * mm, 12 * mm, f'Campus Bus Tracker — {doc_title}')
        canvas.drawRightString(190 * mm, 12 * mm, f'Page {doc.page}')
        canvas.setStrokeColor(RULE)
        canvas.setLineWidth(0.4)
        canvas.line(20 * mm, 15 * mm, 190 * mm, 15 * mm)
        canvas.restoreState()

    doc = BaseDocTemplate(pdf_path, pagesize=A4,
                          leftMargin=20 * mm, rightMargin=20 * mm,
                          topMargin=18 * mm, bottomMargin=20 * mm,
                          title=doc_title,
                          author='Campus Bus Tracker')
    frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height,
                  id='body')
    doc.addPageTemplates([PageTemplate(id='main', frames=[frame],
                                       onPage=decorate)])
    doc.build(flow)


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
    print(f'wrote {sys.argv[2]}')
