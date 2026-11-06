#!/usr/bin/env python3
"""检查内置办公压缩包的结构、内容类型及全部内部关联；仅依赖标准库。"""
import posixpath
import sys
from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1] / "Sources/FinderMenuCore/Resources/OfficeTemplates"
REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"


def validate(root):
    for suffix, part in [("docx", "word/document.xml"), ("xlsx", "xl/workbook.xml"), ("pptx", "ppt/presentation.xml")]:
        with ZipFile(root / ("blank." + suffix)) as archive:
            assert archive.testzip() is None
            names = set(archive.namelist())
            assert {"[Content_Types].xml", "_rels/.rels", part} <= names
            xml = {name: ET.fromstring(archive.read(name)) for name in names if name.endswith((".xml", ".rels"))}
            types = xml["[Content_Types].xml"]
            assert any(node.attrib.get("PartName") == "/" + part for node in types)
            assert any(node.attrib["Type"].endswith("/officeDocument") and node.attrib["Target"].lstrip("/") == part for node in xml["_rels/.rels"])
            for name, tree in xml.items():
                if not name.endswith(".rels"):
                    continue
                parent = posixpath.dirname(posixpath.dirname(name))
                for relation in tree:
                    assert relation.tag == REL + "Relationship"
                    if relation.attrib.get("TargetMode") == "External":
                        continue
                    target = relation.attrib["Target"]
                    resolved = posixpath.normpath(target.lstrip("/") if target.startswith("/") else posixpath.join(parent, target))
                    assert resolved in names, (name, resolved)
            if suffix == "docx":
                assert not xml[part].findall(".//{*}t")
            elif suffix == "xlsx":
                assert len(xml[part].findall(".//{*}sheet")) == 1
                assert "xl/worksheets/sheet1.xml" in names
                assert not xml["xl/worksheets/sheet1.xml"].findall(".//{*}c")
            else:
                assert len(xml[part].findall(".//{*}sldId")) == 1
                assert "ppt/slides/slide1.xml" in names
                assert not xml["ppt/slides/slide1.xml"].findall(".//{*}sp")
                layouts = [name for name in names if name.startswith("ppt/slideLayouts/") and name.endswith(".xml")]
                assert len(layouts) == 1
                assert xml[layouts[0]].attrib.get("type") == "blank"
        print(suffix + "：压缩包、结构、关联关系和空白内容通过")


if __name__ == "__main__":
    validate(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT)
