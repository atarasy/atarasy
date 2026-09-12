# iOS-first contract pack

Status: executable subset, not a complete or production-ready API. The accompanying source manifest pins read-only Git objects. All examples and presentation fixtures are synthetic. Dummy base64 assertions deliberately cannot establish cryptographic authority.

## Contents

- OpenAPI 3.1 inventory for selected existing routes, with external JSON Schema 2020-12 files.
- Six existing native-client subset schemas: decision, settlement, mandate, collection, offer query and statement response.
- One proposed private operation envelope, explicitly unimplemented and separate from strict public request bodies.
- Fifteen positive/negative request examples and five proposed-envelope validation cases.
- Two households, two merchants and four presentation-model offers. These are UI fixtures, not complete server seed commands or evidence of deployed isolation.
- Nine canonical vectors generated from the Web reference and checked independently by Swift and pinned engine functions.

## Interpretation

Schema-valid is not signature-valid, authorised or financially eligible. Empty settlement requests are structurally valid for some protocol paths and do not permit an unsigned consumed physical statement. Collection candidate membership and permitted verdict changes need server state. The native request subset deliberately excludes bare signatures, uses standard base64 and bounds integers to the JavaScript safe range. Those restrictions are client policy and must not be misreported as exact server rejection behavior.

Statement response data includes null carriage when delivery is absent. The native prototype rejects signing in that condition even if a response carries a challenge. A disputed line retains its original amount in canonical statement bytes with its disputed flag; do not zero the signed amount merely because the charge excludes it.

The initial Swift codec conservatively rejects delimiter-bearing decision/statement identifiers and duplicate UTF-8 candidate identifiers. This is a bounded prototype client policy, not a new protocol restriction. Canonically equivalent Unicode spellings remain distinct byte identities, and sorting follows JavaScript UTF-16 ordering.

## Incomplete contracts

Complete catalogue/disclosure/config publication, offer/approval result schemas, settlement/refusal pack, identity/session protocol, permissions, recovery/export and the operational coordinator remain incomplete. OpenAPI default response descriptions intentionally expose that gap. There is no production server URL or security scheme pretending that the reference authenticates callers.

The proposed envelope's digest and actor binding require service verification; regex/type validation proves neither. Source metadata and examples make the next contract work reproducible but do not close CP-B01 or protected-release gates as a whole.
