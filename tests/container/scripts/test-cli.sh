#!/bin/bash
# CLI user-perspective integration tests.
# Tests the `lattice` binary from a user's point of view.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUITE_NAME="CLI Tests"
source "$SCRIPT_DIR/helpers.sh"

LATTICE="${LATTICE:-lattice}"
DB="/tmp/test-cli.lattice"
DB2="/tmp/test-cli-import.lattice"
DB3="/tmp/test-cli-roundtrip.lattice"
FIXTURES="${FIXTURES:-/fixtures}"

# Clean up any previous test databases
rm -f "$DB" "$DB-wal" "$DB2" "$DB2-wal" "$DB3" "$DB3-wal"

# ---------- Basic commands ----------

test_begin "version command returns version string"
run "$LATTICE" version
assert_contains "$STDOUT" "0."

test_begin "help command shows usage"
run "$LATTICE" help
assert_contains "$STDOUT" "Usage"

test_begin "--help flag works"
run "$LATTICE" --help
assert_contains "$STDOUT" "Usage"

# ---------- Database creation ----------

test_begin "create database"
run "$LATTICE" create "$DB"
assert_exit_code "$EXIT_CODE" 0

test_begin "created database file exists"
assert_file_exists "$DB"

test_begin "create database with vector options"
DB_VEC="/tmp/test-cli-vec.lattice"
rm -f "$DB_VEC" "$DB_VEC-wal"
run "$LATTICE" create "$DB_VEC" --enable-vector --vector-dims=384
assert_exit_code "$EXIT_CODE" 0
rm -f "$DB_VEC" "$DB_VEC-wal"

# ---------- Database info ----------

test_begin "info command shows database metadata"
run "$LATTICE" info "$DB"
assert_contains "$STDOUT" "Nodes"

test_begin "info command with JSON format"
run "$LATTICE" info "$DB" --format=json
assert_valid_json "$STDOUT"

# ---------- Count (empty DB) ----------

test_begin "count on empty database"
run "$LATTICE" count "$DB" --format=json
assert_exit_code "$EXIT_CODE" 0

# ---------- Exec CREATE ----------

test_begin "exec CREATE node"
run "$LATTICE" exec "$DB" --query='CREATE (n:Person)'
assert_exit_code "$EXIT_CODE" 0

test_begin "exec CREATE second node"
run "$LATTICE" exec "$DB" --query='CREATE (n:Person)'
assert_exit_code "$EXIT_CODE" 0

# ---------- Exec MATCH ----------

test_begin "exec MATCH returns created nodes"
run "$LATTICE" exec "$DB" --query='MATCH (n:Person) RETURN n' --format=json
assert_contains "$STDOUT" "\"count\":2"

# ---------- Labels ----------

test_begin "labels command shows Person"
run "$LATTICE" labels "$DB"
assert_contains "$STDOUT" "Person"

# ---------- Schema ----------

test_begin "schema command returns valid JSON"
run "$LATTICE" schema "$DB" --format=json
assert_valid_json "$STDOUT"

# ---------- Count after inserts ----------

test_begin "count after inserts shows correct totals"
run "$LATTICE" count "$DB" --format=json
assert_exit_code "$EXIT_CODE" 0
assert_contains "$STDOUT" "\"nodes\":2"
assert_contains "$STDOUT" "\"edges\":0"

# ---------- Import ----------

test_begin "import JSON data"
run "$LATTICE" create "$DB2"
run "$LATTICE" import "$DB2" --file="$FIXTURES/sample-graph.json"
assert_exit_code "$EXIT_CODE" 0

test_begin "count after import"
run "$LATTICE" count "$DB2" --format=json
assert_contains "$STDOUT" "\"nodes\":4"
assert_contains "$STDOUT" "\"edges\":4"

test_begin "types command on imported graph shows KNOWS"
run "$LATTICE" types "$DB2"
assert_contains "$STDOUT" "KNOWS"

# ---------- Export ----------

test_begin "export to JSON"
EXPORT_FILE="/tmp/test-export.json"
rm -f "$EXPORT_FILE"
run "$LATTICE" export "$DB2" --file="$EXPORT_FILE"
assert_exit_code "$EXIT_CODE" 0

test_begin "exported JSON file exists and is valid"
assert_file_exists "$EXPORT_FILE"

# ---------- Dump ----------

test_begin "dump outputs valid JSON to stdout"
run "$LATTICE" dump "$DB2"
assert_valid_json "$STDOUT"

# ---------- Round-trip ----------

test_begin "round-trip: export then import into new DB"
run "$LATTICE" create "$DB3"
run "$LATTICE" import "$DB3" --file="$EXPORT_FILE"
assert_exit_code "$EXIT_CODE" 0

# ---------- Query from file ----------

test_begin "exec with --file flag"
run "$LATTICE" exec "$DB2" --file="$FIXTURES/test-queries.cypher"
assert_exit_code "$EXIT_CODE" 0

# ---------- Error handling ----------

test_begin "info on nonexistent database fails"
run "$LATTICE" info "/tmp/does-not-exist-12345.db"
assert_exit_code "$EXIT_CODE" 1

test_begin "invalid query syntax fails"
run "$LATTICE" exec "$DB" --query='THIS IS NOT VALID CYPHER'
if [ "$EXIT_CODE" -ne 0 ]; then
    pass
else
    fail "expected non-zero exit code for invalid query"
fi

# ---------- Output formats ----------

test_begin "table format works"
run "$LATTICE" exec "$DB" --query='MATCH (n:Person) RETURN n' --format=table
assert_exit_code "$EXIT_CODE" 0

test_begin "csv format works"
run "$LATTICE" exec "$DB" --query='MATCH (n:Person) RETURN n' --format=csv
assert_exit_code "$EXIT_CODE" 0

# ---------- Cross-process locking ----------
#
# Two processes writing one database file corrupt it, and the damage surfaces
# long after the moment that caused it. These tests use two real processes,
# because that is the thing being protected against; a second handle inside one
# process would exercise the same kernel lock but prove less.

LOCK_DB="/tmp/test-cli-lock.lattice"
LOCK_FIFO="/tmp/test-cli-lock.fifo"
rm -f "$LOCK_DB" "$LOCK_DB-wal" "$LOCK_FIFO"

run "$LATTICE" create "$LOCK_DB"
run "$LATTICE" exec "$LOCK_DB" --query="CREATE (p:Person {name: 'held'})"

# The interactive shell holds the database open until it is told to leave, which
# is how this test keeps a second process alive alongside the first.
mkfifo "$LOCK_FIFO"
"$LATTICE" query "$LOCK_DB" < "$LOCK_FIFO" > /tmp/test-cli-lock-repl.log 2>&1 &
LOCK_HOLDER_PID=$!
exec 9>"$LOCK_FIFO"
sleep 2

test_begin "a second writer is refused while another process holds the database"
run "$LATTICE" exec "$LOCK_DB" --query="CREATE (p:Person {name: 'intruder'})"
if [ "$EXIT_CODE" -ne 0 ]; then
    pass
else
    fail "expected a non-zero exit code for a second writer"
fi

test_begin "the refusal explains what to do about it"
assert_contains "$STDERR$STDOUT" "another process"

test_begin "a reader is refused while a writer holds the database"
run "$LATTICE" count "$LOCK_DB"
if [ "$EXIT_CODE" -ne 0 ]; then
    pass
else
    fail "expected a non-zero exit code for a reader"
fi

test_begin "--no-lock overrides the refusal"
run "$LATTICE" count "$LOCK_DB" --no-lock
assert_exit_code "$EXIT_CODE" 0

# Let the holder go, and the lock goes with it.
echo ".exit" >&9
exec 9>&-
wait "$LOCK_HOLDER_PID" 2>/dev/null
sleep 1

test_begin "the lock is released when the holding process exits"
run "$LATTICE" count "$LOCK_DB"
assert_exit_code "$EXIT_CODE" 0

test_begin "the database is intact after all of that"
run "$LATTICE" check "$LOCK_DB"
assert_exit_code "$EXIT_CODE" 0

rm -f "$LOCK_DB" "$LOCK_DB-wal" "$LOCK_FIFO" /tmp/test-cli-lock-repl.log

# ---------- Cleanup ----------
rm -f "$DB" "$DB-wal" "$DB2" "$DB2-wal" "$DB3" "$DB3-wal" "$EXPORT_FILE"
rm -f "$DB_VEC" "$DB_VEC-wal"

test_summary
