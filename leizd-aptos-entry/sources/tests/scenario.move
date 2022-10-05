#[test_only]
module leizd_aptos_entry::scenario {

    use std::signer;
    use std::vector;
    use std::unit_test;
    use aptos_std::debug;
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
    use leizd_aptos_core::pool_manager;
    use leizd_aptos_core::account_position;
    use leizd_aptos_entry::money_market;
    use leizd_aptos_entry::initializer;

    #[test_only]
    fun initialize_signer_for_test(num_signers: u64): vector<signer> {
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
    fun borrow_account(accounts: &vector<signer>, index: u64): (&signer, address) {
        let account = vector::borrow(accounts, index);
        (account, signer::address_of(account))
    }
    #[test_only]
    fun initialize_scenario(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test(1648738800 * 1000 * 1000); // 20220401T00:00:00

        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);

        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);

        initializer::initialize(owner);
        money_market::initialize(owner);
    }
    #[test_only]
    fun register_all_coins(account: &signer) {
        managed_coin::register<USDC>(account);
        managed_coin::register<USDT>(account);
        managed_coin::register<WETH>(account);
        managed_coin::register<UNI>(account);
        managed_coin::register<USDZ>(account);
    }
    #[test_only]
    fun mint_all(owner: &signer, account_addr: address, amount: u64) {
        managed_coin::mint<WETH>(owner, account_addr, amount);
        managed_coin::mint<USDT>(owner, account_addr, amount);
        managed_coin::mint<WETH>(owner, account_addr, amount);
        managed_coin::mint<UNI>(owner, account_addr, amount);
        usdz::mint_for_test(account_addr, amount);
    }

    /* check to earn interest
        deposit -> withdraw
        NOTE:
            no interest rate calculation by interest_rate module
            no time consideration (not use timestamp) */
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_can_earn_interest_by_withdrawing_after_depositing_except_interest_rate_calculation(owner: &signer, aptos_framework: &signer) {
        initialize_scenario(owner, aptos_framework);
        let signers = initialize_signer_for_test(3);
        // let (lp, lp_addr) = borrow_account(&signers, 0);
        // mint_all(owner, lp_addr, 999999);
        let (account1, account1_addr) = borrow_account(&signers, 1);
        managed_coin::mint<WETH>(owner, account1_addr, 500000);
        usdz::mint_for_test(account1_addr, 100000);
        let (account2, account2_addr) = borrow_account(&signers, 2);
        managed_coin::mint<WETH>(owner, account2_addr, 500000);
        usdz::mint_for_test(account2_addr, 100000);
        pool_manager::add_pool<WETH>(owner);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calcurate borrowed amount/share

        money_market::deposit<WETH, Asset>(account1, 300000, false);
        money_market::deposit<WETH, Shadow>(account1, 100000, false); // as collateral
        money_market::borrow<WETH, Asset>(account1, 12500);
        money_market::deposit<WETH, Asset>(account2, 100000, false);
        money_market::deposit<WETH, Shadow>(account2, 100000, false); // as collateral
        money_market::borrow<WETH, Asset>(account2, 37500);

        asset_pool::earn_interest_without_using_interest_rate_module_for_test<WETH>(
            ((interest_rate::precision() / 1000 * 800) as u128) // 80%
        );

        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 400000 + 40000, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 50000 + 40000, 0);
        assert!(account_position::deposited_volume<AssetToShadow>(account1_addr, key<WETH>()) == 300000 + 30000, 0);
        assert!(account_position::deposited_volume<AssetToShadow>(account2_addr, key<WETH>()) == 100000 + 10000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(account1_addr, key<WETH>()) == 12500 + 10000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(account1_addr, key<WETH>()) == 0, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(account2_addr, key<WETH>()) == 37500 + 30000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(account2_addr, key<WETH>()) == 0, 0);
    }
}