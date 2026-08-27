#!/usr/bin/env python3
"""
ssd-csv-to-xlsx.py — turn a fleet CSV into a formatted Excel workbook.

    ./ssd-csv-to-xlsx.py fleet.csv                 -> fleet.xlsx
    ./ssd-csv-to-xlsx.py fleet.csv -o drives.xlsx

Standard library only - no pip installs. An .xlsx is a zip of XML parts, so
it is written directly rather than pulling in openpyxl, which keeps this
runnable on a locked-down workstation.

The sheet has a frozen, filterable header, numeric columns stored as numbers
so sorting works, and rows shaded by status: red CRITICAL, amber WARN, grey
UNKNOWN. Worst drive first, same order as the CSV.
"""
import argparse, csv, os, re, sys, zipfile
from xml.sax.saxutils import escape

# Columns stored as numbers so Excel sorts and filters them properly.
NUMERIC = {"capacity_gb", "life_remaining_pct", "life_used_pct", "available_spare_pct",
           "power_on_hours", "temperature_c", "data_written_tb", "error_count",
           "wear_pct_per_year", "est_days_remaining"}
WIDTHS = {"timestamp": 20, "asset_id": 13, "hostname": 16, "device": 12, "protocol": 9,
          "model": 26, "serial": 20, "firmware": 11, "capacity_gb": 12, "media_type": 11,
          "smart_status": 13, "life_remaining_pct": 12, "life_used_pct": 11,
          "life_source": 34, "available_spare_pct": 12, "power_on_hours": 13,
          "temperature_c": 11, "data_written_tb": 13, "error_count": 10,
          "wear_pct_per_year": 13, "est_days_remaining": 13, "est_eol_date": 13,
          "est_method": 16, "status": 11, "life_confidence": 13}

# style ids: 0 default, 1 header, 2 critical, 3 warn, 4 unknown
STYLES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="3">
<font><sz val="11"/><name val="Calibri"/></font>
<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>
<font><b/><sz val="11"/><name val="Calibri"/></font>
</fonts>
<fills count="6">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF1F3864"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFF8CBCB"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFFFE8B0"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFE4E4E4"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="5">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
<xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyFill="1"/>
<xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0" applyFill="1"/>
<xf numFmtId="0" fontId="0" fillId="5" borderId="0" xfId="0" applyFill="1"/>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>"""

def col_letter(n):
    s = ""
    while n > 0:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s

def is_number(v):
    return bool(v) and re.fullmatch(r"-?\d+(\.\d+)?", v.strip()) is not None

def sheet_xml(header, rows):
    ncol = len(header)
    last = col_letter(ncol)
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
           '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
           '<cols>']
    for i, h in enumerate(header, 1):
        out.append(f'<col min="{i}" max="{i}" width="{WIDTHS.get(h, 14)}" customWidth="1"/>')
    out.append('</cols><sheetData>')

    out.append('<row r="1">')
    for i, h in enumerate(header, 1):
        out.append(f'<c r="{col_letter(i)}1" s="1" t="inlineStr">'
                   f'<is><t>{escape(h)}</t></is></c>')
    out.append('</row>')

    status_i = header.index("status") if "status" in header else -1
    for rn, row in enumerate(rows, start=2):
        style = 0
        if status_i >= 0 and status_i < len(row):
            style = {"CRITICAL": 2, "WARN": 3, "UNKNOWN": 4}.get(row[status_i], 0)
        out.append(f'<row r="{rn}">')
        for i, h in enumerate(header, 1):
            v = row[i - 1] if i - 1 < len(row) else ""
            ref = f"{col_letter(i)}{rn}"
            s = f' s="{style}"' if style else ""
            if v == "":
                out.append(f'<c r="{ref}"{s}/>')
            elif h in NUMERIC and is_number(v):
                out.append(f'<c r="{ref}"{s}><v>{v}</v></c>')
            else:
                out.append(f'<c r="{ref}"{s} t="inlineStr"><is><t>{escape(v)}</t></is></c>')
        out.append('</row>')
    out.append('</sheetData>')
    # Freeze the header and switch on filtering, so a 900-row sheet is usable.
    out.append('<autoFilter ref="A1:%s%d"/>' % (last, len(rows) + 1))
    out.append('</worksheet>')
    # sheetView must precede sheetData in the schema.
    pane = ('<sheetViews><sheetView workbookViewId="0" tabSelected="1">'
            '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
            '</sheetView></sheetViews>')
    return out[0] + out[1] + pane + "".join(out[2:])

def write_xlsx(path, header, rows, sheet_name="SSD Fleet"):
    ct = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
          '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
          '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
          '</Types>')
    rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            '</Relationships>')
    wb = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          f'<sheets><sheet name="{escape(sheet_name)}" sheetId="1" r:id="rId1"/></sheets>'
          '</workbook>')
    wbrels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
              '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
              '</Relationships>')
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", ct)
        z.writestr("_rels/.rels", rels)
        z.writestr("xl/workbook.xml", wb)
        z.writestr("xl/_rels/workbook.xml.rels", wbrels)
        z.writestr("xl/styles.xml", STYLES)
        z.writestr("xl/worksheets/sheet1.xml", sheet_xml(header, rows))

def convert(csv_path, xlsx_path=None):
    if not xlsx_path:
        xlsx_path = os.path.splitext(csv_path)[0] + ".xlsx"
    with open(csv_path, newline="", encoding="utf-8") as fh:
        r = list(csv.reader(fh))
    if not r:
        raise SystemExit(f"ERROR: {csv_path} is empty")
    write_xlsx(xlsx_path, r[0], [row for row in r[1:] if any(row)])
    return xlsx_path, len(r) - 1

def main():
    ap = argparse.ArgumentParser(description="Convert a fleet CSV to a formatted .xlsx")
    ap.add_argument("csv")
    ap.add_argument("-o", "--output")
    a = ap.parse_args()
    if not os.path.exists(a.csv):
        sys.exit(f"ERROR: no such file: {a.csv}")
    out, n = convert(a.csv, a.output)
    print(f"Wrote {out} ({n} row(s))")
    print("  header frozen and filterable; CRITICAL red, WARN amber, UNKNOWN grey")

if __name__ == "__main__":
    main()
