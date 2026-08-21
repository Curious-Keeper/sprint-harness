# Map guide — the writing standard

The map is the only artifact the harness cannot generate for you. Its quality sets
the ceiling on everything downstream: a vague item produces a vague dispatch, and
a builder handed a vague dispatch invents an answer and reports success.

This is the standard the source project arrived at after two rebuilds. The
examples are lightly anonymised from a real map that drove nine batches.

---

## The one rule

> **Record CONSEQUENCES, not structure.**

An agent can read your directory listing, your route table and your schema. It
cannot read the trigger that will turn a live Save button into a raw database
exception, or the fact that a column that still appears in half the codebase was
dropped four months ago.

Structure is free. Consequences are the map's entire value.

Every time you are about to write "the `orders` table has 14 columns", stop. Write
what will bite instead.

---

## `openDebt` — the four-field entry

This is the section the queue is built from. Every entry:

```json
{
  "id": "S#2",
  "summary": "Every pdf_url column stores an expiring signed URL, not the storage key.",
  "evidence": "_shared/storage.ts:28-37 — uploadPdf returns createSignedUrl(path, ttl) and that string is what gets persisted (generate-estimate/index.ts:153-157; same for PO, BOL and tracking). The key itself is stored nowhere.",
  "mechanism": "The web app survives only because lib/documents.ts:8-16 regex-scrapes the key back out of the URL and re-serves it. The column's real contract is therefore 'a key, wrapped in a URL, extractable by a regex in the web tier'. Any other consumer — an alert payload, an export, a person reading the row — gets a link that 404s at TTL. If the storage provider's signed-path shape changes, the scraper falls through to its bare-path branch and yields a WRONG key for every historical row.",
  "fix": "Store the path, sign on read. Backfill by running the same regex once, in SQL, where its result can be inspected."
}
```

### `summary` — one line, becomes the queue item title

Declarative, specific, no hedging. It has to survive being read alone in a
partition printout.

- ❌ "Issues with document URLs"
- ✅ "Every pdf_url column stores an expiring signed URL, not the storage key."

### `evidence` — `file:line` citations, not descriptions

**This field is load-bearing for the machinery, not just for humans.** Two things
consume it:

1. The extractor scrapes file paths out of it to build the **collision graph**. No
   citation → `scope: "unscoped"` → refused at dispatch.
2. The builder **verifies the citation still says what it claims** before changing
   anything, and reports `staleEvidence` when it doesn't. That turns map rot into
   a tracked finding instead of silent drift.

- ❌ "The storage helper returns a signed URL which gets saved to the database."
- ✅ "`_shared/storage.ts:28-37` — `uploadPdf` returns `createSignedUrl(path, ttl)` and that string is what gets persisted (`generate-estimate/index.ts:153-157`)."

> ⚠ **Name only the files you intend to EDIT.** Any path mentioned in an item's
> prose — even in passing, even as a cross-reference — lands in that item's file
> set and can manufacture a false collision, serialising work that could have run
> in parallel. Describe comparisons and cross-references *without* paths.

#### Cite where a thing is BUILT, not only where it is declared

A file list derived from where a field is **declared** misses where it is
**constructed**, and the two fail in opposite ways.

This burned twice in one morning on a live project, in lists written that
morning. An item added a required field to an API model and cited the schema
module. The model is assembled field by field by a function in a different file,
so the field was literally unconstructable inside the declared list. The builder
correctly CUT THE FEATURE rather than touch a file it was not given — and the
reduce reported the node as `not-built`, which reads like a failure and is not
one.

**The check, cheap enough to do every time:** for any item that adds a field to a
model, or a case to a rule, grep for where that thing is CONSTRUCTED, and cite
that file too. A reflective constructor silently omits the field; a hand-written
one will not compile. Neither is visible from the file where it is declared.

#### A companion file does not need a citation

Some files move together by construction and the extractor grants them
automatically: a `pairedArtifacts` counterpart (change a component, get its test
in the file list), plus anything in the extractor's `COMPANIONS` table — a
manifest and its lockfile, a module and the feature-grouped test that covers it.

You do not cite those, and you should not: citing a test file that does not exist
yet just produces an unresolved-citation warning. Write about the code.

### `mechanism` — the causal chain

The field that separates a map from a linter. **Why does this actually break, and
what is surprising about it?** If the mechanism is obvious from the summary, the
item is probably a lint rule and not map material.

Good mechanisms usually contain a *because* that you had to discover:

> "…which survives because the migration only nulled `contact_id` on rows it
> re-pointed — a contact who joins a company LATER keeps their own row, and the
> unique constraint permits it."

That clause is why the bug is still live after an apparent fix. No agent derives
that from the schema.

### `fix` — the shape, never the diff

Give the direction and the constraint. Leave the implementation to the builder;
if you have already written the diff, you did not need the harness.

- ✅ "Either a `check (num_nonnulls(...) = 4)` constraint, or make both views pick
  a ROW and take all five columns from it. **An address is a unit.**"

That last sentence is the actual content — it is the invariant the fix must
preserve, stated so a builder choosing between two approaches cannot pick a wrong
one.

---

## `evolutionTraps` — highest value per line

Things that **used to be true**. Older code, older comments and older docs still
imply they exist, so an agent pattern-matching on them writes code referencing
nothing.

Format: *what does not exist* → *when it went* → *what to use instead*.

```
"orders.freight_charge DOES NOT EXIST — dropped in 0074. Buyer-billed freight is
 an FC LINE ITEM. Any code or doc referencing the column is pre-0074."

"contact_billing DOES NOT EXIST — renamed billing_addresses in 0067 and re-keyed
 from contact to COMPANY."

"There is NO categories table. The taxonomy is material_category_colors."
```

**ALL-CAPS the negation.** These are read fast, and the whole point is that the
reader currently believes the opposite.

**Mine these mechanically** — this is the biggest single shortcut available:

```bash
git log -p --diff-filter=M -- migrations/ | grep -iE '^\+.*(DROP|RENAME)'
git log --diff-filter=D --name-only --format='%h %ad %s' --date=short
```

Every dropped column, renamed table and deleted module is a trap the moment
anything still references it.

---

## `invariants` — the bar is "it already caused a bug here"

Feeds `{{REPO_INVARIANTS}}` in both agent contracts. **A list padded with
plausible-sounding rules trains every agent to skim the section**, which costs you
the entries that matter. Ten real ones beat forty aspirational ones.

Each is *rule → concrete failure mode*:

```
"P&E gate: a shipment cannot be inserted until the estimate is signed and the PO
 issued (enforce_pe_gate, 0004:29). Still BEFORE INSERT only — see L#16."

"Signed-order field lock: <fields> are frozen unless an amendment is open
 (enforce_signed_order_lock). Revised 0046 -> 0074 -> 0075 -> 0080.
 DELIBERATELY OUTSIDE the lock: buyer_contact_id, supplier_contact_id,
 market_segment, sales_rep — locking them would block the repair path for an
 order created against the wrong party (0080:20-28)."
```

Three things that entry does, all worth copying:

1. **Names the enforcing mechanism** (`enforce_signed_order_lock`) so a verifier
   can grep for it.
2. **Records the revision history** so nobody "restores" an older version.
3. **States what is deliberately EXCLUDED, and why.** Without that note the next
   agent helpfully "fixes" the omission and breaks the repair path.

Pair the list with a **maintenance rule** — what a future change must do to keep
the invariant true:

> "When you add a column that PRINTS on a signed document, add it to the lock in a
> new migration **AND** gate it in the UI in the same change. Without the UI gate
> the trigger turns a live Save button into a raw Postgres exception in the user's
> face."

---

## `coverageGaps` — write down what nobody looked at

Feels like admitting failure. It is the section that stops a future audit from
concluding "clean" about a surface it never opened.

```
"NO SECURITY AUDIT HAS EVER COVERED THE UI. The audit had five lanes (deploy,
 migrations, edge functions, web data layer, documents) and none touched
 components/. Never audited by any lane: <explicit list>."

"The blind audit was NOT truly blind — persistent project memory loads every
 session and named one finding, which is why it was flagged contaminated. It also
 enumerated only through migration 0055 and missed 0056. Any future blind run must
 disable project memory AND enumerate the full list."
```

Note the second entry records a **methodology defect**, not a code defect. Those
are worth more than most findings, because they tell you which of your conclusions
to distrust.

---

## `acceptedRisks` — known, deliberately unfixed, with a name attached

Without this section every audit re-discovers the same items forever.

```
"Webhook auth is a static shared secret, timing-safe compared. The upstream
 platform CANNOT sign requests (no HMAC, no timestamp), so this plus path-scoping
 is the platform ceiling. Handlers are idempotent and replay-guarded."
```

The value is *"this is a ceiling, not a choice"*. State the constraint that makes
it unfixable, or it reads as laziness and gets re-raised.

---

## `shipped` — closed work MOVES here

Do **not** leave closed items in the queue with `status: done`. An item that is
both queued and closed is exactly the ambiguity this removes — and the extractor
never reads `shipped`, so it cannot be re-dispatched.

> ⚠ **CLOSING AN ITEM IS TWO EDITS, and the second one is the one that gets
> skipped.** Add the `shipped` entry AND remove the item from the open section.
> Three items on a live project had complete `shipped` records and were still
> sitting in `openDebt`, so the extractor put all three back in the queue as
> `open`. The next batch would have dispatched builders at work already on main
> — and the likely outcome is not a wasted node but a CONFUSING one: an agent
> given an item whose fix is already present reports it done without changing
> anything, which is indistinguishable from a node that silently did nothing.
> Do the move in one edit, at the end of the batch, before the context is gone.

**A refusal is also a closure, and it belongs in the map as a FIELD.** If you
decide before dispatch that an item cannot be built yet, do not leave that
decision in a batch note for a human to re-read — the extractor cannot see prose,
and it will re-offer the item next batch. Give it `scope: "held"` with a note
saying who held it and what releases it (the extractor refuses a `held` item with
no note). Putting the hold in the extractor's `OVERRIDES` table works and is a
stopgap: that is a code file, and a refusal decided by evidence belongs beside
the evidence.

Keep the original four fields and add how it closed:

```json
{
  "id": "§3.4-types",
  "summary": "Supabase types are not generated, so the entire data layer is untyped.",
  "closedIn": "batch-0",
  "closedOn": "2026-08-10",
  "fromSeverity": "high",
  "how": "scripts/gen-types.sh emits database.types.ts and all four clients take the <Database> generic. Wiring it caught a live bug: calc_date was sending an explicit null into a NOT NULL column. STILL OPEN on the MCP side."
}
```

`how` is where you record what the fix *taught* you — including anything it left
open. That last sentence is a future item.

---

## Sections split by DISPATCHABILITY, not by topic

The single most important structural decision. Three lanes, and only the first can
be handed to a builder:

| section | what | dispatchable |
|---|---|---|
| `openDebt` | code work with `file:line` evidence | **yes** |
| `plannedWork` | wanted, not yet scoped | no — scope it first |
| `decisionsOwed` | needs a human to decide something | **never** |
| `externalState` | truth lives outside the repo | **never** |

`decisionsOwed` and `externalState` are the ones that bite. An agent asked to
"check" a DNS record, a SaaS console or a client's machine will report on what it
can see locally and present that as the answer. Keeping them *in* the map makes
them visible; keeping them *out* of the dispatchable lanes stops them reaching a
builder.

---

## Stamping and regeneration

The source project's map was regenerated twice; the first version was "actively
wrong in ten places" within six weeks. Three disciplines:

1. **Stamp what was verified and when** — `"REGENERATED <date> against HEAD
   <sha>"`, plus the counts it was verified against.
2. **A reconciliation pass must NOT restamp the verification date.** If a pass
   only updated what it could *prove* had changed, mark those entries `amended`
   and leave the older stamps alone. A map claiming freshness it does not have is
   worse than one that is honestly stale.
3. **Debt confirmed fixed is DELETED, not marked historical** (it moves to
   `shipped`). `openDebt` is then the complete open list and nothing else in the
   file records debt — so there is exactly one place to look.

---

## Quality checklist

Before you call the map done:

- [ ] Every `openDebt` entry has at least one `file:line` citation.
- [ ] No entry's `evidence` names a file it does not intend to edit.
- [ ] Every `mechanism` contains something you had to *discover*.
- [ ] Every invariant names a bug that actually happened here.
- [ ] Every invariant with deliberate exclusions says what they are and why.
- [ ] `evolutionTraps` has an entry for every dropped column / renamed table.
- [ ] `coverageGaps` names at least one surface nobody audited.
- [ ] Closed work is in `shipped`, not in `openDebt` with a done flag.
- [ ] The map is **committed** — worktrees materialize only tracked files.
- [ ] You can point at three entries no agent could derive from the code.
