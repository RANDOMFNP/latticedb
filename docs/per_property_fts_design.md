# Per-Property Full-Text Search

## The problem

`@@` looks like it searches a property and does not:

```cypher
WHERE d.content @@ "neural networks"
```

The index holds one document per node, so this asks whether the node's indexed
text matches. The property name is read by the planner and then discarded.
`d.title`, `d.content`, and `d.spelled_wrong` all behave identically, and a node
matches on text that has nothing to do with the property named.

It is worth being precise about what the current behaviour actually is, because it
is not "everything gets indexed". Nothing is indexed automatically. Text is handed
over explicitly:

```zig
try db.ftsIndexDocument(node_id, "whatever text you like");
```

That text need not be a property of the node, or resemble one. The index is a
mapping from node to an arbitrary document, and the Cypher syntax describes
something else entirely.

Two things follow. Somebody who stores text in a property and searches it gets
nothing back, with no indication why. And somebody who indexes one property's text
and searches by naming a different property gets matches, which looks like the
feature working.

## What it should be

The property that holds the text is the thing to index:

```cypher
CREATE FULLTEXT INDEX ON :Document(content)
```

```zig
try db.createNodeFtsIndex("Document", "content");
```

After that, writing to `content` on a `:Document` indexes it, deleting the node
removes it, and `d.content @@ "..."` searches that index and nothing else.

This is what the syntax has always promised, and it is how the engine's other
indexes already work.

## Following the property index

There is no need to invent any of this. Explicit property indexes already do the
same job for equality lookups, and the shape is worth copying rather than
paralleling:

- **A catalog.** Definitions live in `property_index_catalog_tree`, keyed by
  entity kind, scope, and property. `createNodePropertyIndex(label, property)`
  adds one and populates it from existing data.
- **Automatic maintenance.** The write path calls `index.indexNode` and
  `index.removeNode` on every create, update, and delete, so an index cannot drift
  from the data.
- **One tree, many definitions.** Entry keys are prefixed with the scope and
  property symbol ids, so a single B-tree serves every declared index without new
  slots in the file header.

Full-text search can use all three. The prefix trick matters most: `FtsIndex`
holds a dictionary, a lengths tree, and a reverse tree, and prefixing their keys
with `(label_id, property_id)` lets one set of trees carry every declared
full-text index. No new header trees, no format-wide restructuring.

## Scoring

The question that makes this a versioned change rather than a patch: when one node
has several indexed properties, is that one document or several?

**Several, one per property, with per-index corpus statistics.** Each declared
index keeps its own document count, average document length, and term
frequencies.

The alternative — one document per node, merging every indexed property — is worse
in a way that shows up immediately. BM25 normalises by document length, so a title
merged with a body is a long document, and matching a term in the title scores as
though the term were buried in a page of text. Keeping them separate means a title
is compared against other titles.

It also happens to be simpler. Within one index each node appears at most once, so
the document identifier stays the node id and nothing about the posting format
changes. Only the key prefix is new.

## Decisions worth taking deliberately

### `ftsIndexDocument` goes away

*Decided: remove it.* Text is indexed because a declared index says to, and there
is one concept rather than two.

This breaks every database currently using full-text search, and one case breaks
worse than the others. Text that was indexed but is **not stored in a property**
cannot be rebuilt, because the database never held it anywhere else. Declaring an
index populates it from property values, and there is nothing to populate from.

So the migration is: store the text in a property, then declare an index on that
property. For anyone who indexed a property's value — the common case, and the one
the syntax always implied — that is a rename away. For anyone who indexed
something derived or assembled, it means keeping the derived text somewhere the
database can see.

That is a real cost and the release notes have to lead with it rather than bury
it in an upgrade section.

`ftsSearch` becomes scoped to an index, since there is no longer a single index to
search:

```zig
const hits = try db.ftsSearch("Document", "content", "neural networks", 10);
```

### Searching a property with no index

Today this silently returns nothing, which is the trap being fixed.

*Decided: refuse it.* `d.content @@ "..."` where nothing declares an index on
`Document.content` is an error naming the missing index, not an empty result. An
empty result is indistinguishable from "nothing matched", which is exactly how the
current behaviour goes unnoticed.

This is a behaviour change for anyone whose query never worked, which is the
population it is meant to reach.

### Migrating existing indexes

Old entries are keyed without a scope prefix, so nothing written by the new code
will find them. They become inert rather than wrong, which is the safe direction:
a query returns an error about a missing index instead of quietly matching against
stale data.

They are not cleared on open. The old index may hold text that exists nowhere else
in the database, and deleting it during an upgrade would destroy the only copy.
Reclaiming that space is what `compact` is for, once the user has migrated and
knows they no longer want it.

Declaring an index populates it from the property values already stored, exactly
as `createNodePropertyIndex` does.

## Scope

In:

- `createNodeFtsIndex(label, property)` and the edge equivalent, plus `drop` and
  `has`
- Catalog entries, key prefixing, and population from existing data
- Automatic maintenance on create, update, and delete
- `@@` resolving to the declared index for the property named
- An error when no such index exists
- Cypher syntax for declaring one
- The C API and all four bindings

Out, for now:

- Indexing several properties into one searchable unit. Worth having, and a
  different feature: it needs a name for the combined index and a rule for
  scoring across fields.
- Full-text indexes on edges, unless it falls out for free.
- Changing the tokenizer, the analyzer, or anything about how terms are produced.

## Open questions

- **Does the tokenizer configuration belong per index?** Different properties want
  different treatment — a title and a body plausibly want the same analyzer, a
  product code does not. Starting with one shared configuration is smaller, and
  the catalog entry is the natural place to put a per-index one later.
- **Should declaring an index be transactional?** `createNodePropertyIndex`
  refuses while a write transaction is open. Following that is the consistent
  choice and it is worth confirming it is also the right one for an index that may
  take a while to populate.
