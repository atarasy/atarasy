"""Structural fixture checks only; not server, identity or signature verification."""
import json
from pathlib import Path
from jsonschema import Draft202012Validator
root=Path(__file__).resolve().parents[2]
pack=root/'contracts/ios-first'
schemas={p.stem.removesuffix('.schema'):json.loads(p.read_text()) for p in pack.glob('*.schema.json')}
for schema in schemas.values():Draft202012Validator.check_schema(schema)
examples=json.loads((pack/'schema-examples.json').read_text())
for example in examples:
    actual=Draft202012Validator(schemas[example['schema']]).is_valid(example['value'])
    assert actual == example['valid'],example['id']
base={'contract_version':'integration.operation/0','client_operation_id':'fixture_operation_0001','action':'decision','target':'digital-a','content_sha256':'a'*64,'request':examples[0]['value']}
validator=Draft202012Validator(schemas['ProposedOperation'])
assert validator.is_valid(base)
for invalid in [{**base,'action':'statement'},{**base,'actor':'household-fixture-b'},{**base,'content_sha256':'not-a-digest'},{**base,'contract_version':'unsupported'}]:assert not validator.is_valid(invalid)
fixtures=json.loads((pack/'fixtures.json').read_text());assert fixtures['synthetic'];assert len(fixtures['households'])==len(fixtures['merchants'])==2
for f in fixtures['offers']:assert f['household'] in fixtures['households'] and f['presenter'] in fixtures['merchants']
for n in ['canonical-vectors','fixtures']:
    assert (pack/(n+'.json')).read_bytes() == (root/'ios/AtarasyCore/Tests/AtarasyCoreTests/Fixtures'/(n+'.json')).read_bytes()
print(json.dumps({'schemas':len(schemas),'request_examples':len(examples),'proposed_envelope_cases':5,'fixtures':'two households and two merchants; resource copies match','limits':'Structural checks only. No signature or deployed access control tested.'},indent=2))
responses=json.loads((pack/'response-examples.json').read_text())
negative_count=0
for example in responses['cases']:
    schema=schemas[example['schema']];validator=Draft202012Validator(schema)
    validator.validate(example['value'])
    missing=dict(example['value']);del missing[schema['required'][0]]
    assert not validator.is_valid(missing),example['id']+' missing field'
    assert not validator.is_valid({**example['value'],'unexpected_presentation':'<script>'}),example['id']+' extra field'
    negative_count+=2
assert (pack/'response-examples.json').read_bytes()==(root/'ios/AtarasyCore/Tests/AtarasyCoreTests/Fixtures/response-examples.json').read_bytes()
print(json.dumps({'reference_responses':len(responses['cases']),'negative_response_cases':negative_count,'source_commit':responses['source']['commit'],'limits':'In-process reference handler; no transport, native credential, provider or deployed access-control verification'},indent=2))
