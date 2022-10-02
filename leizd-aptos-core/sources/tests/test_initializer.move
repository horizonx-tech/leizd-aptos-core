#[test_only]
module leizd::test_initializer {

    use std::signer;
    use leizd_aptos_common::system_status;
    use leizd_aptos_trove::trove_manager;
    use leizd_aptos_treasury::treasury;
    use leizd_aptos_external::price_oracle;
    use leizd_aptos_logic::risk_factor;
    use leizd::stability_pool;
    use leizd::test_coin;

    /// Called only once by the owner.
    public entry fun initialize(owner: &signer) {
        system_status::initialize(owner);
        risk_factor::initialize(owner);
        treasury::initialize(owner);
        trove_manager::initialize(owner);
        stability_pool::initialize(owner);
    }
    public entry fun initialize_price_oracle_with_fixed_price_for_test(owner: &signer) {
        price_oracle::initialize_for_test(owner, 1, 0);
        let owner_address = signer::address_of(owner);
        price_oracle::add_aggregator_for_test<test_coin::USDC>(owner, owner_address);
        price_oracle::add_aggregator_for_test<test_coin::WETH>(owner, owner_address);
        price_oracle::add_aggregator_for_test<test_coin::UNI>(owner, owner_address);
        price_oracle::add_aggregator_for_test<test_coin::USDT>(owner, owner_address);
    }
}
