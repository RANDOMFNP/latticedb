# The `lattice` Command

Installing LatticeDB gives you a `lattice` command. It is the fastest way to create a
database, poke around in one, and move data in and out — no code required.

Every command follows the same shape:

```bash
lattice <command> [options] <path>
```

The path is the database file. Almost every command needs one; `version`, `help`, and
`update` are the exceptions.

If you ever forget what something does, ask it:

```bash
lattice help            # everything at a glance
lattice export --help   # detail for one command
```

## A quick tour

Here is the whole thing in five commands. Create a database, put something in it, and
look at what you have.

```bash
lattice create social.lattice
lattice exec social.lattice --query="CREATE (a:Person {name: 'Alice', age: 30})"
lattice exec social.lattice --query="CREATE (b:Person {name: 'Bob', age: 41})"
lattice exec social.lattice --query="MATCH (a:Person {name:'Alice'}), (b:Person {name:'Bob'}) CREATE (a)-[:KNOWS {since: 2020}]->(b)"
lattice count social.lattice
```

That last command prints:

```text
┌───────────┬────────────┐
│ Type      │ Count      │
├───────────┼────────────┤
│ Nodes     │          2 │
│ Edges     │          1 │
│ Labels    │          1 │
│ EdgeTypes │          1 │
└───────────┴────────────┘
```

## Creating a database

`create` makes a new database file. On its own it gives you a graph with full-text
search turned on:

```bash
lattice create social.lattice
```

```text
Created database: social.lattice
  Full-text search enabled
```

If you plan to store embeddings, turn the vector index on at creation time and say how
many dimensions your vectors have. This has to be decided up front, because the index
is built into the file:

```bash
lattice create embeddings.lattice --enable-vector --vector-dims=1536
```

| Option | What it does |
|--------|--------------|
| `--enable-vector` | Turn on the vector index for similarity search |
| `--vector-dims=<n>` | How many numbers are in each vector, 1 to 4096 (default 128) |
| `--enable-fts` | Turn on full-text search — already the default |
| `--no-fts` | Leave full-text search out |
| `--cache-size=<mb>` | How much memory to keep pages in, in MB (default 64) |
| `--page-size=<bytes>` | Page size, 4096 to 65535 (default 4096) |

Pick `--vector-dims` to match whatever produces your embeddings. OpenAI's
`text-embedding-3-small` gives you 1536 numbers per vector, so that is the number you
would use.

## Running queries

There are two ways to run Cypher. Use `exec` for one query, and `query` when you want
to sit and explore.

### One query at a time

```bash
lattice exec social.lattice --query="MATCH (p:Person) RETURN p.name, p.age"
```

You can keep a longer query in a file instead of fighting with shell quoting:

```bash
lattice exec social.lattice --file=report.cypher
```

### An interactive shell

```bash
lattice query social.lattice
```

This drops you into a prompt where you can type queries and see results immediately.
It also understands a few commands of its own, all starting with a dot:

| Command | What it does |
|---------|--------------|
| `.help` | List these commands |
| `.labels` | List every node label |
| `.types` | List every edge type |
| `.schema` | Show what the data looks like |
| `.format table\|json\|csv` | Change how results are printed |
| `.timing on\|off` | Show how long each query took |
| `.exit` or `.quit` | Leave |

## Looking at what is in there

Four commands answer "what is actually in this database?".

`count` gives you the totals, as shown in the tour above.

`labels` and `types` list the node labels and edge types, with how many of each:

```bash
lattice labels social.lattice
```

```text
┌────────┬────────────┐
│ Label  │ Count      │
├────────┼────────────┤
│ Person │          2 │
└────────┴────────────┘
1 label(s)
```

`schema` puts both together. LatticeDB does not make you declare a schema up front, so
this is worked out by looking at the data that is actually there:

```bash
lattice schema social.lattice
```

```text
Schema
══════

Node Labels:
  (:Person) - 2 node(s)

Edge Types:
  [:KNOWS] - 1 edge(s)

Total: 1 label(s), 1 edge type(s)
```

`info` describes the file rather than its contents — size, counts, and which features
it was built with:

```bash
lattice info social.lattice
```

```text
Database: social.lattice
─────────────────────────────
Size:         68 KB
Nodes:        2
Edges:        1
Format:       v3
FTS:          enabled
```

## Moving data in and out

### Importing

`import` reads JSON or CSV:

```bash
lattice import social.lattice --file=people.json
```

```text
Importing people.json into social.lattice...
Import complete
  Nodes imported: 2
  Edges imported: 1
```

JSON should have a `nodes` array and an `edges` array:

```json
{
  "nodes": [
    {"id": "n1", "labels": ["Person"], "properties": {"name": "Carol", "age": 29}},
    {"id": "n2", "labels": ["Person"], "properties": {"name": "Dan", "age": 35}}
  ],
  "edges": [
    {"source": "n1", "target": "n2", "type": "KNOWS", "properties": {"since": 2021}}
  ]
}
```

CSV needs two files, one for nodes and one for edges. Columns starting with an
underscore have special meaning; everything else becomes a property:

```text
_id,_labels,name,age
n1,"Person;Employee",Alice,30
```

```text
_source,_target,_type,since
n1,n2,KNOWS,2020
```

Two options are worth knowing about for large imports:

| Option | What it does |
|--------|--------------|
| `--batch-size=<n>` | Commit every N items instead of all at once (default 1000) |
| `--on-error=skip` | Skip records that fail instead of giving up on the whole import |

`--on-error=skip` applies records one at a time, so the good rows still land. That is
slower, but it means one bad row in a large file does not cost you the import.

### Exporting

`export` writes JSON, JSONL, CSV, or DOT. It picks the format from the file extension:

```bash
lattice export social.lattice --file=backup.json
lattice export social.lattice --file=graph.jsonl
lattice export social.lattice --file=people.csv --labels=Person
lattice export social.lattice --file=graph.dot
```

DOT is the format Graphviz reads, so you can turn a small graph into a picture:

```text
digraph G {
  n1 [label="1 : Person"];
  n2 [label="2 : Person"];
  n1 -> n2 [label="KNOWS"];
}
```

You can narrow what gets exported with `--labels=Person,Company`, or export the result
of a query instead of the whole graph with `--query="..."`.

### Dumping

`dump` writes the whole database to standard output as JSON, in a stable order:

```bash
lattice dump social.lattice > snapshot.json
```

Because the ordering is fixed, two dumps of the same data produce identical files. That
makes `dump` useful in tests and for spotting what changed between two databases with a
plain `diff`.

## Looking after a database

### Checking for damage

`check` opens the file read-only and verifies the checksum stored on every page:

```bash
lattice check social.lattice
```

```text
Database file checks passed
  Pages checked: 16
  Note: sibling WAL file exists but was not validated
```

One thing to be aware of: this checks the main database file only. If a write-ahead log
file is sitting next to it, `check` will tell you it exists but will not look inside it.
The write-ahead log is the file LatticeDB appends changes to before applying them, so
that a crash cannot leave the database half-written.

### Reclaiming space

Deleting a lot of data leaves free pages behind, and the file stays the same size
because those pages are kept for reuse. `compact` hands the unused ones at the end of
the file back to the operating system:

```bash
lattice compact social.lattice
```

```text
Compacted database: social.lattice
  Pages before:    17
  Pages after:     17
  Pages removed:   0
  Bytes reclaimed: 0
```

Nothing was reclaimed here because nothing had been deleted. A few things are worth
knowing before you run it on real data:

- It only truncates free pages at the *end* of the file. Free pages in the middle stay
  where they are and get reused normally, so a file with holes in the middle will not
  shrink much.
- Live pages are never moved, which is what makes it safe to interrupt.
- It will refuse to run on a read-only database, or while any transaction is open.

### Updating

`update` replaces your installed copy with the latest release:

```bash
lattice update
```

## Output formats

Most commands can print in a different format, which is what you want when something
else is going to read the output:

```bash
lattice count social.lattice --format=json
lattice count social.lattice --format=csv
```

```text
type,count
nodes,2
edges,1
labels,1
edge_types,1
```

`table` is the default and is meant for reading. `json` and `csv` are meant for piping
somewhere else:

```bash
lattice exec social.lattice --query="MATCH (p:Person) RETURN p.name" --format=json | jq
```

## Every command at a glance

| Command | What it does |
|---------|--------------|
| `create <path>` | Make a new database |
| `info <path>` | Show file size, counts, and enabled features |
| `compact <path>` | Give free pages at the end of the file back to the OS |
| `check <path>` | Verify page checksums in the main file |
| `query <path>` | Open an interactive Cypher shell |
| `exec <path>` | Run one query and exit |
| `import <path>` | Load data from JSON or CSV |
| `export <path>` | Write data to JSON, JSONL, CSV, or DOT |
| `dump <path>` | Print the whole database as canonical JSON |
| `labels <path>` | List node labels and their counts |
| `types <path>` | List edge types and their counts |
| `schema <path>` | Show the shape of the data |
| `count <path>` | Show node and edge totals |
| `update` | Update your LatticeDB installation |
| `version` | Print the version and file format version |
| `help` | Show usage |

## Where to go next

- [Quick Start](./quickstart.md) for the same ideas from Python or TypeScript
- [Core Concepts](./concepts.md) for what nodes, edges, and properties actually are
- [Cypher Overview](../cypher/overview.md) for the query language itself
