module leizd::sorted_trove {
    use aptos_std::simple_map;
    use leizd::constant;
    use leizd::permission;
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
        borrow_global<Data<C>>(permission::owner_address()).head
    }

    public fun tail<C>(): address acquires Data {
        borrow_global<Data<C>>(permission::owner_address()).tail
    }

    public fun max_size<C>(): u64 acquires Data {
        borrow_global<Data<C>>(permission::owner_address()).max_size
    }

    public fun size<C>(): u64 acquires Data {
        borrow_global<Data<C>>(permission::owner_address()).size
    }

    public(friend) entry fun initialize<C>(owner: &signer) {
        initialize_internal<C>(owner, constant::u64_max());
    }

    fun initialize_internal<C>(owner: &signer, max_size: u64) {
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
        let data = borrow_global_mut<Data<C>>(permission::owner_address());
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
        simple_map::contains_key<address, Node>(&borrow_global<Data<C>>(permission::owner_address()).nodes, &id)
    }

    public(friend) entry fun remove<C>(id: address) acquires Data {
        remove_internal<C>(id);
    }

    fun contains_<C>(id: address, nodes: simple_map::SimpleMap<address,Node>):bool {
        simple_map::contains_key<address, Node>(&nodes, &id)
    }

    public fun insert_position_of<C>(id: address):(address, address) acquires Data {
        let amount = trove::trove_amount<C>(id);
        let (prev, next) = find_valid_insert_position(@0x0, @0x0, amount, borrow_global_mut<Data<C>>(permission::owner_address()));
        (prev, next)
    }

    // returns valid prev_id and next_id to be inserted between.
    fun find_valid_insert_position<C>(_prev_id: address, _next_id: address, amount: u64, data: &mut Data<C>): (address, address) {
        let (prev_id, next_id) = (_prev_id, _next_id);
        if (prev_id != @0x0) {
            if (!contains_<C>(prev_id, data.nodes) || amount > trove::trove_amount<C>(prev_id)) {
                prev_id = @0x0;
            }
        };
        if (next_id != @0x0) {
            if (!contains_<C>(next_id, data.nodes) || amount > trove::trove_amount<C>(next_id)) {
                next_id = @0x0;
            }
        };
        if (prev_id == @0x0 && next_id == @0x0) {
            // No hint - descend list starting from head
            return descend_list(amount, data.head, data)
        } else if (prev_id == @0x0) {
            // No `prevId` for hint - ascend list starting from `nextId`
            return ascend_list(amount, next_id, data)
        } else if (next_id == @0x0) {
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
        let data = borrow_global_mut<Data<C>>(permission::owner_address());
        let (prev_id, next_id) = prev_next_id_of(id, data);
        if (data.size > 1) {
            // List contains more than a single node
            if (id == data.head) {
                // The removed node is the head
                // Set head to next node
                data.head = next_id;
                let head = simple_map::borrow_mut<address, Node>(&mut data.nodes, &data.head);
                // Set prev pointer of new head to null
                head.prev_id = @0x0;
            } else if (id == data.tail) {
                // The removed node is the tail
                // Set tail to previous node
                data.tail = prev_id;
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
    use leizd::usdz;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use std::option;
    #[test_only]
    use std::signer;


    #[test_only]
    fun node<C>(account: address): option::Option<Node> acquires Data {
        let data = borrow_global_mut<Data<C>>(permission::owner_address());
        let node = simple_map::borrow_mut<address, Node>(&mut data.nodes, &account);
        option::some<Node>(*node)
    }

    #[test_only]
    public fun node_next<C>(account:address): address acquires Data {
        let node = node<C>(account);
        option::borrow_with_default<Node>(&node, &Node{next_id: @0x0, prev_id: @0x0}).next_id
    }

    #[test_only]
    public fun node_prev<C>(account:address): address acquires Data {
        let node = node<C>(account);
        option::borrow_with_default<Node>(&node, &Node{next_id: @0x0, prev_id: @0x0}).prev_id
    }


    #[test_only]
    fun set_up(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        test_coin::init_usdc(owner);
        initialize<USDC>(owner);
    }

    #[test_only]
    fun alice(owner: &signer): address {
        create_user(owner, @0x1)
    }

    #[test_only]
    fun bob(owner: &signer): address {
        create_user(owner, @0x2)
    }

    #[test_only]
    fun carol(owner: &signer): address {
        create_user(owner, @0x3)
    }

    #[test_only]
    fun users(owner: &signer):(address, address, address) {
        (alice(owner), bob(owner), carol(owner))
    }

    #[test_only]
    fun create_user(owner: &signer, account: address): address {
        let sig = account::create_account_for_test(account);
        managed_coin::register<USDC>(&sig);
        managed_coin::register<usdz::USDZ>(&sig);
        managed_coin::mint<USDC>(owner, account, 100000000);
        account
    }

    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 1)]
    fun test_node_capacity(owner: &signer) acquires Data {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        test_coin::init_usdc(owner);
        initialize_internal<USDC>(owner, 0);
        insert<USDC>(alice(owner));
    }

   #[test(owner=@leizd)]
   #[expected_failure(abort_code = 2)]
   fun test_remove_unknown_entry(owner: &signer) acquires Data {
        set_up(owner);
        remove<USDC>(alice(owner));
   }
}
