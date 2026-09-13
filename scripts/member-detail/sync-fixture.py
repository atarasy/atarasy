"""Refresh only the compiled-out UI fixture payload after a deliberate capture."""
from pathlib import Path
import base64
import re
source = Path('contracts/member-detail/responses.json')
target = Path('ios/AtarasyPrototype/MemberDetailFixtureData.swift')
pattern = r'Data\(base64Encoded: "[A-Za-z0-9+/=]+"\)!'
text = target.read_text()
assert text.startswith('#if ATARASY_UI_TEST_FIXTURES\n')
assert len(re.findall(pattern, text)) == 1
encoded = base64.b64encode(source.read_bytes()).decode('ascii')
target.write_text(re.sub(pattern, f'Data(base64Encoded: "{encoded}")!', text))
assert source.read_bytes() == Path('ios/AtarasyCore/Tests/AtarasyCoreTests/Fixtures/member-detail-responses.json').read_bytes()
print('UI fixture payload matches the captured contract pack; test-only condition retained.')
