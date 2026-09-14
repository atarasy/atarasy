/**
 * What a refusal reads as, and where the sentence has to be right.
 *
 * **The engine's message is written for the party that built against it.** It
 * names sections, and `mandate_cooling` carried a thirteen-digit epoch: a
 * member reading `mandate_cooling: this set settles at 1757700000000` has been
 * told nothing they can act on. So every code this screen can provoke has a
 * sentence, and anything unrecognised falls through to the engine's own words
 * rather than to silence.
 *
 * **This is a module of its own because the sentences were wrong and nothing
 * could say so.** A refutation pass on 2026-09-12 measured four of them
 * directing the member to do the wrong thing, and the hub's suite could not
 * have caught any of it: the sentences lived in a browser script no test
 * reaches, and reverting them left the suite green.
 *
 * The rule for writing one: **say what happened and what the member can do**,
 * and never assert a future the engine does not perform. Nothing in this
 * system settles on a timer.
 */
export const REFUSALS: Record<string, string> = {
  /**
   * Status 0, or the proxy's 502. **It does not say nothing was sent**, which
   * it cannot know: a `POST` may have reached the engine and been applied
   * before the connection failed, and the sentence used to promise otherwise
   * on exactly the screen where the charge happens.
   */
  engine_unreachable: "Nothing answered. If you were signing, open the list again before signing a second time: this may or may not have gone through.",
  /**
   * §16.5, §6.5. **Nothing settles by itself.** The engine has no scheduler;
   * `sweep` applies expiry and nothing else, and the only settle is the route.
   * On a statement the household is the party that settles, so a cooling
   * window means it must come back and sign again. The sentence said "it
   * settles by itself once the time has passed; there is nothing more to
   * sign", which is false twice over, and the signature it just made was
   * discarded.
   */
  mandate_cooling: "You set a waiting time before anything can settle, and this is still inside it. Nothing was recorded, and nothing settles on its own: come back after the time has passed and sign again.",
  /**
   * §16.3, question 39. **It may not be a matter of waiting a day.** Where the
   * box's own total is above the ceiling it can never be signed at that
   * ceiling, and the cure is to raise it, which is a loosening. The sentence
   * said "It cannot go through today", which promises a tomorrow the register
   * records as possibly never coming.
   *
   * **And then it said the opposite of what the engine does.** Round three
   * faulted it for sending a household to people it never named, and the
   * sentence written for that said there may be no way to raise the limit.
   * Round four measured the engine: a household with no co-signers raises and
   * removes its own ceiling, signing alone, and is accepted. Clause 47 was
   * amended on 2026-09-13 to say so. **Both earlier sentences were wrong in
   * the same direction**, telling a member a door was shut that was open.
   */
  mandate_ceiling_daily: "This is more than the daily limit you set for yourself, counting what has already settled today. It cannot settle while that limit stands. If you named nobody to hold your limits with you, you can raise it yourself on the protections screen; if you named somebody, raising it needs them.",
  /**
   * **Not here, and the gap is named rather than papered over.** The hub
   * carried `mandate_ceiling`, which neither the engine nor the
   * specification uses: the engine throws `over_ceiling` and §16.6 names
   * it `mandate_ceiling_out_of_network`, so one refusal had three names
   * and the hub's was nobody's. It is also unreachable from any screen,
   * because the ceiling refuses at presentation, which is the presenter's
   * call. A sentence for a code that cannot arrive is dead text a test
   * then asserts. The engine and the specification disagreeing is the
   * engine's to fix and is queued with the rest.
   */
  statement_unsigned: "This box cannot settle until you sign what came back with it.",
  /**
   * §6.5. It is also what a household sees when its own signature went
   * through and the answer was lost, so the sentence no longer claims that
   * nothing was recorded: something was, by somebody, and this screen cannot
   * say what.
   */
  already_settled: "This box has already settled, so what you just marked was not recorded. If you signed it a moment ago, that signature is what settled it.",
  already_decided: "One of these lines has already been decided, so this screen is out of date. Go back and open it again.",
  bad_signature: "The signature did not match what was on the screen. Nothing was recorded.",
  delivery_missing: "No delivery has been recorded for this box, so what carriage costs is not known and it cannot settle yet.",
  not_disputable: "Only a line the collection found used can be disputed. A line you kept is one you signed for yourself.",
  /**
   * §16.5, question 43, decided 2026-09-13. A box the route resolved
   * carries no signed set, so there is nothing to withdraw. **This sentence
   * is ahead of the engine**, which does not send the code yet: the screen
   * stopped offering the button on 2026-09-12 and the engine change is
   * queued behind a mutation sweep. It is here so the two land together.
   */
  not_withdrawable: "This can no longer be taken back: the box was resolved or collected by the route, or it is past its expiry, so what stands is settled as it is. If a line on its statement is wrong, dispute it there.",
  /**
   * Thrown by `settle`, by `decide` on an offer that closed while the screen
   * was open, and by a take-back on an offer that moved on. The sentence said
   * "This box is not in a state that can settle", which names the wrong event
   * on two of the three paths and calls a digital offer a box.
   */
  bad_state: "This is no longer in the state this screen was drawn for. It may have closed, or settled, while the screen was open. Go back and open the list again.",
  config_missing: "The catalogue this offer was priced against is no longer available, so it cannot settle. Nothing was charged.",
  no_cooling: "You have set no cooling window, so a decision is final as soon as it is signed.",
  cooling_over: "The window has closed and the decision is final.",
  confirmation_reused: "This confirmation has been used already. Go back and open the offer again.",
};

/** The sentence for a refusal, or the engine's own words where none is written. */
export function refusal(body: { error?: string; message?: string }, status: number): string {
  if (status === 0) return REFUSALS.engine_unreachable!;
  const known = body.error ? REFUSALS[body.error] : undefined;
  return known ?? body.message ?? `this answered ${status}`;
}
