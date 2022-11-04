#[test_only]
module leizd_aptos_entry::scenario {

    use std::signer;
    use std::vector;
    use std::unit_test;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::managed_coin;
    use aptos_framework::timestamp;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::pool_type::{Asset, Shadow};
    use leizd_aptos_common::position_type::{AssetToShadow, ShadowToAsset};
    use leizd_aptos_common::test_coin::{Self,USDC,USDT,WETH,UNI};
    use leizd_aptos_trove::usdz::{Self, USDZ};
    use leizd_aptos_logic::risk_factor;
    use leizd_aptos_core::interest_rate;
    use leizd_aptos_core::asset_pool;
    use leizd_aptos_core::shadow_pool;
    use leizd_aptos_core::pool_manager;
    use leizd_aptos_core::account_position;
    use leizd_aptos_core::test_initializer;
    use leizd_aptos_entry::money_market;
    use leizd_aptos_entry::initializer;
    use leizd_aptos_external::price_oracle;

    #[test_only]
    public fun initialize_signer_for_test(num_signers: u64): vector<signer> {
        let signers = unit_test::create_signers_for_testing(num_signers);

        let i = vector::length<signer>(&signers);
        while (i > 0) {
            let account = vector::borrow(&signers, i - 1);
            account::create_account_for_test(signer::address_of(account));
            register_all_coins(account);
            i = i - 1;
        };

        signers
    }
    #[test_only]
    public fun borrow_account(accounts: &vector<signer>, index: u64): (&signer, address) {
        let account = vector::borrow(accounts, index);
        (account, signer::address_of(account))
    }
    #[test_only]
    public fun initialize_scenario(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test(1648738800 * 1000 * 1000); // 20220401T00:00:00

        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);

        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        test_coin::init_coin_dec_10(owner);

        initializer::initialize(owner);
        money_market::initialize(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    }
    #[test_only]
    public fun register_all_coins(account: &signer) {
        managed_coin::register<USDC>(account);
        managed_coin::register<USDT>(account);
        managed_coin::register<WETH>(account);
        managed_coin::register<UNI>(account);
        managed_coin::register<USDZ>(account);
    }
    #[test_only]
    public fun mint_all(owner: &signer, account_addr: address, amount: u64) {
        managed_coin::mint<WETH>(owner, account_addr, amount);
        managed_coin::mint<USDT>(owner, account_addr, amount);
        managed_coin::mint<WETH>(owner, account_addr, amount);
        managed_coin::mint<UNI>(owner, account_addr, amount);
        usdz::mint_for_test(account_addr, amount);
    }

    /* check to earn interest
        NOTE:
            no interest rate calculation by interest_rate module
            no time consideration (not use timestamp) */
    // TODO: scale amount's unit to standard decimals
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_can_earn_interest_about_asset_by_withdrawing_after_depositing_except_interest_rate_calculation(owner: &signer, aptos_framework: &signer) {
        // prepares
        initialize_scenario(owner, aptos_framework);
        let signers = initialize_signer_for_test(2);
        let (account1, account1_addr) = borrow_account(&signers, 0);
        managed_coin::mint<WETH>(owner, account1_addr, 300000);
        usdz::mint_for_test(account1_addr, 10000000);
        let (account2, account2_addr) = borrow_account(&signers, 1);
        managed_coin::mint<WETH>(owner, account2_addr, 100000);
        usdz::mint_for_test(account2_addr, 10000000);
        pool_manager::add_pool<WETH>(owner);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        // deposit & borrow
        money_market::deposit<WETH, Asset>(account1, 300000, false);
        money_market::deposit<WETH, Shadow>(account1, 10000000, false); // as collateral
        money_market::borrow<WETH, Asset>(account1, 125);
        money_market::deposit<WETH, Asset>(account2, 100000, false);
        money_market::deposit<WETH, Shadow>(account2, 10000000, false); // as collateral
        money_market::borrow<WETH, Asset>(account2, 375);
        assert!(coin::balance<WETH>(account1_addr) == 125, 0);
        assert!(coin::balance<WETH>(account2_addr) == 375, 0);

        // earn interest
        asset_pool::earn_interest_without_using_interest_rate_module_for_test<WETH>(
            ((interest_rate::precision() / 1000 * 800) as u128) // 80%
        );

        let weth_key = key<WETH>();
        assert!(account_position::deposited_volume<AssetToShadow>(account1_addr, key<WETH>()) == price_oracle::volume(&weth_key, 300000 + 300), 0);
        assert!(account_position::deposited_volume<AssetToShadow>(account2_addr, key<WETH>()) == price_oracle::volume(&weth_key, 100000 + 100), 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(account1_addr, key<WETH>()) == price_oracle::volume(&weth_key, 125 + 100), 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(account1_addr, key<WETH>()) == 0, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(account2_addr, key<WETH>()) == price_oracle::volume(&weth_key, 375 + 300), 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(account2_addr, key<WETH>()) == 0, 0);

        // withdraw
        money_market::withdraw<WETH, Asset>(account1, 110000);
        assert!(account_position::deposited_volume<AssetToShadow>(account1_addr, key<WETH>()) == price_oracle::volume(&weth_key, 300300 - 110000 - 1), 0);
        assert!(coin::balance<WETH>(account1_addr) == 125 + 110000, 0);
        // repay
        money_market::repay<WETH, Asset>(account1, 125);
        assert!(account_position::borrowed_volume<ShadowToAsset>(account1_addr, key<WETH>()) == price_oracle::volume(&weth_key, 100 - 1), 0);
        assert!(coin::balance<WETH>(account1_addr) == 125 + 110000 - 125, 0);
    }
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_can_earn_interest_about_shadow_by_withdrawing_after_depositing_except_interest_rate_calculation(owner: &signer, aptos_framework: &signer) {
        // prepares
        initialize_scenario(owner, aptos_framework);
        let signers = initialize_signer_for_test(2);
        let (account1, account1_addr) = borrow_account(&signers, 0);
        usdz::mint_for_test(account1_addr, 300000);
        managed_coin::mint<WETH>(owner, account1_addr, 100000);
        let (account2, account2_addr) = borrow_account(&signers, 1);
        usdz::mint_for_test(account2_addr, 100000);
        managed_coin::mint<WETH>(owner, account2_addr, 100000);
        pool_manager::add_pool<WETH>(owner);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share

        // deposit & borrow
        money_market::deposit<WETH, Shadow>(account1, 300000, false);
        money_market::deposit<WETH, Asset>(account1, 100000, false); // as collateral
        money_market::borrow<WETH, Shadow>(account1, 12500);
        money_market::deposit<WETH, Shadow>(account2, 100000, false);
        money_market::deposit<WETH, Asset>(account2, 100000, false); // as collateral
        money_market::borrow<WETH, Shadow>(account2, 37500);
        assert!(coin::balance<USDZ>(account1_addr) == 12500, 0);
        assert!(coin::balance<USDZ>(account2_addr) == 37500, 0);

        // earn interest
        shadow_pool::earn_interest_without_using_interest_rate_module_for_test<WETH>(
            ((interest_rate::precision() / 1000 * 800) as u128) // 80%
        );
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 400000 + 40000, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 50000 + 40000, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(account1_addr, key<WETH>()) == 300000 + 30000, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(account2_addr, key<WETH>()) == 100000 + 10000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(account1_addr, key<WETH>()) == 12500 + 10000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(account1_addr, key<WETH>()) == 0, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(account2_addr, key<WETH>()) == 37500 + 30000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(account2_addr, key<WETH>()) == 0, 0);

        // withdraw
        money_market::withdraw<WETH, Shadow>(account1, 110000);
        assert!(account_position::deposited_volume<ShadowToAsset>(account1_addr, key<WETH>()) == 220000, 0);
        assert!(coin::balance<USDZ>(account1_addr) == 12500 + 110000, 0);
        // repay
        money_market::repay<WETH, Shadow>(account1, 5625);
        assert!(account_position::borrowed_volume<AssetToShadow>(account1_addr, key<WETH>()) == 16875, 0);
        assert!(coin::balance<USDZ>(account1_addr) == 12500 + 110000 - 5625, 0);
    }
}