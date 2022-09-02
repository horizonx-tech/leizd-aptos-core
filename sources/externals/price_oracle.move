module leizd::price_oracle {

    use std::signer;
    use std::string;
    use aptos_std::type_info;
    use aptos_framework::table;
    use switchboard::aggregator;
    use switchboard::math;
    use leizd::permission;

    struct AggregatorStorage has key {
        aggregators: table::Table<string::String, address>
    }

    public entry fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, AggregatorStorage { aggregators: table::new<string::String, address>() });
    }

    public entry fun add_aggregator<C>(owner: &signer, aggregator: address) acquires AggregatorStorage {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);
        let key = type_info::type_name<C>();
        let aggrs = &mut borrow_global_mut<AggregatorStorage>(owner_address).aggregators;
        table::add<string::String, address>(aggrs, key, aggregator)
    }

    fun price_internal(aggregator: address): u128 {
        let latest_value = aggregator::latest_value(aggregator);
        let (value, _, _) = math::unpack(latest_value);
        value / math::pow_10(9) // TODO: modify scaling (currently, temp)
    }

    public fun price<C>(): u64 acquires AggregatorStorage {
        let key = type_info::type_name<C>();
        let aggrs = &borrow_global<AggregatorStorage>(permission::owner_address()).aggregators;
        let aggregator_address = table::borrow<string::String, address>(aggrs, key);
        (price_internal(*aggregator_address) as u64)
    }

    public fun price_of(name: &string::String): u64 acquires AggregatorStorage {
        let aggrs = &borrow_global<AggregatorStorage>(permission::owner_address()).aggregators;
        let aggregator_address = table::borrow<string::String, address>(aggrs, *name);
        (price_internal(*aggregator_address) as u64)
    }

    public fun volume(name: &string::String, amount: u64): u64 acquires AggregatorStorage {
        amount * price_of(name)
    }

    public fun amount(name: &string::String, volume: u64): u64 acquires AggregatorStorage {
        volume / price_of(name)
    }

    #[test_only]
    use leizd::test_coin;
    #[test(owner = @leizd)]
    fun test_initialize(owner: &signer) {
        initialize(owner);
        assert!(exists<AggregatorStorage>(signer::address_of(owner)), 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_initialize_with_not_owner(account: &signer) {
        initialize(account);
    }
    #[test(owner = @leizd)]
    fun test_add_aggregator(owner: &signer) acquires AggregatorStorage {
        initialize(owner);
        add_aggregator<test_coin::USDC>(owner, @0x111AAA);
        add_aggregator<test_coin::WETH>(owner, @0x222AAA);
        let aggrs = &borrow_global<AggregatorStorage>(signer::address_of(owner)).aggregators;
        let aggr_usdc = table::borrow<string::String, address>(aggrs, type_info::type_name<test_coin::USDC>());
        assert!(aggr_usdc == &@0x111AAA, 0);
        let aggr_weth = table::borrow<string::String, address>(aggrs, type_info::type_name<test_coin::WETH>());
        assert!(aggr_weth == &@0x222AAA, 0);
        assert!(!table::contains<string::String, address>(aggrs, type_info::type_name<test_coin::UNI>()), 0);
        assert!(!table::contains<string::String, address>(aggrs, type_info::type_name<test_coin::USDT>()), 0);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_add_aggregator_with_not_owner(owner: &signer, account: &signer) acquires AggregatorStorage {
        initialize(owner);
        add_aggregator<test_coin::USDC>(account, @0x111AAA);
    }
    #[test(owner = @leizd, usdc_aggr = @0x111AAA, weth_aggr = @0x222AAA)]
    fun test_end_to_end(owner: &signer, usdc_aggr: &signer, weth_aggr: &signer) acquires AggregatorStorage {
        aggregator::new_test(usdc_aggr, 2, 0, false);
        aggregator::new_test(weth_aggr, 3, 0, false);

        initialize(owner);
        add_aggregator<test_coin::USDC>(owner, signer::address_of(usdc_aggr));
        add_aggregator<test_coin::WETH>(owner, signer::address_of(weth_aggr));

        assert!(price_internal(signer::address_of(usdc_aggr)) == 2, 0);
        assert!(price_internal(signer::address_of(weth_aggr)) == 3, 0);
        assert!(price<test_coin::USDC>() == 2, 0);
        assert!(price<test_coin::WETH>() == 3, 0);
        assert!(price_of(&type_info::type_name<test_coin::USDC>()) == 2, 0);
        assert!(price_of(&type_info::type_name<test_coin::WETH>()) == 3, 0);
    }
    #[test_only]
    public fun initialize_oracle_for_test(owner: &signer) acquires AggregatorStorage {
        aggregator::new_test(owner, 1, 0, false);
        let owner_address = signer::address_of(owner);
        initialize(owner);
        add_aggregator<test_coin::USDC>(owner, owner_address);
        add_aggregator<test_coin::WETH>(owner, owner_address);
        add_aggregator<test_coin::UNI>(owner, owner_address);
        add_aggregator<test_coin::USDT>(owner, owner_address);
    }
    #[test(leizd = @leizd)]
    fun test_price_after_initialize_oracle_for_test(leizd: &signer) acquires AggregatorStorage {
        initialize_oracle_for_test(leizd);
        assert!(price<test_coin::USDC>() == 1, 0);
        assert!(price<test_coin::WETH>() == 1, 0);
        assert!(price<test_coin::UNI>() == 1, 0);
        assert!(price<test_coin::USDT>() == 1, 0);
    }
    #[test(leizd = @leizd)]
    fun test_price_of_after_initialize_oracle_for_test(leizd: &signer) acquires AggregatorStorage {
        initialize_oracle_for_test(leizd);
        assert!(price_of(&type_info::type_name<test_coin::USDC>()) == 1, 0);
        assert!(price_of(&type_info::type_name<test_coin::WETH>()) == 1, 0);
        assert!(price_of(&type_info::type_name<test_coin::UNI>()) == 1, 0);
        assert!(price_of(&type_info::type_name<test_coin::USDT>()) == 1, 0);
    }
}
