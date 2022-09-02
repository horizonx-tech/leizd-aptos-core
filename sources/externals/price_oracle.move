module leizd::price_oracle {

    use std::string;
    use switchboard::aggregator;
    use switchboard::math;

    fun price_internal(aggregator: address): u128 {
        let latest_value = aggregator::latest_value(aggregator);
        let (value, _, _) = math::unpack(latest_value);
        value / math::pow_10(9) // temp
    }

    public fun price<C>(): u64 {
        (price_internal(@leizd) as u64) // TOOD: convert type_args to address
    }

    public fun price_of(name: &string::String): u64 {
        name;
        (price_internal(@leizd) as u64) // TOOD: convert name(type_name) to address
    }

    public fun volume(name: &string::String, amount: u64): u64 {
        amount * price_of(name)
    }

    public fun amount(name: &string::String, volume: u64): u64 {
        volume / price_of(name)
    }

    #[test_only]
    use aptos_std::type_info;
    #[test_only]
    use leizd::test_coin;
    #[test_only]
    public fun initialize_oracle_for_test(owner: &signer) {
        aggregator::new_test(owner, 1, 0, false);
    }
    #[test(leizd = @leizd)]
    fun test_price(leizd: &signer) {
        initialize_oracle_for_test(leizd);
        assert!(price<test_coin::USDC>() == 1, 0);
        assert!(price<test_coin::WETH>() == 1, 0);
        assert!(price<test_coin::UNI>() == 1, 0);
        assert!(price<test_coin::USDT>() == 1, 0);
    }
    #[test(leizd = @leizd)]
    fun test_price_of(leizd: &signer) {
        initialize_oracle_for_test(leizd);
        assert!(price_of(&type_info::type_name<test_coin::USDC>()) == 1, 0);
        assert!(price_of(&type_info::type_name<test_coin::WETH>()) == 1, 0);
        assert!(price_of(&type_info::type_name<test_coin::UNI>()) == 1, 0);
        assert!(price_of(&type_info::type_name<test_coin::USDT>()) == 1, 0);
    }
}