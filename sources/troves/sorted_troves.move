module leizd::sorted_trove {
    use std::signer;
    use leizd::constant;
    use aptos_std::simple_map;
    friend leizd::trove;
    const E_NODE_ALREADY_EXISTS: u64 = 0;
    const E_EXCEEDS_MAX_NODE_CAP: u64 = 1;
    const E_NODE_NOT_FOUND: u64 = 2;

    struct Node has store, key, drop, copy {
        next_id: address,
        prev_id: address
    }

    struct Data has key, copy {
        head: address,
        tail: address,
        max_size: u64,
        size: u64,
        nodes: simple_map::SimpleMap<address,Node>,
    }

    public entry fun initialize(owner: &signer) {
        initialize_internal(owner, constant::u64_max());
    }

    fun initialize_internal(owner: &signer, max_size: u64) {
        assert!(!initialized(signer::address_of(owner)), 0);
        move_to(owner, Data{head: @0x0, tail: @0x0, max_size: max_size, size: 0, nodes: simple_map::create<address,Node>()});
    }

    fun initialized(account: address):bool {
        exists<Data>(account)
    }

    public(friend) fun insert(id: address, prev_id: address, next_id: address) acquires Data {
        insert_internal(id, prev_id, next_id);
    }

    fun insert_internal(id: address, prev_id: address, next_id: address) acquires Data {
        assert!(!contains(id), E_NODE_ALREADY_EXISTS);
        let data = borrow_global_mut<Data>(@leizd);
        assert!(data.size < data.max_size, E_EXCEEDS_MAX_NODE_CAP);
        let new_node = Node{next_id: @0x0, prev_id: @0x0};
        if (prev_id == @0x0 && next_id == @0x0) {
            data.head = id;
            data.tail = id;
        } else if (prev_id == @0x0) {
            new_node.next_id = data.head;
            let head = simple_map::borrow_mut<address, Node>(&mut data.nodes, &data.head);
            head.prev_id = id;
            data.head = id;
        } else if (next_id == @0x0) {
            new_node.prev_id = data.tail;
            let tail = simple_map::borrow_mut<address, Node>(&mut data.nodes, &data.tail);
            tail.next_id = id;
            data.tail = id;
        } else {
            new_node.next_id = next_id;
            new_node.prev_id = prev_id;
            let prev_node = simple_map::borrow_mut<address, Node>(&mut data.nodes, &prev_id);
            prev_node.next_id = id;
            let next_node = simple_map::borrow_mut<address, Node>(&mut data.nodes, &next_id);
            next_node.prev_id = id;
        };
        simple_map::add<address, leizd::sorted_trove::Node>(&mut data.nodes, id, new_node);
        data.size = data.size + 1;
    }

    fun contains(id: address): bool acquires Data {
        simple_map::contains_key<address, Node>(&borrow_global<Data>(@leizd).nodes, &id)
    }

    public(friend) entry fun remove(id: address) acquires Data {
        remove_internal(id);
    }

    fun is_insert_position_valid(): bool {
        true
    }

    // returns valid prev_id and next_id to be inserted between.
    fun find_valid_insert_position(): (address, address) {
        (@0x0,@0x0) 
    }

    // Remove a node from the list
    fun remove_internal(id: address) acquires Data {
        assert!(contains(id), E_NODE_NOT_FOUND);
        let data = borrow_global_mut<Data>(@leizd);
        let (prev_id, next_id) = prev_next_id(id, data);
        if (!is_insert_position_valid()) {
            (prev_id, next_id) = find_valid_insert_position()
        };
        if (data.size > 1) {
            let node = simple_map::borrow<address, Node>(&data.nodes, &id);
            // List contains more than a single node
            if (id == data.head) {
                // The removed node is the head
                // Set head to next node
                data.head = node.next_id;
                let head = simple_map::borrow_mut<address, Node>(&mut data.nodes, &data.head);
                // Set prev pointer of new head to null
                head.prev_id = @0x0;
            } else if (id == data.tail) {
                // The removed node is the tail
                // Set tail to previous node
                data.tail = node.prev_id;
                let tail = simple_map::borrow_mut<address, Node>(&mut data.nodes, &data.tail);
                // Set next pointer of new tail to null
                tail.next_id = @0x0;
            } else {
                // The removed node is neither the head nor the tail
                // Set next pointer of previous node to the next node
                let prev = simple_map::borrow_mut<address, Node>(&mut data.nodes, &prev_id);
                prev.next_id = next_id;
                // Set prev pointer of next node to the previous node
                let next = simple_map::borrow_mut<address, Node>(&mut data.nodes, &next_id);
                next.prev_id = prev_id;
            }
        } else {
            // List contains a single node
            // Set the head and tail to null
            data.head = @0x0;
            data.tail = @0x0;
        };
        simple_map::remove<address, Node>(&mut data.nodes, &id);
        data.size = data.size -1;
    }

    fun prev_next_id(id: address, data: &mut Data):(address,address) {
        let node = simple_map::borrow<address, Node>(&data.nodes, &id);
        (node.prev_id, node.next_id)
    }

    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 1)]
    fun test_node_capacity(owner: signer) acquires Data {
        initialize_internal(&owner, 0);
        insert(@0x1, @0x0, @0x0);
    }

    #[test(owner=@leizd)]
    fun test_insert(owner: signer) acquires Data {
        initialize(&owner);
        // insert 1 elem
        let account1 = @0x1;
        insert(account1, @0x0, @0x0);
        let data = borrow_global<Data>(@leizd);
        assert!(data.size == 1, 0);
        assert!(data.head == account1, 0);
        assert!(data.tail == account1, 0);
        let node = simple_map::borrow(&data.nodes, &account1);
        assert!(node.next_id == @0x0, 0);
        assert!(node.prev_id == @0x0, 0);
        
        // insert more elem after account1
        let account2 = @0x2;
        insert(account2, account1, @0x0);
        let data = borrow_global<Data>(@leizd);
        assert!(&data.size == &2, 0);
        assert!(&data.head == &account1, 0);
        assert!(&data.tail == &account2, 0);
        let node = simple_map::borrow(&data.nodes, &account2);
        assert!(node.next_id == @0x0, 0);
        assert!(node.prev_id == account1, 0);

        // insert more elem between account1 and account2
        let account3 = @0x3;
        insert(account3, account1, account2);
        let data = borrow_global<Data>(@leizd);
        assert!(&data.size == &3, 0);
        assert!(&data.head == &account1, 0);
        assert!(&data.tail == &account2, 0);
        let node = simple_map::borrow(&data.nodes, &account3);
        assert!(node.next_id == account2, 0);
        assert!(node.prev_id == account1, 0);
        assert!(simple_map::borrow(&data.nodes, &account2).prev_id == account3, 0);
    }

    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 2)]
    fun test_remove_unknown_entry(owner: signer) acquires Data {
        initialize(&owner);
        let account1 = @0x1;
        remove(account1)
    }

    #[test(owner=@leizd)]
    fun test_remove_1_entry(owner: signer) acquires Data {
        initialize(&owner);
        let account1 = @0x1;
        insert(account1, @0x0, @0x0);
        // remove 1 of 1 element
        remove(account1);
        let data = borrow_global<Data>(@leizd);
        assert!(&data.head == &@0x0, 0);
        assert!(&data.tail == &@0x0, 0);
        assert!(&data.size == &0, 0);
        assert!(&data.nodes == &simple_map::create<address,Node>(), 0);
    }

    #[test(owner=@leizd)]
    fun test_remove_head_of_2_entries(owner: signer) acquires Data {
        initialize(&owner);
        let account1 = @0x1;
        let account2 = @0x2;
        insert(account1, @0x0, @0x0);
        insert(account2, account1, @0x0);
        // remove 1 of 2 elements
        remove(account1);
        let data = borrow_global<Data>(@leizd);
        assert!(&data.head == &account2, 0);
        assert!(&data.tail == &account2, 0);
        assert!(&data.size == &1, 0);
        let node = simple_map::borrow<address, Node>(&data.nodes, &account2);
        assert!(node.next_id == @0x0, 0);
        assert!(node.prev_id == @0x0, 0);
    }

    #[test(owner=@leizd)]
    fun test_remove_tail_of_2_entries(owner: signer) acquires Data {
        initialize(&owner);
        let account1 = @0x1;
        let account2 = @0x2;
        insert(account1, @0x0, @0x0);
        insert(account2, account1, @0x0);
        // remove 1 of 2 elements
        remove(account2);
        let data = borrow_global<Data>(@leizd);
        assert!(&data.head == &account1, 0);
        assert!(&data.tail == &account1, 0);
        assert!(&data.size == &1, 0);
        let node = simple_map::borrow<address, Node>(&data.nodes, &account1);
        assert!(node.next_id == @0x0, 0);
        assert!(node.prev_id == @0x0, 0);
    }
    
    #[test(owner=@leizd)]
    fun test_remove_head_of_3_entries(owner: signer) acquires Data {
        initialize(&owner);
        let account1 = @0x1;
        let account2 = @0x2;
        let account3 = @0x3;
        insert(account1, @0x0, @0x0);
        insert(account2, account1, @0x0);
        insert(account3, account2, @0x0);
        // remove 1 of 3 elements
        remove(account1);
        let data = borrow_global<Data>(@leizd);
        assert!(&data.head == &account2, 0);
        assert!(&data.tail == &account3, 0);
        assert!(&data.size == &2, 0);
        let node_account2 = simple_map::borrow<address, Node>(&data.nodes, &account2);
        assert!(node_account2.next_id == account3, 0);
        assert!(node_account2.prev_id == @0x0, 0);
        let node_account3 = simple_map::borrow<address, Node>(&data.nodes, &account3);
        assert!(node_account3.next_id == @0x0, 0);
        assert!(node_account3.prev_id == account2, 0);
    }

    #[test(owner=@leizd)]
    fun test_remove_middle_of_3_entries(owner: signer) acquires Data {
        initialize(&owner);
        let account1 = @0x1;
        let account2 = @0x2;
        let account3 = @0x3;
        insert(account1, @0x0, @0x0);
        insert(account2, account1, @0x0);
        insert(account3, account2, @0x0);
        // remove 1 of 3 elements
        remove(account2);
        let data = borrow_global<Data>(@leizd);
        assert!(&data.head == &account1, 0);
        assert!(&data.tail == &account3, 0);
        assert!(&data.size == &2, 0);
        let node_account1 = simple_map::borrow<address, Node>(&data.nodes, &account1);
        assert!(node_account1.next_id == account3, 0);
        assert!(node_account1.prev_id == @0x0, 0);
        let node_account3 = simple_map::borrow<address, Node>(&data.nodes, &account3);
        assert!(node_account3.next_id == @0x0, 0);
        assert!(node_account3.prev_id == account1, 0);
    }

    #[test(owner=@leizd)]
    fun test_remove_tail_of_3_entries(owner: signer) acquires Data {
        initialize(&owner);
        let account1 = @0x1;
        let account2 = @0x2;
        let account3 = @0x3;
        insert(account1, @0x0, @0x0);
        insert(account2, account1, @0x0);
        insert(account3, account2, @0x0);
        // remove 1 of 3 elements
        remove(account3);
        let data = borrow_global<Data>(@leizd);
        assert!(&data.head == &account1, 0);
        assert!(&data.tail == &account2, 0);
        assert!(&data.size == &2, 0);
        let node_account1 = simple_map::borrow<address, Node>(&data.nodes, &account1);
        assert!(node_account1.next_id == account2, 0);
        assert!(node_account1.prev_id == @0x0, 0);
        let node_account2 = simple_map::borrow<address, Node>(&data.nodes, &account2);
        assert!(node_account2.next_id == @0x0, 0);
        assert!(node_account2.prev_id == account1, 0);
    }
}
