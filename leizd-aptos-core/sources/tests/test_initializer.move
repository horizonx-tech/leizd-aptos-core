#[test_only]
module leizd::test_initializer {

    use leizd_aptos_common::system_status;
    use leizd_aptos_common::test_coin;
    use leizd_aptos_common::pool_status;
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_trove::trove;
    use leizd_aptos_treasury::treasury;
    use leizd_aptos_external::price_oracle;
    use leizd_aptos_logic::risk_factor;
    use leizd_aptos_central_liquidity_pool::central_liquidity_pool;
    use leizd::interest_rate;

    /// Called only once by the owner.
    public fun initialize(owner: &signer) {
        system_status::initialize(owner);
        risk_factor::initialize(owner);
        treasury::initialize(owner);
        trove::initialize(owner);
        price_oracle::initialize(owner);
        central_liquidity_pool::initialize(owner);
        interest_rate::initialize(owner);
        pool_status::initialize(owner);
        permission::initialize(owner);
    }
    public fun initialize_price_oracle_with_fixed_price_for_test(owner: &signer) {
        price_oracle::register_oracle_with_fixed_price<test_coin::USDC>(owner, 999900000, 9, false);
        price_oracle::change_mode<test_coin::USDC>(owner, price_oracle::fixed_price_mode());
        price_oracle::register_oracle_with_fixed_price<test_coin::WETH>(owner, 1616370000000, 9, false);
        price_oracle::change_mode<test_coin::WETH>(owner, price_oracle::fixed_price_mode());
        price_oracle::register_oracle_with_fixed_price<test_coin::UNI>(owner, 7410000000, 9, false);
        price_oracle::change_mode<test_coin::UNI>(owner, price_oracle::fixed_price_mode());
        price_oracle::register_oracle_with_fixed_price<test_coin::USDT>(owner, 1000100000, 9, false);
        price_oracle::change_mode<test_coin::USDT>(owner, price_oracle::fixed_price_mode());
        price_oracle::register_oracle_with_fixed_price<test_coin::CoinDec10>(owner, 1000000000, 9, false);
        price_oracle::change_mode<test_coin::CoinDec10>(owner, price_oracle::fixed_price_mode());
        price_oracle::register_oracle_with_fixed_price<USDZ>(owner, 1000000000, 9, false);
        price_oracle::change_mode<USDZ>(owner, price_oracle::fixed_price_mode());
    }

    public fun update_price_oracle_with_fixed_one_dollar_to_all_for_test(owner: &signer) {
        update_price_oracle_with_fixed_one_dollar_for_test<test_coin::USDC>(owner);
        update_price_oracle_with_fixed_one_dollar_for_test<test_coin::WETH>(owner);
        update_price_oracle_with_fixed_one_dollar_for_test<test_coin::UNI>(owner);
        update_price_oracle_with_fixed_one_dollar_for_test<test_coin::USDT>(owner);
        update_price_oracle_with_fixed_one_dollar_for_test<test_coin::CoinDec10>(owner);
        update_price_oracle_with_fixed_one_dollar_for_test<USDZ>(owner);
    }

    public fun update_price_oracle_with_fixed_one_dollar_for_test<C>(owner: &signer) {
        price_oracle::update_fixed_price<C>(owner, 1000000000, 9, false);
        price_oracle::change_mode<C>(owner, price_oracle::fixed_price_mode());
    }

    public fun initialize_price_oracle_with_fixed_one_dollar_for_test<C>(owner: &signer) {
        price_oracle::register_oracle_with_fixed_price<C>(owner, 1000000000, 9, false);
        price_oracle::change_mode<C>(owner, price_oracle::fixed_price_mode());
    }
}
