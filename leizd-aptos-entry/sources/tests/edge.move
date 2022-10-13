#[test_only]
module leizd_aptos_entry::edge {

    use aptos_framework::coin;
    use aptos_framework::managed_coin;
    use leizd_aptos_lib::constant;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::pool_type::{Asset, Shadow};
    use leizd_aptos_common::test_coin::{WETH, USDC};
    use leizd_aptos_common::position_type::{AssetToShadow, ShadowToAsset};
    use leizd_aptos_logic::risk_factor;
    use leizd_aptos_trove::usdz::{Self, USDZ};
    use leizd_aptos_core::pool_manager;
    use leizd_aptos_core::account_position;
    use leizd_aptos_entry::money_market;
    use leizd_aptos_entry::scenario;

    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_deposit_asset_with_u64_except_interest_rate(owner: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let signers = scenario::initialize_signer_for_test(2);
        let (account1, account1_addr) = scenario::borrow_account(&signers, 0);
        let max = constant::u64_max();
        managed_coin::mint<WETH>(owner, account1_addr, max);
        pool_manager::add_pool<WETH>(owner);

        // deposit & borrow
        money_market::deposit<WETH, Asset>(account1, max, false);
        assert!(account_position::deposited_volume<AssetToShadow>(account1_addr, key<WETH>()) == (max as u128), 0);
        assert!(coin::balance<WETH>(account1_addr) == 0, 0);
    }
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_deposit_shadow_with_u64_except_interest_rate(owner: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let signers = scenario::initialize_signer_for_test(2);
        let (account1, account1_addr) = scenario::borrow_account(&signers, 0);
        let max = constant::u64_max();
        usdz::mint_for_test(account1_addr, max);
        pool_manager::add_pool<USDC>(owner);

        // execute
        money_market::deposit<USDC, Shadow>(account1, max, false);
        assert!(account_position::deposited_volume<ShadowToAsset>(account1_addr, key<USDC>()) == (max as u128), 0);
        assert!(coin::balance<USDZ>(account1_addr) == 0, 0);
    }
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_withdraw_asset_with_u64_max_except_interest_rate(owner: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let signers = scenario::initialize_signer_for_test(2);
        let (account1, account1_addr) = scenario::borrow_account(&signers, 0);
        let max = constant::u64_max();
        managed_coin::mint<WETH>(owner, account1_addr, max);
        pool_manager::add_pool<WETH>(owner);

        // deposit & borrow
        money_market::deposit<WETH, Asset>(account1, max, false);
        money_market::withdraw<WETH, Asset>(account1, max);
        assert!(account_position::deposited_volume<AssetToShadow>(account1_addr, key<WETH>()) == 0, 0);
        assert!(coin::balance<WETH>(account1_addr) == max, 0);
    }
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_withdraw_shadow_with_u64_max_except_interest_rate_and_fee(owner: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let signers = scenario::initialize_signer_for_test(2);
        let (account1, account1_addr) = scenario::borrow_account(&signers, 0);
        let max = constant::u64_max();
        usdz::mint_for_test(account1_addr, max);
        pool_manager::add_pool<USDC>(owner);

        // execute
        money_market::deposit<USDC, Shadow>(account1, max, false);
        money_market::withdraw<USDC, Shadow>(account1, max);
        assert!(account_position::deposited_volume<ShadowToAsset>(account1_addr, key<USDC>()) == 0, 0);
        assert!(coin::balance<USDZ>(account1_addr) == max, 0);
    }
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_borrow_asset_with_u64_except_interest_rate_and_fee(owner: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let signers = scenario::initialize_signer_for_test(2);
        let (account1, account1_addr) = scenario::borrow_account(&signers, 0);
        let max = constant::u64_max();
        managed_coin::mint<WETH>(owner, account1_addr, max);
        let (account2, account2_addr) = scenario::borrow_account(&signers, 1);
        usdz::mint_for_test(account2_addr, max);
        pool_manager::add_pool<WETH>(owner);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calcurate borrowed amount/share
        risk_factor::update_config<USDZ>(owner, risk_factor::precision(), risk_factor::precision()); // NOTE: to allow borrowing to the maximum

        // execute
        money_market::deposit<WETH, Asset>(account1, max, false);
        money_market::deposit<WETH, Shadow>(account2, max, false);
        money_market::borrow<WETH, Asset>(account2, max - 1); // NOTE: minus 1 from amount because HF must be less than LT
        assert!(account_position::borrowed_volume<ShadowToAsset>(account2_addr, key<WETH>()) == (max - 1 as u128), 0);
        assert!(coin::balance<WETH>(account2_addr) == max - 1, 0);
    }
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_borrow_shadow_with_u64_except_interest_rate(owner: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let signers = scenario::initialize_signer_for_test(2);
        let (account1, account1_addr) = scenario::borrow_account(&signers, 0);
        let max = constant::u64_max();
        usdz::mint_for_test(account1_addr, max);
        let (account2, account2_addr) = scenario::borrow_account(&signers, 1);
        managed_coin::mint<USDC>(owner, account2_addr, max);
        pool_manager::add_pool<USDC>(owner);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calcurate borrowed amount/share
        risk_factor::update_config<USDC>(owner, risk_factor::precision(), risk_factor::precision()); // NOTE: to allow borrowing to the maximum

        // execute
        money_market::deposit<USDC, Shadow>(account1, max, false);
        money_market::deposit<USDC, Asset>(account2, max, false);
        money_market::borrow<USDC, Shadow>(account2, max - 1); // NOTE: minus 1 from amount because HF must be less than LT
        assert!(account_position::borrowed_volume<AssetToShadow>(account2_addr, key<USDC>()) == (max - 1 as u128), 0);
        assert!(coin::balance<USDZ>(account2_addr) == max - 1, 0);
    }
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_repay_asset_with_u64_max_except_interest_rate_and_fee(owner: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let signers = scenario::initialize_signer_for_test(2);
        let (account1, account1_addr) = scenario::borrow_account(&signers, 0);
        let max = constant::u64_max();
        managed_coin::mint<WETH>(owner, account1_addr, max);
        let (account2, account2_addr) = scenario::borrow_account(&signers, 1);
        usdz::mint_for_test(account2_addr, max);
        pool_manager::add_pool<WETH>(owner);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calcurate borrowed amount/share
        risk_factor::update_config<USDZ>(owner, risk_factor::precision(), risk_factor::precision()); // NOTE: to allow borrowing to the maximum

        // execute
        money_market::deposit<WETH, Asset>(account1, max, false);
        money_market::deposit<WETH, Shadow>(account2, max, false);
        money_market::borrow<WETH, Asset>(account2, max - 1); // NOTE: minus 1 from amount because HF must be less than LT
        money_market::repay<WETH, Asset>(account2, max - 1);
        assert!(account_position::borrowed_volume<ShadowToAsset>(account2_addr, key<WETH>()) == 0, 0);
        assert!(coin::balance<WETH>(account2_addr) == 0, 0);
    }
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_repay_shadow_with_u64_max_except_interest_rate_and_fee(owner: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let signers = scenario::initialize_signer_for_test(2);
        let (account1, account1_addr) = scenario::borrow_account(&signers, 0);
        let max = constant::u64_max();
        usdz::mint_for_test(account1_addr, max);
        let (account2, account2_addr) = scenario::borrow_account(&signers, 1);
        managed_coin::mint<USDC>(owner, account2_addr, max);
        pool_manager::add_pool<USDC>(owner);

        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calcurate borrowed amount/share
        risk_factor::update_config<USDC>(owner, risk_factor::precision(), risk_factor::precision()); // NOTE: to allow borrowing to the maximum

        // execute
        money_market::deposit<USDC, Shadow>(account1, max, false);
        money_market::deposit<USDC, Asset>(account2, max, false);
        money_market::borrow<USDC, Shadow>(account2, max - 1); // NOTE: minus 1 from amount because HF must be less than LT
        money_market::repay<USDC, Shadow>(account2, max - 1);
        assert!(account_position::borrowed_volume<AssetToShadow>(account2_addr, key<USDC>()) == 0, 0);
        assert!(coin::balance<USDZ>(account2_addr) == 0, 0);
    }
}
