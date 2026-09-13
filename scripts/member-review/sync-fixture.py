"""Keep the UITesting-only payload byte-identical to the captured review pack."""
import base64
from pathlib import Path
root = Path(__file__).resolve().parents[2]
data = (root / 'contracts/member-review/responses.json').read_bytes()
assert data == (root / 'ios/AtarasyCore/Tests/AtarasyCoreTests/Fixtures/member-review-responses.json').read_bytes()
p = root / 'ios/AtarasyPrototype/MemberReviewFixtureData.swift'
s = p.read_text()
a = s.index('    private static let encoded = "') + len('    private static let encoded = "')
b = s.index('"', a)
p.write_text(s[:a] + base64.b64encode(data).decode() + s[b:])
