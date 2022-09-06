module leizd::sorted_trove {
    use std::signer;
    use leizd::constant;
    use aptos_std::simple_map;
    friend leizd::trove;

    struct Node has store, key, copy, drop {
        next_id: address,
        prev_id: address
    }

    struct Data has key, store {
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

    public(friend) fun insert(id: address, prev_id: address, next_id: address) acquires Data, Node {
        insert_internal(id, prev_id, next_id);
    }

    fun insert_internal(id: address, prev_id: address, next_id: address) acquires Data, Node {
        assert!(!contains(id), 0);
        let data = borrow_global_mut<Data>(@leizd);
        assert!(data.size < data.max_size, 0);
        let new_node = Node{next_id: @0x0, prev_id: @0x0};
        if (prev_id == @0x0 && next_id == @0x0) {
            data.head = id;
            data.tail = id;
        } else if (prev_id == @0x0) {
            new_node.next_id = data.head;
            new_node.prev_id = id;
            data.head = id;
        } else if (next_id == @0x0) {
            new_node.next_id = next_id;
            new_node.prev_id = prev_id;
            let prev_node = borrow_global_mut<Node>(prev_id);
            prev_node.next_id = id;
            let next_node = borrow_global_mut<Node>(next_id);
            next_node.prev_id = id;
        };
        let nodes = data.nodes;
        simple_map::add(&mut nodes, id, new_node);
        data.size = data.size + 1;
    }

    fun contains(id: address): bool acquires Data {
        simple_map::contains_key<address, Node>(&borrow_global<Data>(@leizd).nodes, &id)
    }

    public(friend) entry fun remove(id: address) acquires Data, Node {
        remove_internal(id);
    }

    // Remove a node from the list
    fun remove_internal(id: address) acquires Data, Node {
        assert!(contains(id), 0);
        let data = borrow_global_mut<Data>(@leizd);
        let node = borrow_global<Node>(id);
        if (data.size > 1) {
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
                let prev = simple_map::borrow_mut<address, Node>(&mut data.nodes, &node.prev_id);
                prev.next_id = node.next_id;
                // Set prev pointer of next node to the previous node
                let next = simple_map::borrow_mut<address, Node>(&mut data.nodes, &node.next_id);
                next.prev_id = node.prev_id;
            };
        } else {
            // List contains a single node
            // Set the head and tail to null
            data.head = @0x0;
            data.tail = @0x0;
        };
        simple_map::remove<address, Node>(&mut data.nodes, &id);
    }

    #[test(owner=@leizd,account1=@0x111)]
    fun test_insert(owner: signer, account1: address) acquires Data, Node {
        initialize(&owner);
        insert(account1, @0x0, @0x0);
    }

}
