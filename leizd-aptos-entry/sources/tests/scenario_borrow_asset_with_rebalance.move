#[test_only]
module leizd_aptos_entry::scenario_borrow_asset_with_rebalance {
    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::coin;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use leizd_aptos_lib::math64;
    #[test_only]
    use leizd_aptos_common::pool_type::{Asset, Shadow};
    #[test_only]
    use leizd_aptos_common::test_coin::{
        Self,
        USDC_DEC8 as USDC, // NOTE: caution. for simplified scenario testing
        USDT_DEC8 as USDT, // NOTE: caution. for simplified scenario testing
        WETH,
        UNI
    };
    #[test_only]
    use leizd_aptos_logic::risk_factor;
    #[test_only]
    use leizd_aptos_trove::usdz::{Self, USDZ};
    #[test_only]
    use leizd_aptos_core::account_position;
    #[test_only]
    use leizd_aptos_core::asset_pool;
    #[test_only]
    use leizd_aptos_core::shadow_pool;
    #[test_only]
    use leizd_aptos_common::coin_key::{key};
    #[test_only]
    use leizd_aptos_core::pool_manager;
    #[test_only]
    use leizd_aptos_core::initializer;
    #[test_only]
    use leizd_aptos_core::test_initializer;
    #[test_only]
    use leizd::money_market::{
        Self,
        deposit,
        borrow,
        borrow_asset_with_rebalance,
        borrow_unsafe_for_test,
        disable_to_rebalance,
    };

    #[test_only]
    public fun initialize_lending_pool_with_same_decimals_coins_for_test(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test(1648738800 * 1000 * 1000); // 20220401T00:00:00

        account::create_account_for_test(signer::address_of(owner));

        test_coin::init_usdc_dec8(owner);
        test_coin::init_usdt_dec8(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);

        // initialize
        initializer::initialize(owner);
        //// about all coins, one amount is one dollar
        test_initializer::initialize_price_oracle_with_fixed_one_dollar_for_test<USDC>(owner);
        test_initializer::initialize_price_oracle_with_fixed_one_dollar_for_test<USDT>(owner);
        test_initializer::initialize_price_oracle_with_fixed_one_dollar_for_test<WETH>(owner);
        test_initializer::initialize_price_oracle_with_fixed_one_dollar_for_test<UNI>(owner);
        test_initializer::initialize_price_oracle_with_fixed_one_dollar_for_test<USDZ>(owner);
        money_market::initialize(owner);

        // add_pool
        pool_manager::add_pool<USDC>(owner);
        pool_manager::add_pool<USDT>(owner);
        pool_manager::add_pool<WETH>(owner);
        pool_manager::add_pool<UNI>(owner);
    }
    #[test_only]
    public fun setup_account_for_test(account: &signer) {
        account::create_account_for_test(signer::address_of(account));
        managed_coin::register<USDC>(account);
        managed_coin::register<USDT>(account);
        managed_coin::register<WETH>(account);
        managed_coin::register<UNI>(account);
        managed_coin::register<USDZ>(account);
    }
    #[test_only]
    public fun setup_liquidity_provider_for_test(owner: &signer, account: &signer) {
        setup_account_for_test(account);

        let account_addr = signer::address_of(account);
        managed_coin::mint<USDC>(owner, account_addr, 999999 * math64::pow_10((coin::decimals<USDC>() as u64)));
        managed_coin::mint<USDT>(owner, account_addr, 999999 * math64::pow_10((coin::decimals<USDT>() as u64)));
        managed_coin::mint<WETH>(owner, account_addr, 999999 * math64::pow_10((coin::decimals<WETH>() as u64)));
        managed_coin::mint<UNI>(owner, account_addr, 999999 * math64::pow_10((coin::decimals<UNI>() as u64)));
        usdz::mint_for_test(account_addr, 9999999 * math64::pow_10((coin::decimals<USDZ>() as u64)));
    }

    #[test_only]
    public fun prepare_to_exec_borrow_asset_with_rebalance(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        initialize_lending_pool_with_same_decimals_coins_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);

        // prerequisite
        deposit<USDC, Asset>(lp, 500000, false);
        deposit<USDT, Asset>(lp, 500000, false);
        deposit<WETH, Asset>(lp, 500000, false);
        deposit<UNI, Asset>(lp, 500000, false);
        deposit<USDC, Shadow>(lp, 500000, false);
        deposit<USDT, Shadow>(lp, 500000, false);
        deposit<WETH, Shadow>(lp, 500000, false);
        deposit<UNI, Shadow>(lp, 500000, false);
    }

    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_1(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        usdz::mint_for_test(account_addr, 100000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<USDC, Shadow>(account, 100000, false);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 0, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(asset_pool::normal_deposited_share_to_amount(
            key<WETH>(),
            account_position::normal_deposited_asset_share<WETH>(account_addr)
        ) == 100000, 0);
        assert!(shadow_pool::normal_deposited_share_to_amount(
            key<USDC>(),
            account_position::normal_deposited_shadow_share<USDC>(account_addr)
        ) == 0, 0);
        assert!(shadow_pool::normal_deposited_share_to_amount(
            key<UNI>(),
            account_position::normal_deposited_shadow_share<UNI>(account_addr)
        ) == 100000, 0);

        assert!(asset_pool::borrowed_share_to_amount(
            key<UNI>(),
            account_position::borrowed_asset_share<UNI>(account_addr)
        ) == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_2(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        usdz::mint_for_test(account_addr, 100000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<USDC, Shadow>(account, 100000, false);
        borrow<USDC, Asset>(account, 50000);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 83334, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 16666, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) 
            + account_position::normal_deposited_shadow_share<UNI>(account_addr)
            + coin::balance<USDZ>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_3(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        usdz::mint_for_test(account_addr, 50000 - 10000 + 100000 + 10000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<WETH, Shadow>(account, 50000, false);
        borrow<WETH, Shadow>(account, 10000);
        deposit<USDC, Shadow>(account, 100000, false);
        borrow<USDC, Asset>(account, 50000);
        deposit<UNI, Shadow>(account, 10000, false);

        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 10050, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr) == 2, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 10050, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 133332, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 26666, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr)
            + account_position::normal_deposited_shadow_share<USDC>(account_addr) 
            + account_position::normal_deposited_shadow_share<UNI>(account_addr)
            + coin::balance<USDZ>(account_addr) == 160000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_4(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        usdz::mint_for_test(account_addr, 50000 - 10000 + 100000 + 10000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<WETH, Shadow>(account, 50000, false);
        borrow<WETH, Shadow>(account, 10000);
        disable_to_rebalance<WETH>(account);
        deposit<USDC, Shadow>(account, 100000, false);
        borrow<USDC, Asset>(account, 50000);
        deposit<UNI, Shadow>(account, 10000, false);

        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 10050, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 10050, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 91668, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 18332, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr)
            + account_position::normal_deposited_shadow_share<UNI>(account_addr)
            + coin::balance<USDZ>(account_addr) == 110000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_5__adjust_three_with_normal_only(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 300000);
        deposit<WETH, Shadow>(account, 100000, false);
        borrow<WETH, Asset>(account, 20000);
        deposit<USDC, Shadow>(account, 100000, false);
        borrow<USDC, Asset>(account, 45000);
        deposit<USDT, Shadow>(account, 100000, false);
        borrow<USDT, Asset>(account, 70000);
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 100000, 0);
        assert!(coin::balance<WETH>(account_addr) == 20000, 0);
        assert!(coin::balance<USDC>(account_addr) == 45000, 0);
        assert!(coin::balance<USDT>(account_addr) == 70000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 15000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr) == 40000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 90000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 140000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 30000, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr)
            + account_position::normal_deposited_shadow_share<USDC>(account_addr) 
            + account_position::normal_deposited_shadow_share<USDT>(account_addr) 
            + account_position::normal_deposited_shadow_share<UNI>(account_addr)
            + coin::balance<USDZ>(account_addr) == 300000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_5__adjust_three_with_conly_only(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 300000);
        deposit<WETH, Shadow>(account, 100000, true);
        borrow<WETH, Asset>(account, 20000);
        deposit<USDC, Shadow>(account, 100000, true);
        borrow<USDC, Asset>(account, 45000);
        deposit<USDT, Shadow>(account, 100000, true);
        borrow<USDT, Asset>(account, 70000);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 100000, 0);
        assert!(coin::balance<WETH>(account_addr) == 20000, 0);
        assert!(coin::balance<USDC>(account_addr) == 45000, 0);
        assert!(coin::balance<USDT>(account_addr) == 70000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 15000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 40000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 90000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 140000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 30000, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr)
            + account_position::conly_deposited_shadow_share<USDC>(account_addr) 
            + account_position::conly_deposited_shadow_share<USDT>(account_addr) 
            + account_position::normal_deposited_shadow_share<UNI>(account_addr)
            + coin::balance<USDZ>(account_addr) == 300000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_5__adjust_three_with_normal_and_conly(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 300000);
        deposit<WETH, Shadow>(account, 100000, true);
        borrow<WETH, Asset>(account, 20000);
        deposit<USDC, Shadow>(account, 100000, false);
        borrow<USDC, Asset>(account, 45000);
        deposit<USDT, Shadow>(account, 100000, true);
        borrow<USDT, Asset>(account, 70000);
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 100000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 100000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 15000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 40000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 90000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 140000, 0);

        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 30000, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr)
            + account_position::normal_deposited_shadow_share<USDC>(account_addr) 
            + account_position::conly_deposited_shadow_share<USDT>(account_addr) 
            + account_position::normal_deposited_shadow_share<UNI>(account_addr)
            + coin::balance<USDZ>(account_addr) == 300000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_6(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        usdz::mint_for_test(account_addr, 300000);
        deposit<WETH, Shadow>(account, 150000, true);
        borrow<WETH, Asset>(account, 20000);
        deposit<USDC, Shadow>(account, 95000, false);
        borrow<USDC, Asset>(account, 45000);
        deposit<USDT, Shadow>(account, 45000, true);
        borrow_unsafe_for_test<USDT, Asset>(account, 70000);
        deposit<UNI, Shadow>(account, 10000, false);
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 150000, 0);
        assert!(account_position::borrowed_asset_share<WETH>(account_addr) == 20000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 95000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 45000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 45000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 70000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 10000, 0);
        assert!(account_position::conly_deposited_shadow_share<UNI>(account_addr) == 0, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 15000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr) == 40000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 90000, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<USDT>(account_addr) == 140000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 30000, 0);
        assert!(account_position::conly_deposited_shadow_share<UNI>(account_addr) == 0, 0);

        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<UNI>(account_addr) == 15000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        //// for pool
        let liquidity_from_lp = 500000;
        assert!(shadow_pool::normal_deposited_amount<WETH>() - liquidity_from_lp == 0, 0);
        assert!(shadow_pool::conly_deposited_amount<WETH>() == 40000, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 20000, 0);
        assert!(shadow_pool::normal_deposited_amount<USDC>() - liquidity_from_lp == 90000, 0);
        assert!(shadow_pool::conly_deposited_amount<USDC>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<USDC>() == 45000, 0);
        assert!(shadow_pool::normal_deposited_amount<USDT>() - liquidity_from_lp == 0, 0);
        assert!(shadow_pool::conly_deposited_amount<USDT>() == 140000, 0);
        assert!(asset_pool::total_borrowed_amount<USDT>() == 70000, 0);
        assert!(shadow_pool::normal_deposited_amount<UNI>() - liquidity_from_lp == 30000, 0);
        assert!(shadow_pool::conly_deposited_amount<UNI>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<UNI>() == 15000, 0);
        assert!(account_position::conly_deposited_shadow_share<WETH>(account_addr)
            + account_position::normal_deposited_shadow_share<USDC>(account_addr) 
            + account_position::conly_deposited_shadow_share<USDT>(account_addr) 
            + account_position::normal_deposited_shadow_share<UNI>(account_addr)
            + coin::balance<USDZ>(account_addr) == 300000, 0);
    }

    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_0(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        let account_addr = signer::address_of(account);

        // execute
        managed_coin::mint<WETH>(owner, account_addr, 20000);
        deposit<WETH, Asset>(account, 20000, false);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 20000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);

        borrow_asset_with_rebalance<USDC>(account, 12600);

        // check
        //// ltv is...
        assert!(risk_factor::ltv<WETH>() == risk_factor::precision() / 100 * 70, 0); // 70%
        assert!(risk_factor::ltv_of_shadow() == risk_factor::precision() / 100 * 90, 0); // 90%
        //// 20000 * 70% = 14000 <- borrowing Shadow
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 20000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 14000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 14000, 0);
        //// 14000 * 90% = 12600 <- borrowable Asset from borrowing Shadow
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 12600, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_0_when_over_borrowable_amount(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        let account_addr = signer::address_of(account);

        // execute
        managed_coin::mint<WETH>(owner, account_addr, 20000);
        deposit<WETH, Asset>(account, 20000, false);
        assert!(risk_factor::ltv<WETH>() == risk_factor::precision() / 100 * 70, 0); // 70%
        assert!(risk_factor::ltv_of_shadow() == risk_factor::precision() / 100 * 90, 0); // 90%
        borrow_asset_with_rebalance<USDC>(account, 20000 * 70 / 100 * 90 / 100 + 1);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_1(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        deposit<WETH, Asset>(account, 100000, false);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 11111, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 11111, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr)
            + coin::balance<USDZ>(account_addr)
            == account_position::borrowed_shadow_share<WETH>(account_addr), 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_2(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<USDC, Asset>(account, 50000, false);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 7407, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 3703, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 11110, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr)
            + coin::balance<USDZ>(account_addr)
            == (account_position::borrowed_shadow_share<WETH>(account_addr)
            + account_position::borrowed_shadow_share<USDC>(account_addr)), 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_2_with_fee(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        deposit<USDC, Asset>(account, 50000, false);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_amount_with(key<WETH>(), account_addr) == 7499, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_amount_with(key<USDC>(), account_addr) == 3740, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 11164, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
        // TODO: important to check
        // assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr)
        //     == (account_position::borrowed_shadow_share<WETH>(account_addr)
        //     + account_position::borrowed_shadow_share<USDC>(account_addr)), 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_3(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        // usdz::mint_for_test(account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        borrow<WETH, Shadow>(account, 9000);
        deposit<USDC, Asset>(account, 50000, false);
        // deposit<USDT, Shadow>(account, 50000, false);
        // borrow<USDT, Asset>(account, 47500);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 9000, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        // assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        // assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 47500, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        // assert!(coin::balance<USDT>(account_addr) == 47500, 0);
        assert!(coin::balance<USDZ>(account_addr) == 9000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 13407, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 6703, 0); // -> 6704 ?
        // assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 0, 0);
        // assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 11110, 0); // -> 11111 ?
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        // assert!(coin::balance<USDT>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == 9000, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_4(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        usdz::mint_for_test(account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        borrow<WETH, Shadow>(account, 50000);
        deposit<USDC, Asset>(account, 50000, false);
        deposit<USDT, Shadow>(account, 50000, false);
        borrow_unsafe_for_test<USDT, Asset>(account, 45000);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 45000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 45000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 40740, 0); // -> 40741
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 20370, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 45000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 11110, 0); // -> 11111
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 45000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr)
            + account_position::normal_deposited_shadow_share<UNI>(account_addr)
            == (account_position::borrowed_shadow_share<WETH>(account_addr)
            + account_position::borrowed_shadow_share<USDC>(account_addr)), 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_5(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        usdz::mint_for_test(account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        borrow<WETH, Shadow>(account, 50000);
        deposit<USDC, Asset>(account, 50000, false);
        deposit<USDT, Shadow>(account, 50000, false);
        borrow<USDT, Asset>(account, 40000);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 40740, 0); // -> 40741
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 20370, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 48888, 0); // -> 48889
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 40000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 12222, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);

        //// for pool
        let liquidity_from_lp = 500000;
        ////// AssetToShadow
        assert!(asset_pool::total_normal_deposited_amount<WETH>() - liquidity_from_lp == 100000, 0);
        assert!(asset_pool::total_conly_deposited_amount<WETH>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 40740, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() - liquidity_from_lp == 50000, 0);
        assert!(asset_pool::total_conly_deposited_amount<USDC>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == 20370, 0);
        ////// ShadowToAsset
        assert!(shadow_pool::normal_deposited_amount<USDT>() - liquidity_from_lp == 48888, 0);
        assert!(shadow_pool::conly_deposited_amount<USDT>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<USDT>() == 40000, 0);
        assert!(shadow_pool::normal_deposited_amount<UNI>() - liquidity_from_lp == 12222, 0);
        assert!(shadow_pool::conly_deposited_amount<UNI>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<UNI>() == 10000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_6(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        usdz::mint_for_test(account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        borrow<WETH, Shadow>(account, 50000);
        deposit<USDC, Asset>(account, 50000, false);
        deposit<USDT, Shadow>(account, 50000, false);
        borrow<USDT, Asset>(account, 40000);
        disable_to_rebalance<WETH>(account);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 11111, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 48889, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 40000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 12222, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 40000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr)
            == ((50000 - account_position::normal_deposited_shadow_share<USDT>(account_addr)) // withdrawn amount
            + account_position::borrowed_shadow_share<USDC>(account_addr)), 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__borrow_and_deposit_7(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);

        // prerequisite
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000);
        managed_coin::mint<USDC>(owner, account_addr, 50000);
        usdz::mint_for_test(account_addr, 50000);
        deposit<WETH, Asset>(account, 100000, false);
        borrow<WETH, Shadow>(account, 50000);
        deposit<USDC, Asset>(account, 50000, false);
        deposit<USDT, Shadow>(account, 50000, false);
        borrow_unsafe_for_test<USDT, Asset>(account, 50000);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 50000, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 50000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 40740, 0);
        assert!(account_position::normal_deposited_asset_share<USDC>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 20370, 0);
        assert!(account_position::normal_deposited_shadow_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_asset_share<USDT>(account_addr) == 50000, 0);
        assert!(account_position::borrowed_shadow_share<USDT>(account_addr) == 1, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) == 11111, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 0, 0);
        assert!(coin::balance<USDT>(account_addr) == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) == 50000, 0);
        assert!(coin::balance<UNI>(account_addr) == 10000, 0);
        assert!((50000 - account_position::borrowed_shadow_share<WETH>(account_addr)) + account_position::normal_deposited_shadow_share<UNI>(account_addr)
            == (account_position::borrowed_shadow_share<USDT>(account_addr)
            + account_position::borrowed_shadow_share<USDC>(account_addr)), 0);
    }
}

// use correct decimals
#[test_only]
module leizd_aptos_entry::scenario_borrow_asset_with_rebalance__with_correct_decimals_coins {
    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::coin;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use leizd_aptos_lib::math64;
    #[test_only]
    use leizd_aptos_common::pool_type::{Asset, Shadow};
    #[test_only]
    use leizd_aptos_common::test_coin::{
        Self,
        USDC,
        USDT,
        WETH,
        UNI
    };
    #[test_only]
    use leizd_aptos_trove::usdz::{Self, USDZ};
    #[test_only]
    use leizd_aptos_core::account_position;
    #[test_only]
    use leizd_aptos_core::pool_manager;
    #[test_only]
    use leizd_aptos_core::initializer;
    #[test_only]
    use leizd_aptos_core::test_initializer;
    #[test_only]
    use leizd::money_market::{
        Self,
        deposit,
        borrow,
        borrow_asset_with_rebalance,
    };
    #[test_only]
    public fun initialize_lending_pool_for_test(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test(1648738800 * 1000 * 1000); // 20220401T00:00:00

        account::create_account_for_test(signer::address_of(owner));

        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);

        // initialize
        initializer::initialize(owner);
        //// about all coins, one amount is one dollar
        test_initializer::initialize_price_oracle_with_fixed_one_dollar_for_test<USDC>(owner);
        test_initializer::initialize_price_oracle_with_fixed_one_dollar_for_test<USDT>(owner);
        test_initializer::initialize_price_oracle_with_fixed_one_dollar_for_test<WETH>(owner);
        test_initializer::initialize_price_oracle_with_fixed_one_dollar_for_test<UNI>(owner);
        test_initializer::initialize_price_oracle_with_fixed_one_dollar_for_test<USDZ>(owner);
        money_market::initialize(owner);

        // add_pool
        pool_manager::add_pool<USDC>(owner);
        pool_manager::add_pool<USDT>(owner);
        pool_manager::add_pool<WETH>(owner);
        pool_manager::add_pool<UNI>(owner);
    }
    #[test_only]
    public fun setup_account_for_test(account: &signer) {
        account::create_account_for_test(signer::address_of(account));
        managed_coin::register<USDC>(account);
        managed_coin::register<USDT>(account);
        managed_coin::register<WETH>(account);
        managed_coin::register<UNI>(account);
        managed_coin::register<USDZ>(account);
    }
    #[test_only]
    public fun setup_liquidity_provider_for_test(owner: &signer, account: &signer) {
        setup_account_for_test(account);

        let account_addr = signer::address_of(account);
        managed_coin::mint<USDC>(owner, account_addr, 999999 * math64::pow_10((coin::decimals<USDC>() as u64)));
        managed_coin::mint<USDT>(owner, account_addr, 999999 * math64::pow_10((coin::decimals<USDT>() as u64)));
        managed_coin::mint<WETH>(owner, account_addr, 999999 * math64::pow_10((coin::decimals<WETH>() as u64)));
        managed_coin::mint<UNI>(owner, account_addr, 999999 * math64::pow_10((coin::decimals<UNI>() as u64)));
        usdz::mint_for_test(account_addr, 9999999 * math64::pow_10((coin::decimals<USDZ>() as u64)));
    }

    #[test_only]
    public fun prepare_to_exec_borrow_asset_with_rebalance(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(account);

        // prerequisite
        let dec6 = math64::pow_10(6);
        let dec8 = math64::pow_10(8);
        deposit<USDC, Asset>(lp, 500000 * dec6, false);
        deposit<USDT, Asset>(lp, 500000 * dec6, false);
        deposit<WETH, Asset>(lp, 500000 * dec8, false);
        deposit<UNI, Asset>(lp, 500000 * dec8, false);
        deposit<USDC, Shadow>(lp, 500000 * dec8, false);
        deposit<USDT, Shadow>(lp, 500000 * dec8, false);
        deposit<WETH, Shadow>(lp, 500000 * dec8, false);
        deposit<UNI, Shadow>(lp, 500000 * dec8, false);
    }

    #[test(owner=@leizd_aptos_entry,lp=@0x111,account=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_asset_with_rebalance__optimize_shadow_2(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_borrow_asset_with_rebalance(owner, lp, account, aptos_framework);
        let dec6 = math64::pow_10(6);
        let dec8 = math64::pow_10(8);

        // prerequisite
        let account_addr = signer::address_of(account);
        managed_coin::mint<WETH>(owner, account_addr, 100000 * dec8);
        usdz::mint_for_test(account_addr, 100000 * dec8);
        deposit<WETH, Asset>(account, 100000 * dec8, false);
        deposit<USDC, Shadow>(account, 100000 * dec8, false);
        borrow<USDC, Asset>(account, 50000 * dec6);
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) == 100000 * dec8, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) == 100000 * dec8, 0);
        assert!(account_position::borrowed_asset_share<USDC>(account_addr) == 50250 * dec6, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) == 50000 * dec6, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);

        // execute
        borrow_asset_with_rebalance<UNI>(account, 10000 * dec8);

        // check
        // NOTE: `share` value is equal to `amount` value in this situation
        assert!(account_position::normal_deposited_asset_share<WETH>(account_addr) / dec8 == 100000, 0);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account_addr) / dec8 == 83333, 0);
        assert!(account_position::normal_deposited_shadow_share<UNI>(account_addr) / dec8 == 16666, 0);
        assert!(account_position::borrowed_asset_share<UNI>(account_addr) / dec8 == 10050, 0);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(coin::balance<USDC>(account_addr) / dec6 == 50000, 0);
        assert!(coin::balance<USDZ>(account_addr) / dec8 == 0, 0);
        assert!(coin::balance<UNI>(account_addr) / dec8 == 10000, 0);
        assert!((account_position::normal_deposited_shadow_share<USDC>(account_addr)
            + account_position::normal_deposited_shadow_share<UNI>(account_addr)
            + coin::balance<USDZ>(account_addr)) / dec8 == 100000, 0);
    }
}
