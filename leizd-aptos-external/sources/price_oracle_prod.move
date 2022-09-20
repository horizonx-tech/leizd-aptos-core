module leizd_aptos_external::price_oracle_prod {

    use std::signer;
    use std::string;
    use aptos_std::type_info;
    use aptos_framework::simple_map;
    use switchboard::aggregator;
    use switchboard::math;
    use leizd_aptos_common::permission;

    struct Config has key {
        isMockedPrice: bool
    }

    struct AggregatorStorage has key {
        aggregators: simple_map::SimpleMap<string::String, address>
    }

    public entry fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, Config { isMockedPrice: false });
        move_to(owner, AggregatorStorage { aggregators: simple_map::create<string::String, address>() });
    }

    public entry fun add_aggregator<C>(owner: &signer, aggregator: address) acquires AggregatorStorage {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);
        let key = type_info::type_name<C>();
        let aggrs = &mut borrow_global_mut<AggregatorStorage>(owner_address).aggregators;
        simple_map::add<string::String, address>(aggrs, key, aggregator)
    }

    fun price_internal(aggregator: address): u128 {
        let latest_value = aggregator::latest_value(aggregator);
        let (value, _, _) = math::unpack(latest_value);
        value / math::pow_10(9) // TODO: modify scaling (currently, temp)
    }

    public fun price<C>(): u64 acquires AggregatorStorage {
        let key = type_info::type_name<C>();
        let aggrs = &borrow_global<AggregatorStorage>(permission::owner_address()).aggregators;
        let aggregator_address = simple_map::borrow<string::String, address>(aggrs, &key);
        (price_internal(*aggregator_address) as u64)
    }

    public fun price_of(name: &string::String): u64 acquires AggregatorStorage {
        let aggrs = &borrow_global<AggregatorStorage>(permission::owner_address()).aggregators;
        let aggregator_address = simple_map::borrow<string::String, address>(aggrs, name);
        (price_internal(*aggregator_address) as u64)
    }

    public fun volume(name: &string::String, amount: u64): u64 acquires AggregatorStorage {
        amount * price_of(name)
    }

    public fun amount(name: &string::String, volume: u64): u64 acquires AggregatorStorage {
        volume / price_of(name)
    }

    #[test_only]
    use leizd_aptos_common::test_coin::{USDC, WETH, UNI, USDT};
    #[test(owner = @leizd_aptos_external)]
    fun test_initialize(owner: &signer) {
        initialize(owner);
        let owner_addr = signer::address_of(owner);
        assert!(exists<Config>(owner_addr), 0);
        assert!(exists<AggregatorStorage>(owner_addr), 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_initialize_with_not_owner(account: &signer) {
        initialize(account);
    }
    #[test(owner = @leizd_aptos_external)]
    fun test_add_aggregator(owner: &signer) acquires AggregatorStorage {
        initialize(owner);
        add_aggregator<USDC>(owner, @0x111AAA);
        add_aggregator<WETH>(owner, @0x222AAA);
        let aggrs = &borrow_global<AggregatorStorage>(signer::address_of(owner)).aggregators;
        let aggr_usdc = simple_map::borrow<string::String, address>(aggrs, &type_info::type_name<USDC>());
        assert!(aggr_usdc == &@0x111AAA, 0);
        let aggr_weth = simple_map::borrow<string::String, address>(aggrs, &type_info::type_name<WETH>());
        assert!(aggr_weth == &@0x222AAA, 0);
        assert!(!simple_map::contains_key<string::String, address>(aggrs, &type_info::type_name<UNI>()), 0);
        assert!(!simple_map::contains_key<string::String, address>(aggrs, &type_info::type_name<USDT>()), 0);
    }
    #[test(owner = @leizd_aptos_external, account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_add_aggregator_with_not_owner(owner: &signer, account: &signer) acquires AggregatorStorage {
        initialize(owner);
        add_aggregator<USDC>(account, @0x111AAA);
    }
    #[test(owner = @leizd_aptos_external, usdc_aggr = @0x111AAA, weth_aggr = @0x222AAA)]
    fun test_end_to_end(owner: &signer, usdc_aggr: &signer, weth_aggr: &signer) acquires AggregatorStorage {
        aggregator::new_test(usdc_aggr, 2, 0, false);
        aggregator::new_test(weth_aggr, 3, 0, false);

        initialize(owner);
        add_aggregator<USDC>(owner, signer::address_of(usdc_aggr));
        add_aggregator<WETH>(owner, signer::address_of(weth_aggr));

        assert!(price_internal(signer::address_of(usdc_aggr)) == 2, 0);
        assert!(price_internal(signer::address_of(weth_aggr)) == 3, 0);
        assert!(price<USDC>() == 2, 0);
        assert!(price<WETH>() == 3, 0);
        assert!(price_of(&type_info::type_name<USDC>()) == 2, 0);
        assert!(price_of(&type_info::type_name<WETH>()) == 3, 0);
    }
    #[test_only] // for leizd-aptos-core
    public fun initialize_for_test(owner: &signer) {
        aggregator::new_test(owner, 1, 0, false); // TODO: changeable
        initialize(owner);
    }
    #[test_only] // for leizd-aptos-core
    public fun add_aggregator_for_test<C>(owner: &signer, aggregator_addr: address) acquires AggregatorStorage {
        add_aggregator<C>(owner, aggregator_addr);
    }
    #[test_only]
    fun initialize_with_fixed_price_for_test(owner: &signer) acquires AggregatorStorage {
        initialize_for_test(owner);
        let owner_address = signer::address_of(owner);
        add_aggregator<USDC>(owner, owner_address);
        add_aggregator<WETH>(owner, owner_address);
        add_aggregator<UNI>(owner, owner_address);
        add_aggregator<USDT>(owner, owner_address);
    }
    #[test(leizd = @leizd_aptos_external)]
    fun test_price_after_initialize_with_fixed_price_for_test(leizd: &signer) acquires AggregatorStorage {
        initialize_with_fixed_price_for_test(leizd);
        assert!(price<USDC>() == 1, 0);
        assert!(price<WETH>() == 1, 0);
        assert!(price<UNI>() == 1, 0);
        assert!(price<USDT>() == 1, 0);
    }
    #[test(leizd = @leizd_aptos_external)]
    fun test_price_of_after_initialize_with_fixed_price_for_test(leizd: &signer) acquires AggregatorStorage {
        initialize_with_fixed_price_for_test(leizd);
        assert!(price_of(&type_info::type_name<USDC>()) == 1, 0);
        assert!(price_of(&type_info::type_name<WETH>()) == 1, 0);
        assert!(price_of(&type_info::type_name<UNI>()) == 1, 0);
        assert!(price_of(&type_info::type_name<USDT>()) == 1, 0);
    }
}
