#[test_only]
module leizd::test_initializer {

    use leizd_aptos_common::system_status;
    use leizd_aptos_common::test_coin;
    use leizd_aptos_common::pool_status;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_trove::trove_manager;
    use leizd_aptos_treasury::treasury;
    use leizd_aptos_external::price_oracle;
    use leizd_aptos_logic::risk_factor;
    use leizd_aptos_central_liquidity_pool::central_liquidity_pool;
    use leizd::interest_rate;

    /// Called only once by the owner.
    public entry fun initialize(owner: &signer) {
        system_status::initialize(owner);
        risk_factor::initialize(owner);
        treasury::initialize(owner);
        trove_manager::initialize(owner);
        price_oracle::initialize(owner);
        central_liquidity_pool::initialize(owner);
        interest_rate::initialize(owner);
        pool_status::initialize(owner);
    }
    public entry fun initialize_price_oracle_with_fixed_price_for_test(owner: &signer) {
        price_oracle::register_oracle_with_fixed_price<test_coin::USDC>(owner, 1000000000, 9, false);
        price_oracle::change_mode<test_coin::USDC>(owner, price_oracle::fixed_price_mode());
        price_oracle::register_oracle_with_fixed_price<test_coin::WETH>(owner, 1000000000, 9, false);
        price_oracle::change_mode<test_coin::WETH>(owner, price_oracle::fixed_price_mode());
        price_oracle::register_oracle_with_fixed_price<test_coin::UNI>(owner, 1000000000, 9, false);
        price_oracle::change_mode<test_coin::UNI>(owner, price_oracle::fixed_price_mode());
        price_oracle::register_oracle_with_fixed_price<test_coin::USDT>(owner, 1000000000, 9, false);
        price_oracle::change_mode<test_coin::USDT>(owner, price_oracle::fixed_price_mode());
        price_oracle::register_oracle_with_fixed_price<USDZ>(owner, 1000000000, 9, false); // TODO: check that why is it necessary
        price_oracle::change_mode<USDZ>(owner, price_oracle::fixed_price_mode());
    }
}
