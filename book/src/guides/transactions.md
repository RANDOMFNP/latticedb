# Transactions and Durability

LatticeDB provides ACID transactions with snapshot isolation.

## Transaction Model

- **Read transactions** see a consistent snapshot of the database. As many as you like can run at once.
- **Write transactions** change the database. Only one can be open at a time — see [One writer at a time](#one-writer-at-a-time) below, because this one has a sharp edge.
- **Snapshot isolation** — each transaction sees the database as it was the moment it began. Changes made by other transactions that have not committed yet are invisible to it.

## Using Transactions

### Python

```python
# Read transaction
with db.read() as txn:
    node = txn.get_node(node_id)
    edges = txn.get_outgoing_edges(node_id)
    # Transaction automatically completes when context exits

# Write transaction
with db.write() as txn:
    node = txn.create_node(labels=["Person"], properties={"name": "Alice"})
    txn.commit()
    # If commit() is not called, the transaction is rolled back
```

### TypeScript

```typescript
// Read transaction
await db.read(async (txn) => {
  const node = await txn.getNode(nodeId);
  const edges = await txn.getOutgoingEdges(nodeId);
});

// Write transaction
await db.write(async (txn) => {
  const node = await txn.createNode({
    labels: ["Person"],
    properties: { name: "Alice" },
  });
  // Transaction auto-commits on success, rolls back on error
});
```

### C

```c
// Begin a read transaction
lattice_txn* txn;
lattice_begin(db, LATTICE_TXN_READ_ONLY, &txn);
// ... read operations ...
lattice_commit(txn);

// Begin a write transaction
lattice_begin(db, LATTICE_TXN_READ_WRITE, &txn);
// ... write operations ...
lattice_commit(txn);  // or lattice_rollback(txn);
```

## Queries and Transactions

`db.query()` automatically creates the appropriate transaction:

- Read queries (`MATCH ... RETURN`) use a read transaction
- Write queries (`CREATE`, `SET`, `DELETE`) use a write transaction

```python
# Implicit read transaction
results = db.query("MATCH (n:Person) RETURN n.name")

# Implicit write transaction
db.query("CREATE (n:Person {name: 'Alice'})")
```

## Durability

LatticeDB uses a write-ahead log (WAL) for crash recovery:

1. Changes are written to the WAL before being applied to data pages
2. Commit means the WAL record is on disk (a fast sequential write)
3. Data pages are written lazily during checkpointing
4. On crash, the WAL is replayed to recover committed transactions

This means committed data survives process crashes and power failures.

## Concurrency

- Readers never block writers
- Writers never block readers
- As many readers as you like can run at the same time
- Only one write transaction can be open at a time

This makes LatticeDB a good fit for read-heavy work, which is what most RAG and search
applications look like.

## One writer at a time

A database handle allows exactly one open write transaction. If you try to begin a
second one while the first is still open, you do not wait in a queue — the call fails
immediately.

This changed in 0.10.0. Before that, overlapping writers were resolved later, at commit
time. Now the second one is refused up front, which turns a subtle race into an obvious
error you can see and handle.

Read transactions are unaffected. You can open as many as you want, and they can happily
run alongside the writer.

### What the error looks like

| Language | What you get |
|----------|--------------|
| C | `LATTICE_ERROR_LOCK_TIMEOUT` (`-8`) returned from `lattice_begin` |
| Python | `LatticeLockTimeoutError` raised |
| TypeScript | `LatticeError` thrown, with `.code === LatticeErrorCode.LockTimeout` |
| Go | `ErrorLockTimeout` on the returned error's `Code` |

The name says "lock timeout", which is a slightly misleading inheritance from the error
code it shares. Nothing is timing out. It means: somebody else is already writing.

### Writing code that respects it

The fix is almost always to finish one write before starting the next, rather than to
retry. If two parts of your program both want to write, give them the same handle and
let them take turns:

```python
# This fails: the second write() begins while the first is still open
with db.write() as txn_a:
    txn_a.create_node(labels=["Person"], properties={"name": "Alice"})
    with db.write() as txn_b:          # raises LatticeLockTimeoutError
        txn_b.create_node(labels=["Person"], properties={"name": "Bob"})
    txn_a.commit()
```

```python
# This works: one transaction at a time
with db.write() as txn:
    txn.create_node(labels=["Person"], properties={"name": "Alice"})
    txn.create_node(labels=["Person"], properties={"name": "Bob"})
    txn.commit()
```

Batching writes into one transaction like this is also faster, because the durability
work that makes a commit safe happens once instead of twice.

If your program writes from several threads or tasks, put the writes behind something
that serialises them — a lock, a queue, a single writer task — rather than catching the
error and retrying in a loop. Retrying works, but it burns effort re-attempting
something you already know will fail until the other writer finishes.

### Running a query picks its own mode

You do not have to decide this yourself for ordinary queries. `db.query()` looks
at what the query does and opens the transaction it needs: a read-only one for
`MATCH` and friends, a read-write one for `CREATE`, `SET`, `DELETE`, `MERGE`,
and `REMOVE`.

That means a read never takes the writer slot, so reads keep running alongside
an open write transaction, while a write through `query()` still has to wait its
turn like any other writer.

```python
db.query("MATCH (p:Person) RETURN p.name")   # read-only, runs alongside a writer
db.query("CREATE (p:Person {name: 'Ada'})")  # needs the writer slot
```

Explicit transactions are still there when you want several statements to
succeed or fail together, which a single `query()` call cannot express.

### Schema changes count as writes

Creating or dropping a property index is also refused while a write transaction is
open, with the same error. Do schema work when no transaction is in flight:

```python
db.create_node_property_index("Person", "email")   # no open write transaction
```

Physical compaction is stricter still: `lattice compact` refuses to run while *any*
transaction is open, read or write.
