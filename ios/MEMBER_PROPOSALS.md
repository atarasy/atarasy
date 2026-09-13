# Authenticated member proposal summaries

The configured member account now displays a separate, read-only proposal summary list after login or saved-session inspection. The service client supplies household and presenter grants from the inspected session. No household or source typed into the screen becomes authority. The original sample inbox remains synthetic and is never used as an authenticated detail screen.

## Source and session behaviour

The screen queries each granted presenter, with at most four requests in flight. It preserves grant order and response row order. Repeated presenter grants are deduplicated by exact UTF-8 bytes; Unicode-equivalent but byte-distinct identifiers remain separate. The model rechecks row household/presenter scope and rejects duplicate IDs within a source, unknown bindings and empty identifiers/states in addition to the member client's checks.

A source has loading, available or unavailable state. An available empty source says it has no proposals. A failed or malformed source remains unavailable and contributes to the incomplete-list notice. Refresh clears old rows and makes a new explicit read; it does not silently retry failed sources or make old rows look freshly verified. A cancelled refresh leaves unchecked sources unavailable.

Closing the account, logout, session expiry or switching account clears the list and invalidates its generation. Late results cannot repopulate it or invalidate a newer session. A current 401 or expired result clears the whole authenticated display through the account model. Source-local failures preserve already checked sources. The real member client independently rechecks the bearer session around each read.

The summary contract provides identifiers, household, presenter, binding and state. It does not provide a product title, amount, arrival time or complete approval data. The list displays text summaries without inventing those values or exposing a decision/payment button. Full authenticated detail and transaction composition remain later work.

## Test configurations

Normal Debug and Release builds contain no proposal fixture entry. The dedicated `UITesting` configuration sets `ATARASY_UI_TEST_FIXTURES`; the `AtarasyMemberListTests` scheme uses it. In this build only, the `--member-list-fixture` launch argument opens a labelled test-data list from Member account. The fixture exercises the same view and list model with available, failed and verified-empty sources. It makes no network request and does not simulate a successful passkey or member login.

From the repository root, regenerate the project with `xcodegen generate --spec ios/project.yml`. Run the `AtarasyMemberListTests` scheme on a simulator for fixture UI tests. Use the `AtarasyPrototype` scheme for normal application builds. Do not distribute UITesting products as a configured member application.

The test-only list is compiled out by its source condition and entry condition in normal builds. The validation record includes a normal Release compilation and binary inspection, as well as test-configuration UI results. Fixture screenshots are design/test evidence, not authenticated network or physical-device evidence.

The full offer-detail projection and native navigation described in steps 1 and 2 follow in [member detail](MEMBER_DETAIL.md), with their own validation and remaining approval boundaries.

## Next integration

1. Pin a full offer-detail projection from the member service and map it into a separate authenticated detail model. Preserve missing fields and refusal states; do not reuse synthetic totals or signing responses.
2. Add source-aware navigation and retain session-generation checks during detail loads and refresh. Distinguish physical collection state from a digital choice.
3. Complete actual app identity/domain and controlled transport configuration described in [native setup](NATIVE_MEMBER_SETUP.md), then measure login, member reads, expiry and logout on iPhone and iPad.
4. Add transaction approval only once its canonical challenge, trusted state and uncertain-outcome/read-back contract are exercised against the real service. Read access is not transaction authority or provider completion.

See [proposal validation](evidence/member-proposals-validation.json) for this checkpoint. Earlier evidence files retain the source hashes and limitations of their original increments.
