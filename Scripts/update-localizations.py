#!/usr/bin/env python3
"""Keep Chinese SwiftUI source strings in the editable Xcode String Catalog."""
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parent.parent
path = root / 'Sources/MacXTermApp/Resources/Localizable.xcstrings'
catalog = json.loads(path.read_text())
pattern = re.compile(r'\b(?:Text|Button|Label|Section|Picker|Toggle|LabeledContent|TextField|SecureField|ProgressView|ContentUnavailableView|GroupBox|CommandMenu|help|navigationTitle)\(\s*"((?:[^"\\]|\\.)*)"')
for source in (root / 'Sources/MacXTermApp').glob('*.swift'):
    for match in pattern.finditer(source.read_text()):
        raw = match.group(1)
        if r'\(' in raw:
            continue  # Xcode's compiler extracts interpolated localization keys.
        try:
            key = json.loads('"' + raw + '"')
        except json.JSONDecodeError:
            continue
        if not key or not any('\u4e00' <= c <= '\u9fff' for c in key):
            continue
        catalog['strings'].setdefault(key, {
            'extractionState': 'manual',
            'localizations': {'zh-Hans': {'stringUnit': {'state': 'translated', 'value': key}}}
        })
path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
print(f'{len(catalog["strings"])} source strings in {path.name}')
