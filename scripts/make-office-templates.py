#!/usr/bin/env python3
"""重新生成内置模板；仅维护资源时需要安装 python-docx、openpyxl、python-pptx。"""
from pathlib import Path
from io import BytesIO
from zipfile import ZipFile, ZIP_DEFLATED
from datetime import datetime, timezone

from docx import Document
from openpyxl import Workbook
from pptx import Presentation

ROOT = Path(__file__).resolve().parents[1] / "Sources/FinderMenuCore/Resources/OfficeTemplates"


def save_package(document, suffix):
    buffer = BytesIO()
    document.save(buffer)
    # 统一压缩包时间戳，避免无内容变化时更新资源。
    with ZipFile(buffer) as source, ZipFile(ROOT / ("blank." + suffix), "w", ZIP_DEFLATED) as output:
        for name in sorted(source.namelist()):
            from zipfile import ZipInfo
            entry = ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            entry.compress_type = ZIP_DEFLATED
            output.writestr(entry, source.read(name))


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    document = Document()
    document.add_paragraph()
    document.core_properties.author = ""
    document.core_properties.last_modified_by = ""
    save_package(document, "docx")
    workbook = Workbook()
    workbook.properties.creator = ""
    workbook.properties.created = datetime(2026, 1, 1, tzinfo=timezone.utc)
    workbook.properties.modified = workbook.properties.created
    save_package(workbook, "xlsx")
    presentation = Presentation()
    blank = presentation.slide_layouts[6]
    presentation.slides.add_slide(blank)
    # 默认母版包含未使用的图片占位布局，会触发部分办公应用的导入警告。
    # 通过关联删除裁掉这些部件，只保留空白布局及其完整母版和主题。
    master = presentation.slide_masters[0]
    for layout_id in list(master.slide_layouts._sldLayoutIdLst):
        if master.part.related_part(layout_id.rId) is not blank.part:
            master.part.drop_rel(layout_id.rId)
            master.slide_layouts._sldLayoutIdLst.remove(layout_id)
    presentation.core_properties.author = ""
    presentation.core_properties.last_modified_by = ""
    save_package(presentation, "pptx")
    # 一页空白文档，包含完整页树、空内容流和交叉引用表。
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << >> /Contents 4 0 R >>",
        b"<< /Length 0 >>\nstream\n\nendstream",
    ]
    data = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, body in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{index} 0 obj\n".encode() + body + b"\nendobj\n")
    xref = len(data)
    data.extend(b"xref\n0 5\n0000000000 65535 f \n")
    for offset in offsets[1:]:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    (ROOT / "blank.pdf").write_bytes(data)


if __name__ == "__main__":
    main()
