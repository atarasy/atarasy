/**
 * The screen's vocabulary in the member's language, picked from
 * `navigator.language`. Vault `80` D-5 and §6.3.
 *
 * The English side of every entry is the exact string this screen already
 * shows (or, for a wording brought over from `22`, the iOS app's own
 * English), and the Japanese side is the iOS app's Japanese for that same
 * element, copied verbatim from `ios/AtarasyPrototype/Resources/*.lproj/`
 * rather than translated again here. A hub and a native app disagreeing
 * about what to call the same thing is a worse defect than either being
 * imperfect on its own; using one source removes the chance of it.
 *
 * Not every sentence in this hub has an iOS counterpart: the longer,
 * clause-citing explanations this screen carries (the ones with a section
 * number in their own comment) are this hub's own and stay English-only.
 * What is here is what the plan's D-5 and the acceptance test both call
 * "equivalent elements": navigation, section and row wording, button labels
 * and the shared vocabulary table (vault `80` §6.3).
 */

export type Lang = "en" | "ja";

/** navigator.language, ja* to Japanese, everything else to English. */
export function pickLanguage(navigatorLanguage: string): Lang {
  return navigatorLanguage.toLowerCase().startsWith("ja") ? "ja" : "en";
}

/**
 * English key -> Japanese value, `%@` / `%lld` positional or `%1$@`-style
 * indexed, matching the iOS `.strings` placeholders these were copied from.
 */
const JA: Record<string, string> = {
  // These two have no iOS counterpart: the app reaches an offer through a
  // `NavigationLink` row and returns through the navigation stack's own back
  // button, neither of which is a string. This hub's cards need one of each.
  "Open": "開く",
  "Back": "戻る",
  "%@ and %lld more": "%1$@ ほか %2$lld 点",
  "This account cannot be deleted yet": "このアカウントはまだ削除できません",
  "Account deleted": "アカウントを削除しました",
  "A box": "お届け箱",
  "A box or order is still open. Finish or decline it first.": "終わっていない箱や注文があります。先に終えるか、見送ってください。",
  "A proposal": "ご提案",
  "About this account": "このアカウントについて",
  "Account": "アカウント",
  "Account reference": "アカウント番号",
  "After the change": "変更後",
  "After this date nothing can be bought for you until you sign new limits.": "この日を過ぎると、新しい設定に署名するまで何も買いません。",
  "After you sign a decision, how long you have to undo it.": "決定に署名したあと、取り消せる期間です。",
  "Already settled": "すでに精算済み",
  "Alternatives": "ほかの選択肢",
  "Amounts are in %@.": "金額の単位は %@ です。",
  "Another person": "ほかの人",
  "At a shop outside your network": "登録外のお店での上限",
  "At home": "お手元の箱",
  "Atarasy": "Atarasy",
  "Box": "お届け箱",
  "Boxes delivered to you. Use what you like; you pay only for what you use.": "ご自宅に届いている箱です。気になるものを使い、使った分だけお支払いください。",
  "Cancel this change": "この変更を取りやめる",
  "Change at least one limit. Amounts must be whole numbers, the time to undo at most 30 days, and each person listed once.": "1 つ以上の項目を変えてください。金額は整数、取り消せる期間は 30 日以内、同じ人は 1 回だけ入力できます。",
  "Change limits": "設定の変更",
  "Change these limits": "この設定を変える",
  "Change to your limits": "見守り設定の変更",
  "Changes waiting for signatures": "署名待ちの変更",
  "Check result": "結果を確認",
  "Checked %@": "%@ に確認",
  "Checking your shops": "ショップを確認しています",
  "Checking\u2026": "確認しています…",
  "Choose Keep or Decline for each item (%lld of %lld).": "品目ごとに「受け取る」か「見送る」を選んでください（%2$lld 点中 %1$lld 点）。",
  "Closed": "締め切り済み",
  "Closed, nothing to pay": "終了（お支払いなし）",
  "Closes %@.": "%@ に締め切り。",
  "Closes %@. Nothing is bought if you do nothing.": "%@ に締め切り。何もしなければ何も買いません。",
  "Confirm the statement to receive the next box": "明細を確認すると次の箱が届きます",
  "Correction from %@": "%@ からの訂正",
  "Corrections from the shop": "ショップからの訂正",
  "Could not be checked.": "確認できませんでした。",
  "Could not open this": "開けませんでした",
  "Create passkey": "パスキーを作成",
  "Daily limit": "1 日の上限",
  "Decision recorded": "決定を記録しました",
  "Decision undone": "決定を取り消しました",
  "Decisions and statements you signed on this device, and their results.": "この端末で署名した決定と明細、その結果です。",
  "Decline": "見送る",
  "Declined.": "見送りました。",
  "Delete account": "アカウントを削除",
  "Delete this account?": "このアカウントを削除しますか？",
  "Deleting removes your account and everything this host holds for it. Shops keep their own records of sales. Gifts you shared with other households stay in their records, showing you as a member who has left.": "削除すると、アカウントと保管先にあるすべてのデータが消えます。ショップは自社の販売記録を保持します。ほかの世帯に贈ったものは相手の記録に残り、退会した会員として表示されます。",
  "Delivery": "送料",
  "Delivery costs have not been recorded. This statement is not ready to sign.": "送料がまだ記録されていないため、この明細にはまだ署名できません。",
  "Delivery costs have not been recorded. You can choose now and sign once they are.": "送料がまだ記録されていません。いま選んでおき、記録されてから署名できます。",
  "Done": "完了",
  "Enter the account reference each person gives you.": "それぞれの人から伝えられたアカウント番号を入力してください。",
  "Enter the invitation code you were given. A passkey is created on this device; no password is used.": "受け取った招待コードを入力してください。この端末にパスキーを作ります。パスワードは使いません。",
  "Everything bought for you in one day, including what has already been settled today.": "あなたの代わりに 1 日に買う合計です。今日すでに精算した分も含みます。",
  "Excluded": "対象外",
  "Face ID or Touch ID confirms it is you. It does not replace reading this screen.": "Face ID や Touch ID は本人確認のためのものです。この画面を読む代わりにはなりません。",
  "For %@ only": "%@ のみ",
  "Free": "無料",
  "Gift from %@": "%@ からの贈り物",
  "Goods": "商品",
  "Goods and delivery": "商品と送料",
  "Goods charged": "商品の請求額",
  "Hard to cancel": "解約しにくい",
  "Having trouble signing in?": "サインインできない場合",
  "I have an invitation": "招待コードをお持ちの方",
  "If you do not choose, this proposal closes without a purchase.": "選ばなければ、何も買わずにこのご提案は締め切られます。",
  "In the box": "箱の中身",
  "Inbox": "届いたもの",
  "Invitation code": "招待コード",
  "It was in the box": "箱に入っていた",
  "It was offered until %@.": "%@ までのお届けでした。",
  "Keep": "受け取る",
  "Kept": "手元に残したもの",
  "Left out by your agent": "提案から外したもの",
  "Limits": "見守り設定",
  "Limits %@": "見守り設定 %@",
  "Limits to sign": "署名する内容",
  "Lines you marked are not charged here. What is owed for them is between you and the shop, under its terms.": "申し出た品目はここでは請求されません。その分の扱いは、ショップの規約に沿ってあなたとショップの間で決まります。",
  "Load the limits to sign": "署名する内容を読み込む",
  "Made by %@": "メーカー・生産者: %@",
  "Marked as not right, not charged here": "申し出た分（ここでは請求なし）",
  "Move to another host": "別の保管先へ移す",
  "My records": "記録",
  "Never charged to you. If one was there, say so.": "この分を請求されることはありません。箱にあった場合はお知らせください。",
  "New limits": "新しい設定",
  "New to you": "はじめての品",
  "Next swap %@": "次の入れ替え %@",
  "No boxes at home.": "お手元に箱はありません。",
  "No daily limit": "1 日の上限なし",
  "No goods charge to you for this item.": "この品目の商品代はかかりません。",
  "No limits are recorded for this account yet.": "このアカウントの見守り設定はまだありません。",
  "No proposals here.": "ご提案はありません。",
  "No result yet": "まだ結果がありません",
  "No shops are connected to this account yet.": "このアカウントにつながっているショップはまだありません。",
  "No time to undo": "取り消せる期間なし",
  "Nobody else needs to agree to loosen these": "ゆるめるときにほかの人の同意は不要",
  "Not charged": "請求なし",
  "Not found in the box": "箱に見当たらなかったもの",
  "Not returned. You are never charged for it.": "返却されていません。この分を請求されることはありません。",
  "Nothing can be bought for you until you do.": "署名するまで、あなたの代わりに何かを買うことはありません。",
  "Nothing is bought unless you choose it and sign.": "選んで署名しない限り、何も買いません。",
  "Nothing was decided or paid. Try again.": "決定も支払いもしていません。もう一度お試しください。",
  "Nothing. You decline every item.": "ありません。すべて見送ります。",
  "Now": "現在",
  "One per line": "1 行に 1 人",
  "Opening": "開いています",
  "Outside your limits": "見守り設定の範囲外",
  "Payment status is not available here.": "支払いの状況はここでは確認できません。",
  "People who must agree to loosen these": "ゆるめるときに同意が必要な人",
  "Prepared, not signed": "準備のみ（署名していません）",
  "Preparing": "準備しています",
  "Preparing your review": "確認画面を準備しています",
  "Preparing your statement": "明細を準備しています",
  "Price shown too late": "価格の表示が遅い",
  "Prices are the shop's own. You are charged only for what you use.": "価格はショップ自身のものです。使った分だけ請求されます。",
  "Proposal": "ご提案",
  "Proposals": "ご提案",
  "Raising a limit, shortening the time to undo or removing a person needs everyone named in your current limits to sign. Nothing changes until they have.": "上限を上げる、取り消せる期間を短くする、同意が必要な人を外す、といった変更には、現在の設定にある全員の署名が必要です。全員が署名するまで何も変わりません。",
  "Refresh": "更新",
  "Refund from %@": "%@ からの返金",
  "Renews automatically": "自動で更新される",
  "Result not known yet": "結果はまだ分かりません",
  "Review": "確認へ進む",
  "Review and sign": "確認して署名",
  "Review and sign your limits": "見守り設定を確認して署名",
  "Review for my signature": "確認して署名する",
  "Review this change": "この変更を確認",
  "Save a copy of my records": "記録のコピーを保存",
  "Sent because nothing was chosen.": "選ばれなかったため届いたものです。",
  "Settled": "精算済み",
  "Settled %@": "%@ に精算",
  "Shop terms": "ショップの規約",
  "Show the settlement": "精算を見る",
  "Sign in again from the Account tab.": "「アカウント」からもう一度サインインしてください。",
  "Sign in with passkey": "パスキーでサインイン",
  "Sign out": "サインアウト",
  "Sign this decision": "この決定に署名",
  "Sign this statement": "この明細に署名",
  "Sign with passkey": "パスキーで署名",
  "Sign your limits": "見守り設定に署名する",
  "Signed": "署名済み",
  "Signed for %@.": "%@ 向けの署名です。",
  "Signing buys the items you keep, from the shops named, at the prices shown. The items you decline are declined, and nothing else is bought.": "署名すると、受け取ると決めた品目を、表示の価格で各ショップから買います。見送った品目は買わず、それ以外に買うものもありません。",
  "Signing confirms what the collection recorded, except the lines you marked, and lets %@ charge the goods amount below.": "署名すると、申し出た品目を除いて回収の記録を確認したことになり、%@ が下の商品代を請求できるようになります。",
  "Signing shows you were told which items the collection did not find. It is not you agreeing they are missing or taking responsibility for them; you are never charged for them, and you can say any of them was there.": "署名は、回収時に見当たらなかった品目を知らされたことを示すものです。紛失を認めることや責任を負うことにはなりません。この分を請求されることはなく、箱にあった場合は申し出られます。",
  "Sold by %@": "販売: %@",
  "Some shops could not be reached. This list may be incomplete.": "確認できなかったショップがあります。一覧がすべてではない可能性があります。",
  "Statement ready to confirm": "明細を確認できます",
  "Statement signed": "明細に署名しました",
  "Support may ask you for the account reference shown under Account on a device where you are signed in. It does not sign you in by itself.": "お問い合わせの際に、サインイン中の端末の「アカウント」に表示される番号を伺うことがあります。番号だけではサインインできません。",
  "Taken from the limits in effect when the change was proposed.": "変更を出した時点の設定に基づいています。",
  "Terms from %@": "%@ の規約",
  "The case against": "選ばない理由",
  "The collection found these used. You pay the shop's price, unless it was a gift.": "回収時に使用済みだったものです。贈り物を除き、ショップの価格でお支払いいただきます。",
  "The collection has recorded what was used and what went back.": "使ったものと戻したものを、回収時に記録しました。",
  "The refund from %@ did not reach you. The shop still owes it to you, off this platform.": "%@ からの返金が届きませんでした。ショップには引き続き返金する義務があり、このサービスの外で対応されます。",
  "The shop takes payment through its own checkout. This signature is your decision, not a payment.": "お支払いはショップ自身の決済で行われます。この署名はあなたの決定であって、支払いではありません。",
  "There is nothing left to sign for this box.": "この箱で署名するものはもうありません。",
  "These are the limits your agent works within. Nothing outside them can be bought for you, and loosening them needs the people you name here.": "あなたの代わりに買うときの範囲です。この範囲の外で何かを買うことはありません。ゆるめるには、ここで指定した人の同意が必要です。",
  "These goods are already with you. Use what you like; you pay only for what you use, and the rest goes back at the swap.": "すでにお手元にある商品です。気になるものを使ってください。お支払いは使った分だけで、残りは入れ替えのときに回収します。",
  "This box has settled.": "この箱は精算済みです。",
  "This decision can no longer be undone.": "この決定はもう取り消せません。",
  "This isn't right": "内容が違う",
  "This proposal is closed.": "このご提案は締め切られました。",
  "This statement has not been signed. The next box is on hold until it is.": "この明細にはまだ署名していません。署名するまで次の箱は届きません。",
  "Time to undo a decision": "決定を取り消せる期間",
  "Total": "合計",
  "Total if you sign": "署名した場合の合計",
  "Try again": "もう一度試す",
  "Undo decision": "決定の取り消し",
  "Undo this decision": "この決定を取り消す",
  "Undo with passkey": "パスキーで取り消す",
  "Undoing reopens this proposal so you can choose again before it closes. It does not cancel a payment or record a refund.": "取り消すと、締め切りまでもう一度選び直せます。支払いの取り消しや返金の記録にはなりません。",
  "Up to %@ a day": "1 日 %@ まで",
  "Up to %@ at a shop outside your network": "登録外のお店では %@ まで",
  "Up to, per day": "1 日あたりの上限",
  "Used": "使ったもの",
  "Used.": "使用済み。",
  "Uses scarcity pressure": "品切れをあおる",
  "Waiting": "待機中",
  "Waiting for your choice": "選択を待っています",
  "Waiting for your choice.": "選択を待っています。",
  "Waiting for your signature": "署名待ち",
  "Went back at the swap.": "入れ替えのときに回収しました。",
  "Who must sign": "署名が必要な人",
  "Why this, and why not": "この品目を勧める理由と、選ばない理由",
  "With you.": "お手元にあります。",
  "With you. Not collected yet.": "お手元にあります。まだ回収していません。",
  "Written and signed by each shop. Shown exactly as the shop wrote it.": "各ショップが書いて署名したものを、そのまま表示しています。",
  "You": "あなた",
  "You can undo until %@.": "%@ まで取り消せます。",
  "You can undo within the time your limits allow. Undoing reopens the proposal.": "見守り設定で決めた期間内なら取り消せます。取り消すとご提案を選び直せます。",
  "You chose to keep these.": "手元に残すと決めたものです。",
  "You decided": "決定済み",
  "You decided on this proposal.": "このご提案は決定済みです。",
  "You decline": "見送るもの",
  "You declined it before": "以前に見送った",
  "You keep": "受け取るもの",
  "You kept this.": "手元に残しました。",
  "You marked this as not right. Not charged here.": "内容が違うと申し出ました。ここでは請求されません。",
  "You said it was in the box.": "箱に入っていたと申し出ました。",
  "Your agent does not propose these, and says why.": "次の品目は提案していません。理由を添えています。",
  "Your choices are not sent until you sign.": "署名するまで、選んだ内容は送信されません。",
  "Your decision": "あなたの決定",
  "Your limits": "見守り設定",
  "Your limits are signed and in effect.": "見守り設定に署名しました。いまから有効です。",
  "Your own agent for things that arrive to be tried. You pay only for what you keep, and nothing is bought without your signature.": "試しに届くものを、あなたの代わりに見きわめる窓口です。お支払いは手元に残したものだけで、署名なしに何かを買うことはありません。",
};

/** Replaces `%@`, `%lld`/`%d`, or an indexed `%1$@`, left to right by default. */
function substitute(template: string, args: readonly (string | number)[]): string {
  let next = 0;
  return template.replace(/%(\d+\$)?(?:lld|@|d)/g, (_match, indexed: string | undefined) => {
    const i = indexed ? Number(indexed.slice(0, -1)) - 1 : next++;
    return String(args[i] ?? "");
  });
}

/**
 * The string for `key` in `lang`, with any `%@`/`%lld` filled from `args`.
 * `key` is English, and is what is shown, unfilled, when `lang` is `"en"` or
 * when a Japanese translation is missing (a key not yet in the table is a
 * hub-only sentence, not a broken lookup).
 */
export function t(lang: Lang, key: string, ...args: (string | number)[]): string {
  const template = lang === "ja" ? (JA[key] ?? key) : key;
  return args.length ? substitute(template, args) : template;
}

/** Every key this dictionary carries, for the completeness test. */
export const COPY_KEYS: readonly string[] = Object.keys(JA);
