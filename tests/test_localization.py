"""Check translation coverage, format arguments, and real bundle language selection."""
import json
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = root / 'build/XGlyph.app/Contents/MacOS/XGlyph'
langs = ['en', 'ru', 'de', 'es', 'zh-Hans']
def read_strings(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
tables = {lang: read_strings(root / 'app/Resources' / (lang + '.lproj') / 'Localizable.strings') for lang in langs}
base = tables['en']
pattern = re.compile(r'%(?:\d+\$)?(?:\.\d+)?(?:@|[udi])|%%')
for lang, table in tables.items():
    assert table.keys() == base.keys(), (lang, 'missing/extra keys')
    for key, value in table.items():
        assert value.strip(), (lang, key, 'empty')
        assert pattern.findall(key) == pattern.findall(value), (lang, key, 'format mismatch')
    actual = json.loads(subprocess.check_output([str(app), '--localization-check', '-AppleLanguages', f'({lang})']))
    assert actual == table, (lang, 'bundle lookup differs from translation')
    subprocess.run([str(app), '--self-test', '-AppleLanguages', f'({lang})'], check=True)
# Regional fallbacks and unsupported language fallback use NSBundle's real selection.
for preferred, expected in [('ru-RU', 'ru'), ('de-DE', 'de'), ('es-MX', 'es'), ('zh-CN', 'zh-Hans'), ('it', 'en')]:
    actual = json.loads(subprocess.check_output([str(app), '--localization-check', '-AppleLanguages', f'({preferred})']))
    assert actual == tables[expected], (preferred, 'fallback')
# Every explicit localized key must exist. Brands, preference keys and protocol text stay literal.
source = (root / 'app/XGlyph.m').read_text()
keys = {json.loads(m) for m in re.findall(r'L\(@("(?:[^"\\]|\\.)*")\)', source)}
assert keys == base.keys(), (keys - base.keys(), base.keys() - keys)
print(f'Localization tests passed: {len(base)} messages, five languages, regional and English fallback.')
