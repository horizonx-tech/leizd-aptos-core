module leizd::sorted_trove {
    use std::signer;
    use leizd::constant;
    use aptos_std::simple_map;
    use leizd::trove;
    friend leizd::trove_manager;
    const E_NODE_ALREADY_EXISTS: u64 = 0;
    const E_EXCEEDS_MAX_NODE_CAP: u64 = 1;
    const E_NODE_NOT_FOUND: u64 = 2;

    struct Node has store, key, drop, copy {
        next_id: address,
        prev_id: address
    }

    struct Data<phantom C> has key, copy, store {
        head: address,
        tail: address,
        max_size: u64,
        size: u64,
        nodes: simple_map::SimpleMap<address,Node>,
    }

    public fun head<C>(): address acquires Data {
        borrow_global<Data<C>>(@leizd).head
    }

    public entry fun initialize<C>(owner: &signer) {
        initialize_internal<C>(owner, constant::u64_max());
    }

    fun initialize_internal<C>(owner: &signer, max_size: u64) {
        assert!(!initialized<C>(signer::address_of(owner)), 0);
        move_to(owner, Data<C>{head: @0x0, tail: @0x0, max_size: max_size, size: 0, nodes: simple_map::create<address,Node>()});
    }

    fun initialized<C>(account: address):bool {
        exists<Data<C>>(account)
    }

    public(friend) fun insert_between<C>(id: address, prev_id: address, next_id: address) acquires Data {
        insert_internal<C>(id, prev_id, next_id);
    }

    public(friend) fun insert<C>(id: address) acquires Data {
        let (prev, next) = insert_position_of<C>(id);
        insert_internal<C>(id, prev, next);
    }

    fun is_insert_position_valid<C>(prev_id: address, next_id: address, amount: u64, data: &mut Data<C>): bool {
        if (prev_id == @0x0 && next_id == @0x0) {
            return data.size == 0
        };
         if (prev_id == @0x0) {
            return data.head == next_id && amount >= trove::trove_amount<C>(next_id)
        };
        if (next_id == @0x0) {
            return data.tail == prev_id && amount <= trove::trove_amount<C>(prev_id)
        };
        let prev_node = simple_map::borrow<address,Node>(&data.nodes, &prev_id);
        prev_node.next_id == next_id && trove::trove_amount<C>(prev_id) >= amount && amount >= trove::trove_amount<C>(next_id)
    }


    fun insert_internal<C>(id: address, prev_id: address, next_id: address) acquires Data {
        assert!(!contains<C>(id), E_NODE_ALREADY_EXISTS);
        let data = borrow_global_mut<Data<C>>(@leizd);
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

    fun contains<C>(id: address): bool acquires Data {
        simple_map::contains_key<address, Node>(&borrow_global<Data<C>>(@leizd).nodes, &id)
    }

    public(friend) entry fun remove<C>(id: address) acquires Data {
        remove_internal<C>(id);
    }

    fun contains_<C>(id: address, nodes: simple_map::SimpleMap<address,Node>):bool {
        simple_map::contains_key<address, Node>(&nodes, &id)
    }

    public fun insert_position_of<C>(id: address):(address, address) acquires Data {
        let amount = trove::trove_amount<C>(id);
        let (prev, next) = find_valid_insert_position(@0x0, @0x0, amount, borrow_global_mut<Data<C>>(@leizd));
        (prev, next)
    }

    // returns valid prev_id and next_id to be inserted between.
    fun find_valid_insert_position<C>(prev_id: address, next_id: address, amount: u64, data: &mut Data<C>): (address, address) {
        let ret_prev_id = prev_id;
        let ret_next_id = next_id;
        if (prev_id == @0x0) {
            if (!contains_<C>(prev_id, data.nodes) || amount > trove::trove_amount<C>(prev_id)) {
                ret_prev_id = @0x0;
            }
        };
        if (next_id == @0x0) {
            if (!contains_<C>(next_id, data.nodes) || amount > trove::trove_amount<C>(next_id)) {
                ret_next_id = @0x0;
            }
        };
        if (ret_prev_id == @0x0 && ret_next_id == @0x0) {
            // No hint - descend list starting from head
            return descend_list(amount, data.head, data)
        } else if (ret_prev_id == @0x0) {
            // No `prevId` for hint - ascend list starting from `nextId`
            return ascend_list(amount, next_id, data)
        } else if (ret_next_id == @0x0) {
            // No `nextId` for hint - descend list starting from `prevId`
            return descend_list(amount, prev_id, data)
        };
        // Descend list starting from `prevId`
        descend_list(amount, prev_id, data)
    }
    
    fun descend_list<C>(amount: u64, start_id: address, data: &mut Data<C>): (address,address) {
        if (data.head == start_id && amount >= trove::trove_amount<C>(start_id)) {
            return (@0x0, start_id)
        };
        let prev_id = start_id;
        let next_id = simple_map::borrow<address, Node>(&data.nodes, &prev_id).next_id;
        while (prev_id != @0x0 && !is_insert_position_valid(prev_id, next_id, amount, data)){
            prev_id  = simple_map::borrow<address, Node>(&data.nodes, &prev_id).next_id;
            next_id = simple_map::borrow<address, Node>(&data.nodes, &prev_id).next_id;
        };
        (prev_id, next_id)
    }

    fun ascend_list<C>(amount: u64, start_id: address, data: &mut Data<C>): (address, address) {
        if(data.tail == start_id && amount <= trove::trove_amount<C>(start_id)) {
            return (start_id, @0x0)
        };
        let next_id = start_id;
        let prev_id = simple_map::borrow<address, Node>(&data.nodes, &next_id).prev_id;
        while (next_id != @0x0 && !is_insert_position_valid(prev_id, next_id, amount, data)) {
            next_id = simple_map::borrow<address, Node>(&data.nodes, &next_id).prev_id;
            prev_id = simple_map::borrow<address, Node>(&data.nodes, &next_id).prev_id;
        };
        (prev_id, next_id)
    }

    // Remove a node from the list
    fun remove_internal<C>(id: address) acquires Data {
        assert!(contains<C>(id), E_NODE_NOT_FOUND);
        let data = borrow_global_mut<Data<C>>(@leizd);
        let (prev_id, next_id) = prev_next_id_of(id, data);
        if (!is_insert_position_valid<C>(prev_id, next_id, trove::trove_amount<C>(id), data)) {
            (prev_id, next_id) = find_valid_insert_position<C>(prev_id, next_id, trove::trove_amount<C>(id), data)
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

    fun prev_next_id_of<C>(id: address, data: &mut Data<C>):(address,address) {
        let node = simple_map::borrow<address, Node>(&data.nodes, &id);
        (node.prev_id, node.next_id)
    }

    #[test_only]
    use leizd::test_coin::{Self,USDC};

    #[test_only]
    fun set_up(owner: &signer) {
        test_coin::init_usdc(owner);
    }

    #[test_only]
    const ALICE :address = @0x1;
    #[test_only]
    const BOB: address = @0x2;
    #[test_only]
    const CAROL: address = @0x3;

   //#[test(owner=@leizd)]
   //#[expected_failure(abort_code = 1)]
   //fun test_node_capacity<C>(owner: signer) acquires Data {
   //    initialize_internal<C>(&owner, 0);
   //    insert<C>(ALICE, @0x0, @0x0);
   //}

   //#[test(owner=@leizd)]
   //fun test_insert<USDC>(owner: signer) acquires Data {
   //    initialize<USDC>(&owner);
   //    // insert 1 elem
   //    insert<USDC>(ALICE, @0x0, @0x0);
   //    let data = borrow_global<Data<USDC>>(@leizd);
   //    assert!(data.size == 1, 0);
   //    assert!(data.head == ALICE, 0);
   //    assert!(data.tail == ALICE, 0);
   //    let node = simple_map::borrow(&data.nodes, &ALICE);
   //    assert!(node.next_id == @0x0, 0);
   //    assert!(node.prev_id == @0x0, 0);
   //    
   //    // insert more elem after account1
   //    insert<USDC>(BOB, ALICE, @0x0);
   //    let data = borrow_global<Data<USDC>>(@leizd);
   //    assert!(&data.size == &2, 0);
   //    assert!(&data.head == &ALICE, 0);
   //    assert!(&data.tail == &BOB, 0);
   //    let node = simple_map::borrow(&data.nodes, &BOB);
   //    assert!(node.next_id == @0x0, 0);
   //    assert!(node.prev_id == ALICE, 0);
//
   //    // insert more elem between account1 and account2
   //    insert<USDC>(CAROL, ALICE, BOB);
   //    let data = borrow_global<Data<USDC>>(@leizd);
   //    assert!(&data.size == &3, 0);
   //    assert!(&data.head == &ALICE, 0);
   //    assert!(&data.tail == &BOB, 0);
   //    let node = simple_map::borrow(&data.nodes, &CAROL);
   //    assert!(node.next_id == BOB, 0);
   //    assert!(node.prev_id == ALICE, 0);
   //    assert!(simple_map::borrow(&data.nodes, &BOB).prev_id == CAROL, 0);
   //}

   #[test(owner=@leizd)]
   #[expected_failure(abort_code = 2)]
   fun test_remove_unknown_entry(owner: signer) acquires Data {
       initialize<USDC>(&owner);
       remove<USDC>(ALICE)
   }

   #[test(owner=@leizd)]
   fun test_remove_1_entry(owner: signer) acquires Data {
       initialize<USDC>(&owner);
       insert<USDC>(ALICE);
       // remove 1 of 1 element
       remove<USDC>(ALICE);
       let data = borrow_global<Data<USDC>>(@leizd);
       assert!(&data.head == &@0x0, 0);
       assert!(&data.tail == &@0x0, 0);
       assert!(&data.size == &0, 0);
       assert!(&data.nodes == &simple_map::create<address,Node>(), 0);
   }

   #[test(owner=@leizd)]
   fun test_remove_head_of_2_entries(owner: signer) acquires Data {
       initialize<USDC>(&owner);
       insert<USDC>(ALICE);
       insert<USDC>(BOB);
       // remove 1 of 2 elements
       remove<USDC>(ALICE);
       let data = borrow_global<Data<USDC>>(@leizd);
       assert!(&data.head == &BOB, 0);
       assert!(&data.tail == &BOB, 0);
       assert!(&data.size == &1, 0);
       let node = simple_map::borrow<address, Node>(&data.nodes, &BOB);
       assert!(node.next_id == @0x0, 0);
       assert!(node.prev_id == @0x0, 0);
   }

   #[test(owner=@leizd)]
   fun test_remove_tail_of_2_entries(owner: signer) acquires Data {
       initialize<USDC>(&owner);
       insert<USDC>(ALICE);
       insert<USDC>(BOB);
       // remove 1 of 2 elements
       remove<USDC>(BOB);
       let data = borrow_global<Data<USDC>>(@leizd);
       assert!(&data.head == &ALICE, 0);
       assert!(&data.tail == &ALICE, 0);
       assert!(&data.size == &1, 0);
       let node = simple_map::borrow<address, Node>(&data.nodes, &ALICE);
       assert!(node.next_id == @0x0, 0);
       assert!(node.prev_id == @0x0, 0);
   }
   
   //#[test(owner=@leizd)]
   //fun test_remove_head_of_3_entries(owner: signer) acquires Data {
   //    initialize<USDC>(&owner);
   //    insert<USDC>(ALICE, @0x0, @0x0);
   //    insert<USDC>(BOB, ALICE, @0x0);
   //    insert<USDC>(CAROL, BOB, @0x0);
   //    // remove 1 of 3 elements
   //    remove<USDC>(ALICE);
   //    let data = borrow_global<Data<USDC>>(@leizd);
   //    assert!(&data.head == &BOB, 0);
   //    assert!(&data.tail == &ALICE, 0);
   //    assert!(&data.size == &2, 0);
   //    let node_account2 = simple_map::borrow<address, Node>(&data.nodes, &BOB);
   //    assert!(node_account2.next_id == CAROL, 0);
   //    assert!(node_account2.prev_id == @0x0, 0);
   //    let node_account3 = simple_map::borrow<address, Node>(&data.nodes, &CAROL);
   //    assert!(node_account3.next_id == @0x0, 0);
   //    assert!(node_account3.prev_id == BOB, 0);
   //}

   //#[test(owner=@leizd)]
   //fun test_remove_middle_of_3_entries(owner: signer) acquires Data {
   //    initialize<USDC>(&owner);
   //    insert<USDC>(ALICE, @0x0, @0x0);
   //    insert<USDC>(BOB, ALICE, @0x0);
   //    insert<USDC>(CAROL, BOB, @0x0);
   //    // remove 1 of 3 elements
   //    remove<USDC>(BOB);
   //    let data = borrow_global<Data<USDC>>(@leizd);
   //    assert!(&data.head == &ALICE, 0);
   //    assert!(&data.tail == &CAROL, 0);
   //    assert!(&data.size == &2, 0);
   //    let node_account1 = simple_map::borrow<address, Node>(&data.nodes, &ALICE);
   //    assert!(node_account1.next_id == CAROL, 0);
   //    assert!(node_account1.prev_id == @0x0, 0);
   //    let node_account3 = simple_map::borrow<address, Node>(&data.nodes, &CAROL);
   //    assert!(node_account3.next_id == @0x0, 0);
   //    assert!(node_account3.prev_id == ALICE, 0);
   //}
//
   //#[test(owner=@leizd)]
   //fun test_remove_tail_of_3_entries(owner: signer) acquires Data {
   //    initialize<USDC>(&owner);
   //    insert<USDC>(ALICE, @0x0, @0x0);
   //    insert<USDC>(BOB, ALICE, @0x0);
   //    insert<USDC>(CAROL, BOB, @0x0);
   //    // remove 1 of 3 elements
   //    remove<USDC>(CAROL);
   //    let data = borrow_global<Data<USDC>>(@leizd);
   //    assert!(&data.head == &ALICE, 0);
   //    assert!(&data.tail == &BOB, 0);
   //    assert!(&data.size == &2, 0);
   //    let node_account1 = simple_map::borrow<address, Node>(&data.nodes, &ALICE);
   //    assert!(node_account1.next_id == BOB, 0);
   //    assert!(node_account1.prev_id == @0x0, 0);
   //    let node_account2 = simple_map::borrow<address, Node>(&data.nodes, &BOB);
   //    assert!(node_account2.next_id == @0x0, 0);
   //    assert!(node_account2.prev_id == ALICE, 0);
   //}
}
