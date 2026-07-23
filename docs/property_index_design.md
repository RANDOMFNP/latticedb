# Property Lookup and Index Design

LatticeDB provides explicit, durable equality indexes for scoped node and edge
properties. Indexes are schema objects: callers opt into their storage and write
cost, and indexed lookup APIs fail instead of silently falling back to a scan.

## Goals

- Keep hot-path lookup APIs honest about whether they are index-backed.
- Keep explicit property indexes as the prerequisite for APIs that imply indexed lookup.
- Support common graph access patterns such as `(:Person {email: ...})` without
  forcing callers through Cypher when they want direct API access.

## Explicit Property Indexes

Creating an index names the entity kind, label or edge type, and property key:

```c
lattice_node_property_index_create(db, "Person", "email");
lattice_edge_property_index_create(db, "OWNS", "serial_number");
```

Python exposes `create_node_property_index()` and
`create_edge_property_index()` on `Database`; TypeScript uses the equivalent
camel-case methods. Matching drop methods remove the schema definition and its
entries.

The storage layer maintains a durable definition catalog plus separate node and
edge B+Trees. Entry keys encode the scoped label/type ID, property key ID, a
SHA-256 digest of the complete typed property value, and the entity ID. Fixed
keys allow large strings, bytes, vectors, lists, and maps to be indexed without
inheriting B+Tree key-size limits. Lookups re-read and compare source properties,
so a digest collision cannot produce an incorrect result.

## Indexed Equality Lookup APIs

Direct lookup APIs make the index requirement clear:

```c
lattice_nodes_find_by_label_property(
    txn,
    "Person",
    "email",
    &email_value,
    limit,
    &node_ids,
    &count
);
```

`lattice_edges_find_by_type_property()` provides the edge equivalent. Python
transaction methods are `find_nodes_by_label_property()` and
`find_edges_by_type_property()`; TypeScript uses camel-case names. Each accepts
a positive result limit.

The lookup fails with `LATTICE_ERROR_UNSUPPORTED` (or the binding's corresponding
exception) when the required index does not exist. It never silently scans.
Creating an index scans existing matching records, and subsequent direct and
transactional mutations maintain it. Transactional lookups include staged
changes and preserve reader snapshot visibility.

## Scan-Backed Convenience APIs

Any future scan-backed convenience lookup must remain explicitly named as a
scan:

```c
lattice_nodes_scan_by_label_property(...);
lattice_edges_scan_by_type_property(...);
```

Scan APIs may be useful for migrations, admin tools, tests, and small local
datasets, but their names must keep the cost visible.
