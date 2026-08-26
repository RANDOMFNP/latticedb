#include <string>
#include <iostream>
#include "lattice.h"

namespace lattice {

// Database Operations

namespace database {

// Open Database (edited settings)
lattice_error open(const std::string& path, 
                   const lattice_open_options* options,
                   lattice_database** db_out) {
    return lattice_open(path.c_str(), options, db_out);
}

// Open Database w/ v2 settings
lattice_error open_v2(const std::string& path,
                      const lattice_open_options_v2* options,
                      lattice_database** db_out) {
    return lattice_open_v2(path.c_str(), options, db_out);
}

// Open Database w/ v3 settings
lattice_error open_v3(const std::string& path,
                      const lattice_open_options_v3* options,
                      lattice_database** db_out) {
    return lattice_open_v3(path.c_str(), options, db_out);
}

// Open Database w/ v4 settings
lattice_error open_v4(const std::string& path,
                      const lattice_open_options_v4* options,
                      lattice_database** db_out) {
    return lattice_open_v4(path.c_str(), options, db_out);
}

// Close Database
lattice_error close(lattice_database* db) {
    return lattice_close(db);
}
}

// Transaction Operations

namespace transaction {

// Begin Transaction
lattice_error begin(lattice_database* db,
                    lattice_txn_mode mode,
                    lattice_txn** txn_out) {
    return lattice_begin(db, mode, txn_out);
}

// Commit Transaction
lattice_error commit(lattice_txn* txn) {
    return lattice_commit(txn);
}

// Rollback Transaction
lattice_error rollback(lattice_txn* txn) {
    return lattice_rollback(txn);
}
}

// Node Operations

namespace node {

// Create Node
lattice_error create(lattice_txn* txn, 
                     const std::string& label,
                     lattice_node_id* node_out) {
    return lattice_node_create(txn, label.c_str(), node_out);
}

// Add label to Node
lattice_error add_label(lattice_txn* txn,
                        lattice_node_id node_id,
                        const std::string& label) {
    return lattice_node_add_label(txn, node_id, label.c_str());
}

// Remove label from Node
lattice_error remove_label(lattice_txn* txn,
                           lattice_node_id node_id,
                           const std::string& label) {
    return lattice_node_remove_label(txn, node_id, label.c_str());
}

// Set property
lattice_error set_property(lattice_txn* txn,
                           lattice_node_id node_id,
                           const std::string& key,
                           const lattice_value* value) {
    return lattice_node_set_property(txn, node_id, key.c_str(), value);
}

// Gets property
lattice_error get_property(lattice_txn* txn,
                           lattice_node_id node_id,
                           const std::string& key,
                           lattice_value* value_out) {
    return lattice_node_get_property(txn, node_id, key.c_str(), value_out);
}

// Checks if Node exists
lattice_error node_exists(lattice_txn* txn,
                                  lattice_node_id node_id,
                                  bool* exists_out) {
    return lattice_node_exists(txn, node_id, exists_out);
}
}
}