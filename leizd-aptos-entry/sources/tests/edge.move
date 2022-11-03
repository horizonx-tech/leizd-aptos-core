#[test_only]
module leizd_aptos_entry::edge {

    use std::signer;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::managed_coin;
    use leizd_aptos_lib::constant;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::pool_type::{Asset, Shadow};
    use leizd_aptos_common::test_coin::{WETH, USDC, USDT, UNI};
    use leizd_aptos_common::position_type::{AssetToShadow, ShadowToAsset};
    use leizd_aptos_logic::risk_factor;
    use leizd_aptos_trove::usdz::{Self, USDZ};
    use leizd_aptos_core::pool_manager;
    use leizd_aptos_core::shadow_pool;
    use leizd_aptos_core::account_position;
    use leizd_aptos_entry::money_market;
    use leizd_aptos_entry::scenario;
    use leizd_aptos_external::price_oracle;

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
        assert!(account_position::deposited_volume<AssetToShadow>(account1_addr, key<WETH>()) == price_oracle::volume(&key<WETH>(), (max as u128)), 0);
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
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        risk_factor::update_config<USDZ>(owner, risk_factor::precision(), risk_factor::precision()); // NOTE: to allow borrowing to the maximum

        let borrowable_amount_in_usd = price_oracle::volume(&key<USDZ>(),(max as u128)) * 70 / 100 - 1; // NOTE: minus 1 from amount because HF must be less than LTV
        let (value, _dec) = price_oracle::price_of(&key<WETH>());
        let borrowable_amount_in_weth = borrowable_amount_in_usd / value;

        // execute
        money_market::deposit<WETH, Asset>(account1, max, false);
        money_market::deposit<WETH, Shadow>(account2, max, false);
        money_market::borrow<WETH, Asset>(account2, (borrowable_amount_in_weth as u64));
        assert!(account_position::borrowed_volume<ShadowToAsset>(account2_addr, key<WETH>()) == price_oracle::volume(&key<WETH>(), borrowable_amount_in_weth), 0);
        assert!(coin::balance<WETH>(account2_addr) == (borrowable_amount_in_weth as u64), 0);
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
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        risk_factor::update_config<USDC>(owner, risk_factor::precision(), risk_factor::precision()); // NOTE: to allow borrowing to the maximum

        let borrowable_amount_in_usd = price_oracle::volume(&key<USDC>(),(max as u128)) * 70 / 100 - 1; // NOTE: minus 1 from amount because HF must be less than LTV
        let (value, _) = price_oracle::price_of(&key<USDC>());
        let borrowable_amount_in_usdc = borrowable_amount_in_usd / value;

        // execute
        money_market::deposit<USDC, Shadow>(account1, max, false);
        money_market::deposit<USDC, Asset>(account2, max, false);
        money_market::borrow<USDC, Shadow>(account2, (borrowable_amount_in_usdc as u64));
        assert!(account_position::borrowed_volume<AssetToShadow>(account2_addr, key<USDC>()) == price_oracle::volume(&key<USDZ>(), borrowable_amount_in_usdc), 0);
        assert!(coin::balance<USDZ>(account2_addr) == (borrowable_amount_in_usdc as u64), 0);
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
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        risk_factor::update_config<USDZ>(owner, risk_factor::precision(), risk_factor::precision()); // NOTE: to allow borrowing to the maximum

        let borrowable_amount_in_usd = price_oracle::volume(&key<USDZ>(),(max as u128)) * 70 / 100 - 1; // NOTE: minus 1 from amount because HF must be less than LTV
        let (value_weth, _) = price_oracle::price_of(&key<WETH>());
        let borrowable_amount_in_weth = borrowable_amount_in_usd / value_weth;

        // execute
        money_market::deposit<WETH, Asset>(account1, max, false);
        money_market::deposit<WETH, Shadow>(account2, max, false);
        money_market::borrow<WETH, Asset>(account2, (borrowable_amount_in_weth as u64));
        money_market::repay<WETH, Asset>(account2, (borrowable_amount_in_weth as u64));
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
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        risk_factor::update_config<USDC>(owner, risk_factor::precision(), risk_factor::precision()); // NOTE: to allow borrowing to the maximum

        let borrowable_amount_in_usd = price_oracle::volume(&key<USDC>(),(max as u128)) * 70 / 100 - 1; // NOTE: minus 1 from amount because HF must be less than LTV
        let (value, _) = price_oracle::price_of(&key<USDC>());
        let borrowable_amount_in_usdc = borrowable_amount_in_usd / value;

        // execute
        money_market::deposit<USDC, Shadow>(account1, max, false);
        money_market::deposit<USDC, Asset>(account2, max, false);
        money_market::borrow<USDC, Shadow>(account2, (borrowable_amount_in_usdc as u64)); // NOTE: minus 1 from amount because HF must be less than LTV
        money_market::repay<USDC, Shadow>(account2, (borrowable_amount_in_usdc as u64));
        assert!(account_position::borrowed_volume<AssetToShadow>(account2_addr, key<USDC>()) == 0, 0);
        assert!(coin::balance<USDZ>(account2_addr) == 0, 0);
    }
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_switch_collateral_asset_with_u64_max(owner: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let signers = scenario::initialize_signer_for_test(1);
        let (account1, account1_addr) = scenario::borrow_account(&signers, 0);
        let max = constant::u64_max();
        managed_coin::mint<WETH>(owner, account1_addr, max);
        pool_manager::add_pool<WETH>(owner);

        money_market::deposit<WETH, Asset>(account1, max, false);
        money_market::switch_collateral<WETH, Asset>(account1, true);
        assert!(account_position::normal_deposited_asset_share<WETH>(account1_addr) == 0, 0);
        assert!(account_position::conly_deposited_asset_share<WETH>(account1_addr) == max, 0);
        money_market::switch_collateral<WETH, Asset>(account1, false);
        assert!(account_position::normal_deposited_asset_share<WETH>(account1_addr) == max, 0);
        assert!(account_position::conly_deposited_asset_share<WETH>(account1_addr) == 0, 0);
    }
    #[test(owner = @leizd_aptos_entry, aptos_framework = @aptos_framework)]
    fun test_switch_collateral_shadow_with_u64_max(owner: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let signers = scenario::initialize_signer_for_test(1);
        let (account1, account1_addr) = scenario::borrow_account(&signers, 0);
        let max = constant::u64_max();
        usdz::mint_for_test(account1_addr, max);
        pool_manager::add_pool<USDC>(owner);

        money_market::deposit<USDC, Shadow>(account1, max, false);
        money_market::switch_collateral<USDC, Shadow>(account1, true);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account1_addr) == 0, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account1_addr) == max, 0);
        money_market::switch_collateral<USDC, Shadow>(account1, false);
        assert!(account_position::normal_deposited_shadow_share<USDC>(account1_addr) == max, 0);
        assert!(account_position::conly_deposited_shadow_share<USDC>(account1_addr) == 0, 0);
    }
    #[test_only]
    fun prepare_to_exec_repay_shadow_with_rebalance(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        // prepares
        scenario::initialize_scenario(owner, aptos_framework);
        let owner_addr = signer::address_of(owner);
        let lp_addr = signer::address_of(lp);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(lp_addr);
        account::create_account_for_test(account_addr);
        scenario::register_all_coins(lp);
        scenario::register_all_coins(account);
        pool_manager::add_pool<WETH>(owner);
        pool_manager::add_pool<USDC>(owner);
        pool_manager::add_pool<USDT>(owner);
        pool_manager::add_pool<UNI>(owner);

        // prerequisite
        //// update risk_factor
        risk_factor::update_protocol_fees_unsafe(
            0,
            0,
            risk_factor::default_liquidation_fee(),
        ); // NOTE: remove entry fee / share fee to make it easy to calculate borrowed amount/share
        risk_factor::update_config<USDC>(owner, risk_factor::precision(), risk_factor::precision()); // NOTE: to allow borrowing to the maximum
        //// add liquidity
        let max = constant::u64_max();
        managed_coin::mint<WETH>(owner, account_addr, max);
        managed_coin::mint<USDC>(owner, account_addr, max);
        managed_coin::mint<USDT>(owner, account_addr, max);
        managed_coin::mint<UNI>(owner, account_addr, max);
        money_market::deposit<WETH, Asset>(account, max, false);
        money_market::deposit<USDC, Asset>(account, max, false);
        money_market::deposit<USDT, Asset>(account, max, false);
        money_market::deposit<UNI, Asset>(account, max, false);

        // execute
        //// borrow
        usdz::mint_for_test(lp_addr, max);
        let amount: u64;
        amount = max / 5 * 2; // 40%
        money_market::deposit<WETH, Shadow>(lp, amount, false);
        money_market::borrow<WETH, Shadow>(account, amount);

        amount = max / 5; // 20%
        money_market::deposit<USDC, Shadow>(lp, amount, false);
        money_market::borrow<USDC, Shadow>(account, amount);

        amount = max / 5 / 3 * 2; // 13.333...%
        money_market::deposit<USDT, Shadow>(lp, amount, false);
        money_market::borrow<USDT, Shadow>(account, amount);

        amount = max / 5 / 3; // 6.666...%
        money_market::deposit<UNI, Shadow>(lp, amount, false);
        money_market::borrow<UNI, Shadow>(account, amount);

        assert!(shadow_pool::borrowed_amount<WETH>() == (max / 5 * 2 as u128), 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == (max / 5 as u128), 0);
        assert!(shadow_pool::borrowed_amount<USDT>() == (max / 5 / 3 * 2 as u128), 0);
        assert!(shadow_pool::borrowed_amount<UNI>() == (max / 5 / 3 as u128), 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == max / 5 * 2, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == max / 5, 0);
        assert!(account_position::borrowed_shadow_share<USDT>(account_addr) == max / 5 / 3 * 2, 0);
        assert!(account_position::borrowed_shadow_share<UNI>(account_addr) == max / 5 / 3, 0);

        //// post-process
        managed_coin::register<USDZ>(owner);
        coin::transfer<USDZ>(account, owner_addr, max / 5 * 4);
        assert!(coin::balance<USDZ>(owner_addr) == max / 5 * 4, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
    }
    #[test(owner = @leizd_aptos_entry, lp = @0x111, account = @0x222, aptos_framework = @aptos_framework)]
    fun test_repay_shadow_evenly_with_u64_max_except_fee_to_repay_all(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_repay_shadow_with_rebalance(owner, lp, account, aptos_framework);
        let account_addr = signer::address_of(account);
        let max = constant::u64_max();

        //// execute
        let amount = max;
        usdz::mint_for_test(account_addr, amount);
        money_market::repay_shadow_evenly(account, amount);

        assert!(shadow_pool::borrowed_amount<WETH>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<USDT>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<UNI>() == 0, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 0, 0);
        assert!(account_position::borrowed_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::borrowed_shadow_share<UNI>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == max / 5, 0);
    }
    #[test(owner = @leizd_aptos_entry, lp = @0x111, account = @0x222, aptos_framework = @aptos_framework)]
    fun test_repay_shadow_evenly_with_u64_max_except_fee_to_repay_all_in_part(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_repay_shadow_with_rebalance(owner, lp, account, aptos_framework);
        let account_addr = signer::address_of(account);
        let max = constant::u64_max();

        //// execute
        let amount = (max / 5 - 1) * 4;
        usdz::mint_for_test(account_addr, amount);
        money_market::repay_shadow_evenly(account, amount);

        assert!(shadow_pool::borrowed_amount<WETH>() == (max / 5 + 1 as u128), 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == 1, 0);
        assert!(shadow_pool::borrowed_amount<USDT>() == 0, 0);
        assert!(shadow_pool::borrowed_amount<UNI>() == 0, 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == max / 5 + 1, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == 1, 0);
        assert!(account_position::borrowed_shadow_share<USDT>(account_addr) == 0, 0);
        assert!(account_position::borrowed_shadow_share<UNI>(account_addr) == 0, 0);
        assert!(coin::balance<USDZ>(account_addr) == (max / 5 - 1) * 2 - (max / 5), 0);
    }
    #[test(owner = @leizd_aptos_entry, lp = @0x111, account = @0x222, aptos_framework = @aptos_framework)]
    fun test_repay_shadow_evenly_with_u64_max_except_fee_to_repay_evenly(owner: &signer, lp: &signer, account: &signer, aptos_framework: &signer) {
        prepare_to_exec_repay_shadow_with_rebalance(owner, lp, account, aptos_framework);
        let account_addr = signer::address_of(account);
        let max = constant::u64_max();

        //// execute
        let amount = 4;
        usdz::mint_for_test(account_addr, amount);
        money_market::repay_shadow_evenly(account, amount);

        assert!(shadow_pool::borrowed_amount<WETH>() == (max / 5 * 2 - 1 as u128), 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == (max / 5 - 1 as u128), 0);
        assert!(shadow_pool::borrowed_amount<USDT>() == (max / 5 / 3 * 2 - 1 as u128), 0);
        assert!(shadow_pool::borrowed_amount<UNI>() == (max / 5 / 3 - 1 as u128), 0);
        assert!(account_position::borrowed_shadow_share<WETH>(account_addr) == max / 5 * 2 - 1, 0);
        assert!(account_position::borrowed_shadow_share<USDC>(account_addr) == max / 5 - 1, 0);
        assert!(account_position::borrowed_shadow_share<USDT>(account_addr) == max / 5 / 3 * 2 - 1, 0);
        assert!(account_position::borrowed_shadow_share<UNI>(account_addr) == max / 5 / 3 - 1, 0);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
    }
}
