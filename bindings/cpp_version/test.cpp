#include "latticedb.hpp"

#include <filesystem>
#include <iostream>
#include <string>

int main() {
    const std::string path = "/tmp/lattice_cpp_smoke_test.db";
    std::filesystem::remove(path);
    std::filesystem::remove(path + "-wal");

    lattice_open_options_v4 options = LATTICE_OPEN_OPTIONS_V4_DEFAULT;
    options.create = true;
    options.read_only = false;
    options.lock = true;

    lattice_database* db = nullptr;
    auto rc = lattice::database::open_v4(path, &options, &db);
    if (rc != LATTICE_OK) {
        std::cerr << "open_v4 failed: " << rc << "\n";
        return 1;
    }

    lattice_txn* txn = nullptr;
    rc = lattice::transaction::begin(db, LATTICE_TXN_READ_WRITE, &txn);
    if (rc != LATTICE_OK) {
        std::cerr << "begin failed: " << rc << "\n";
        lattice::database::close(db);
        return 1;
    }

    lattice_node_id node_id = 0;
    rc = lattice::node::create(txn, "Person", &node_id);
    if (rc != LATTICE_OK) {
        std::cerr << "create failed: " << rc << "\n";
        lattice::transaction::rollback(txn);
        lattice::database::close(db);
        return 1;
    }

    rc = lattice::node::add_label(txn, node_id, "Active");
    if (rc != LATTICE_OK) {
        std::cerr << "add_label failed: " << rc << "\n";
        lattice::transaction::rollback(txn);
        lattice::database::close(db);
        return 1;
    }

    lattice_value name_value{};
    name_value.type = LATTICE_VALUE_STRING;
    name_value.data.string_val.ptr = "Alice";
    name_value.data.string_val.len = 5;

    rc = lattice::node::set_property(txn, node_id, "name", &name_value);
    if (rc != LATTICE_OK) {
        std::cerr << "set_property failed: " << rc << "\n";
        lattice::transaction::rollback(txn);
        lattice::database::close(db);
        return 1;
    }

    bool exists = false;
    rc = lattice::node::node_exists(txn, node_id, &exists);
    if (rc != LATTICE_OK || !exists) {
        std::cerr << "node_exists failed: " << rc << "\n";
        lattice::transaction::rollback(txn);
        lattice::database::close(db);
        return 1;
    }

    lattice_value out_value{};
    rc = lattice::node::get_property(txn, node_id, "name", &out_value);
    if (rc != LATTICE_OK || out_value.type != LATTICE_VALUE_STRING) {
        std::cerr << "get_property failed: " << rc << "\n";
        lattice::transaction::rollback(txn);
        lattice::database::close(db);
        return 1;
    }

    rc = lattice::node::remove_label(txn, node_id, "Active");
    if (rc != LATTICE_OK) {
        std::cerr << "remove_label failed: " << rc << "\n";
        lattice::transaction::rollback(txn);
        lattice::database::close(db);
        return 1;
    }

    rc = lattice::transaction::commit(txn);
    if (rc != LATTICE_OK) {
        std::cerr << "commit failed: " << rc << "\n";
        lattice::database::close(db);
        return 1;
    }

    rc = lattice::database::close(db);
    if (rc != LATTICE_OK) {
        std::cerr << "close failed: " << rc << "\n";
        return 1;
    }

    std::filesystem::remove(path);
    std::filesystem::remove(path + "-wal");
    std::cout << "C++ smoke test passed\n";
    return 0;
}
