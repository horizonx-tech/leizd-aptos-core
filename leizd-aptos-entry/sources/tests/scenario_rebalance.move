#[test_only]
module leizd_aptos_entry::scenario_rebalance {
    #[test_only]
    use std::signer;
    #[test_only]
    use leizd_aptos_common::coin_key::{key};
    #[test_only]
    use leizd_aptos_common::position_type::{AssetToShadow,ShadowToAsset};
    #[test_only]
    use aptos_framework::coin;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_common::pool_type::{Asset, Shadow};
    #[test_only]
    use leizd_aptos_common::test_coin::{USDC, USDT, WETH, UNI};
    #[test_only]
    use leizd_aptos_logic::risk_factor;
    #[test_only]
    use leizd_aptos_trove::usdz::{Self, USDZ};
    #[test_only]
    use leizd_aptos_external::price_oracle;
    #[test_only]
    use leizd_aptos_treasury::treasury;
    #[test_only]
    use leizd_aptos_core::account_position;
    #[test_only]
    use leizd_aptos_core::asset_pool;
    #[test_only]
    use leizd_aptos_core::shadow_pool;
    #[test_only]
    use leizd::money_market::{
        initialize_lending_pool_for_test,
        setup_liquidity_provider_for_test,
        setup_account_for_test,
        deposit,
        borrow,
        liquidate,
        borrow_unsafe_for_test
    };
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,aptos_framework=@aptos_framework)]
    fun test_liquidate_with_rebalance(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        let borrower_addr = signer::address_of(borrower);
        let liquidator_addr = signer::address_of(liquidator);
        usdz::mint_for_test(borrower_addr, 500000);
        managed_coin::mint<WETH>(owner, liquidator_addr, 100000);

        // prerequisite
        deposit<WETH, Asset>(lp, 100000, false);
        deposit<USDC, Asset>(lp, 100000, false);

        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // deposit & borrow
        deposit<WETH, Shadow>(borrower, 100000, false);
        borrow<WETH, Asset>(borrower, 50000);
        deposit<USDC, Shadow>(borrower, 200000, false);
        borrow<USDC, Asset>(borrower, 50000);

        // change price
        price_oracle::update_fixed_price<WETH>(owner, 2, 0, false);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 100000, 0);
        assert!(shadow_pool::normal_deposited_amount<USDC>() == 200000, 0);

        // liquidate
        liquidate<WETH, Shadow>(liquidator, borrower_addr);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 200000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 100000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 200000, 0);
        assert!(shadow_pool::normal_deposited_amount<USDC>() == 100000, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,aptos_framework=@aptos_framework)]
    fun test_liquidate_with_rebalance_2(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        let borrower_addr = signer::address_of(borrower);
        let liquidator_addr = signer::address_of(liquidator);
        usdz::mint_for_test(borrower_addr, 500000);
        managed_coin::mint<WETH>(owner, liquidator_addr, 100000);

        // prerequisite
        deposit<WETH, Asset>(lp, 100000, false);
        deposit<USDC, Asset>(lp, 100000, false);

        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // deposit & borrow
        deposit<WETH, Shadow>(borrower, 100000, false);
        borrow<WETH, Asset>(borrower, 50000);
        deposit<USDC, Shadow>(borrower, 55000, false);
        borrow_unsafe_for_test<USDC, Asset>(borrower, 50000);

        // change price
        price_oracle::update_fixed_price<WETH>(owner, 2000000, 6, false);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 55000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 50250, 0);
        assert!(coin::balance<USDZ>(liquidator_addr) == 0, 0);
        assert!(coin::balance<WETH>(liquidator_addr) == 100000, 0);
        //// for pool
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 100000, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<USDC>() == 55000, 0);
        assert!(asset_pool::total_borrowed_amount<USDC>() == 50250, 0);

        // liquidate
        liquidate<WETH, Shadow>(liquidator, borrower_addr);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 0, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 0, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 55000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 50250, 0);
        assert!(coin::balance<USDZ>(liquidator_addr) == 99500, 0); // 0.5% liquidation fee
        assert!(coin::balance<WETH>(liquidator_addr) == 49750, 0);
        //// for pool
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 0, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 0, 0);
        assert!(shadow_pool::normal_deposited_amount<USDC>() == 55000, 0);
        assert!(asset_pool::total_borrowed_amount<USDC>() == 50250, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,aptos_framework=@aptos_framework,borrower2=@0x555)]
    fun test_liquidate_with_rebalance_3(owner: &signer, lp: &signer, borrower: &signer, borrower2: &signer, liquidator: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        setup_account_for_test(borrower2);
        let borrower_addr = signer::address_of(borrower);
        let borrower2_addr = signer::address_of(borrower2);
        let liquidator_addr = signer::address_of(liquidator);
        usdz::mint_for_test(borrower_addr, 1000000);
        usdz::mint_for_test(borrower2_addr, 1000000);
        managed_coin::mint<WETH>(owner, liquidator_addr, 100000);

        // prerequisite
        deposit<WETH, Asset>(lp, 200000, false);
        deposit<USDC, Asset>(lp, 200000, false);
        deposit<USDT, Asset>(lp, 200000, false);

        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // deposit & borrow
        deposit<WETH, Shadow>(borrower, 100000, false);
        borrow<WETH, Asset>(borrower, 50000);
        deposit<USDC, Shadow>(borrower, 200000, false);
        borrow<USDC, Asset>(borrower, 50000);
        deposit<USDT, Shadow>(borrower, 300000, false);
        borrow<USDT, Asset>(borrower, 50000);

        // deposit & borrow by others
        deposit<WETH, Shadow>(borrower2, 100000, false);
        borrow<WETH, Asset>(borrower2, 50000);
        deposit<USDC, Shadow>(borrower2, 200000, false);
        borrow<USDC, Asset>(borrower2, 50000);
        deposit<USDT, Shadow>(borrower2, 300000, false);
        borrow<USDT, Asset>(borrower2, 50000);

        // change price
        price_oracle::update_fixed_price<WETH>(owner, 2, 0, false);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 300000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower2_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower2_addr, key<WETH>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower2_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower2_addr, key<USDC>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower2_addr, key<USDT>()) == 300000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower2_addr, key<USDT>()) == 50250, 0);
        //// for pool
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 100000 + 100000, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 50250 + 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<USDC>() == 200000 + 200000, 0);
        assert!(asset_pool::total_borrowed_amount<USDC>() == 50250 + 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<USDT>() == 300000 + 300000, 0);
        assert!(asset_pool::total_borrowed_amount<USDT>() == 50250 + 50250, 0);

        // liquidate
        liquidate<WETH, Shadow>(liquidator, borrower_addr);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 300000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<WETH>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 150000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 150000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower2_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower2_addr, key<WETH>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower2_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower2_addr, key<USDC>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower2_addr, key<USDT>()) == 300000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower2_addr, key<USDT>()) == 50250, 0);
        //// for pool
        assert!(shadow_pool::normal_deposited_amount<WETH>() == 300000 + 100000, 0);
        assert!(asset_pool::total_borrowed_amount<WETH>() == 50250 + 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<USDC>() == 150000 + 200000, 0);
        assert!(asset_pool::total_borrowed_amount<USDC>() == 50250 + 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<USDT>() == 150000 + 300000, 0);
        assert!(asset_pool::total_borrowed_amount<USDT>() == 50250 + 50250, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,aptos_framework=@aptos_framework)]
    fun test_liquidate_with_rebalance_4(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        let borrower_addr = signer::address_of(borrower);
        // let liquidator_addr = signer::address_of(liquidator);
        managed_coin::mint<WETH>(owner, borrower_addr, 200000);
        managed_coin::mint<USDC>(owner, borrower_addr, 200000);

        // prerequisite
        deposit<WETH, Shadow>(lp, 100000, false);
        deposit<USDC, Shadow>(lp, 100000, false);

        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // deposit & borrow
        price_oracle::update_fixed_price<WETH>(owner, 1000000, 6, false);
        price_oracle::update_fixed_price<USDZ>(owner, 1000000, 6, false);
        deposit<WETH, Asset>(borrower, 100000, false);
        borrow<WETH, Shadow>(borrower, 50000);
        deposit<USDC, Asset>(borrower, 200000, false);
        borrow<USDC, Shadow>(borrower, 50000);

        // change price
        price_oracle::update_fixed_price<WETH>(owner, 500000, 6, false);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50250, 0);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 50250, 0);
        //// for pool
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100000, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 50250, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() == 200000, 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == 50250, 0);

        // liquidate
        liquidate<WETH, Asset>(liquidator, borrower_addr);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 20102, 0); // CHECK: 20100?
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 80550, 0);
        //// for pool
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100000, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 20102, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() == 200000, 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == 80550, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,aptos_framework=@aptos_framework)]
    fun test_liquidate_with_rebalance_5(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        let borrower_addr = signer::address_of(borrower);
        // let liquidator_addr = signer::address_of(liquidator);
        managed_coin::mint<WETH>(owner, borrower_addr, 200000);
        managed_coin::mint<USDC>(owner, borrower_addr, 200000);

        // prerequisite
        deposit<WETH, Shadow>(lp, 100000, false);
        deposit<USDC, Shadow>(lp, 100000, false);

        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // deposit & borrow
        price_oracle::update_fixed_price<WETH>(owner, 1000000, 6, false);
        price_oracle::update_fixed_price<USDZ>(owner, 1000000, 6, false);
        risk_factor::update_config<WETH>(owner, risk_factor::precision() / 100 * 70, risk_factor::precision() / 100 * 85);
        risk_factor::update_config<USDC>(owner, risk_factor::precision() / 100 * 70, risk_factor::precision() / 100 * 90);
        deposit<WETH, Asset>(borrower, 100000, false);
        borrow<WETH, Shadow>(borrower, 50000);
        deposit<USDC, Asset>(borrower, 200000, false);
        borrow<USDC, Shadow>(borrower, 50000);

        // change price
        price_oracle::update_fixed_price<WETH>(owner, 500000, 6, false);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50250, 0);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 50250, 0);
        //// for pool
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100000, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 50250, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() == 200000, 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == 50250, 0);

        // liquidate
        liquidate<WETH, Asset>(liquidator, borrower_addr);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 19198, 0);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 81459, 0);
        //// for pool
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100000, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 19198, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() == 200000, 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == 81459, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,aptos_framework=@aptos_framework)]
    fun test_liquidate_with_rebalance_6(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        let borrower_addr = signer::address_of(borrower);
        managed_coin::mint<WETH>(owner, borrower_addr, 200000);
        usdz::mint_for_test(borrower_addr, 1000000);

        // prerequisite
        deposit<WETH, Shadow>(lp, 100000, false);
        deposit<USDC, Asset>(lp, 100000, false);
        deposit<USDT, Asset>(lp, 100000, false);

        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // deposit & borrow
        price_oracle::update_fixed_price<WETH>(owner, 1000000, 6, false);
        price_oracle::update_fixed_price<USDZ>(owner, 1000000, 6, false);
        deposit<WETH, Asset>(borrower, 100000, false);
        borrow<WETH, Shadow>(borrower, 50000);
        deposit<USDC, Shadow>(borrower, 200000, false);
        borrow<USDC, Asset>(borrower, 50000);
        deposit<USDT, Shadow>(borrower, 300000, false);
        borrow<USDT, Asset>(borrower, 50000);

        // change price
        price_oracle::update_fixed_price<WETH>(owner, 500000, 6, false);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 300000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 50250, 0);
        //// for pool
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100000, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<USDC>() == 200000, 0);
        assert!(asset_pool::total_borrowed_amount<USDC>() == 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<USDT>() == 300000, 0);
        assert!(asset_pool::total_borrowed_amount<USDT>() == 50250, 0);

        // liquidate
        liquidate<WETH, Asset>(liquidator, borrower_addr);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 9782, 0); // CHECK: 9784?
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 229766, 0); // CHECK: 229767?
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDC>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 229766, 0); // CHECK: 229767?
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 50250, 0);
        //// for pool
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100000, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 9782, 0);
        assert!(shadow_pool::normal_deposited_amount<USDC>() == 229766, 0);
        assert!(asset_pool::total_borrowed_amount<USDC>() == 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<USDT>() == 229766, 0);
        assert!(asset_pool::total_borrowed_amount<USDT>() == 50250, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,aptos_framework=@aptos_framework)]
    fun test_liquidate_with_rebalance_7(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        let borrower_addr = signer::address_of(borrower);
        managed_coin::mint<WETH>(owner, borrower_addr, 200000);
        managed_coin::mint<USDC>(owner, borrower_addr, 200000);
        usdz::mint_for_test(borrower_addr, 1000000);

        // prerequisite
        deposit<WETH, Shadow>(lp, 200000, false);
        deposit<USDC, Shadow>(lp, 200000, false);
        deposit<USDT, Asset>(lp, 200000, false);
        deposit<UNI, Asset>(lp, 200000, false);

        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // deposit & borrow
        price_oracle::update_fixed_price<UNI>(owner, 1000000, 6, false);
        price_oracle::update_fixed_price<USDZ>(owner, 1000000, 6, false);
        deposit<WETH, Asset>(borrower, 100000, false);
        borrow<WETH, Shadow>(borrower, 50000);
        deposit<USDC, Asset>(borrower, 200000, false);
        borrow<USDC, Shadow>(borrower, 100000);
        deposit<USDT, Shadow>(borrower, 300000, false);
        borrow<USDT, Asset>(borrower, 50000);
        deposit<UNI, Shadow>(borrower, 200000, false);
        borrow<UNI, Asset>(borrower, 50000);

        // change price
        price_oracle::update_fixed_price<UNI>(owner, 4000000, 6, false);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50250, 0);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 300000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 50250, 0); 
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 200000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 201000, 0);
        //// for pool
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100000, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 50250, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() == 200000, 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == 100500, 0);
        assert!(shadow_pool::normal_deposited_amount<USDT>() == 300000, 0);
        assert!(asset_pool::total_borrowed_amount<USDT>() == 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<UNI>() == 200000, 0);
        assert!(asset_pool::total_borrowed_amount<UNI>() == 50250, 0);

        // liquidate
        liquidate<UNI, Shadow>(liquidator, borrower_addr);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 46105, 0); // CHECK: 46107?
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 92213, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 97513, 0); // CHECK: 97514?
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 390055, 0); // CHECK: 390056
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 201000, 0);
        //// for pool
        assert!(asset_pool::total_normal_deposited_amount<WETH>() == 100000, 0);
        assert!(shadow_pool::borrowed_amount<WETH>() == 46105, 0);
        assert!(asset_pool::total_normal_deposited_amount<USDC>() == 200000, 0);
        assert!(shadow_pool::borrowed_amount<USDC>() == 92213, 0);
        assert!(shadow_pool::normal_deposited_amount<USDT>() == 97513, 0);
        assert!(asset_pool::total_borrowed_amount<USDT>() == 50250, 0);
        assert!(shadow_pool::normal_deposited_amount<UNI>() == 390055, 0);
        assert!(asset_pool::total_borrowed_amount<UNI>() == 50250, 0);
    }
    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,target=@0x444,aptos_framework=@aptos_framework)]
    fun test_liquidate_with_rebalance_8(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, target: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        setup_account_for_test(target);
        let borrower_addr = signer::address_of(borrower);
        managed_coin::mint<WETH>(owner, borrower_addr, 200000);
        managed_coin::mint<USDC>(owner, borrower_addr, 200000);
        usdz::mint_for_test(borrower_addr, 1000000);

        // prerequisite
        deposit<WETH, Shadow>(lp, 200000, false);
        deposit<USDC, Shadow>(lp, 200000, false);
        deposit<USDT, Asset>(lp, 200000, false);
        deposit<UNI, Asset>(lp, 200000, false);

        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // deposit & borrow
        price_oracle::update_fixed_price<UNI>(owner, 1000000, 6, false);
        price_oracle::update_fixed_price<USDZ>(owner, 1000000, 6, false);
        deposit<WETH, Asset>(borrower, 100000, false);
        borrow<WETH, Shadow>(borrower, 50000);
        deposit<USDC, Asset>(borrower, 200000, false);
        borrow<USDC, Shadow>(borrower, 100000);
        deposit<USDT, Shadow>(borrower, 300000, false);
        borrow<USDT, Asset>(borrower, 50000);
        deposit<UNI, Shadow>(borrower, 200000, false);
        borrow<UNI, Asset>(borrower, 50000);

        account_position::disable_to_rebalance<WETH>(borrower);
        account_position::disable_to_rebalance<UNI>(borrower);
        account_position::enable_to_rebalance<UNI>(borrower);

        // change price
        price_oracle::update_fixed_price<UNI>(owner, 4000000, 6, false);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50250, 0);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 300000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 50250, 0); 
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 200000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 201000, 0); 

        // liquidate
        liquidate<UNI, Shadow>(liquidator, borrower_addr);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50250, 0);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 91557, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 98211, 0); // CHECK: 98212?
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 50250, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 392846, 0); // CHECK: 392847?
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 201000, 0);
    }

    #[test(owner=@leizd_aptos_entry,lp=@0x111,borrower=@0x222,liquidator=@0x333,target=@0x444,aptos_framework=@aptos_framework)]
    fun test_liquidate_with_rebalance_9(owner: &signer, lp: &signer, borrower: &signer, liquidator: &signer, target: &signer, aptos_framework: &signer) {
        initialize_lending_pool_for_test(owner, aptos_framework);
        setup_liquidity_provider_for_test(owner, lp);
        setup_account_for_test(borrower);
        setup_account_for_test(liquidator);
        setup_account_for_test(target);
        let borrower_addr = signer::address_of(borrower);
        let liquidator_addr = signer::address_of(liquidator);
        managed_coin::mint<WETH>(owner, borrower_addr, 200000);
        managed_coin::mint<USDC>(owner, borrower_addr, 200000);
        managed_coin::mint<UNI>(owner, liquidator_addr, 300000);
        usdz::mint_for_test(borrower_addr, 1000000);

        // prerequisite
        deposit<WETH, Shadow>(lp, 200000, false);
        deposit<USDC, Shadow>(lp, 200000, false);
        deposit<USDT, Asset>(lp, 200000, false);
        deposit<UNI, Asset>(lp, 200000, false);

        //// check risk_factor
        assert!(risk_factor::lt<WETH>() == risk_factor::default_lt(), 0);
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // deposit & borrow
        price_oracle::update_fixed_price<UNI>(owner, 1000000, 6, false);
        price_oracle::update_fixed_price<USDZ>(owner, 1000000, 6, false);
        deposit<WETH, Asset>(borrower, 100000, false);
        borrow<WETH, Shadow>(borrower, 50000);
        deposit<USDC, Asset>(borrower, 200000, false);
        borrow<USDC, Shadow>(borrower, 100000);
        deposit<USDT, Shadow>(borrower, 300000, false);
        borrow<USDT, Asset>(borrower, 50000);
        deposit<UNI, Shadow>(borrower, 200000, false);
        borrow<UNI, Asset>(borrower, 50000);

        account_position::disable_to_rebalance<WETH>(borrower);
        account_position::disable_to_rebalance<UNI>(borrower);

        // change price
        price_oracle::update_fixed_price<UNI>(owner, 4000000, 6, false);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50250, 0);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 300000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 50250, 0); 
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 200000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 201000, 0); 
        assert!(coin::balance<USDZ>(liquidator_addr) == 0, 0);
        assert!(coin::balance<UNI>(liquidator_addr) == 300000, 0);
        assert!(treasury::balance<USDZ>() == 750, 0);

        // liquidate
        liquidate<UNI, Shadow>(liquidator, borrower_addr);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 100000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<WETH>()) == 50250, 0);
        assert!(account_position::deposited_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 200000, 0);
        assert!(account_position::borrowed_volume<AssetToShadow>(borrower_addr, key<USDC>()) == 100500, 0);
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 300000, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<USDT>()) == 50250, 0); 
        assert!(account_position::deposited_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 0, 0);
        assert!(account_position::borrowed_volume<ShadowToAsset>(borrower_addr, key<UNI>()) == 0, 0);
        assert!(coin::balance<USDZ>(liquidator_addr) == 199000, 0);
        assert!(coin::balance<UNI>(liquidator_addr) == 249750, 0); // 300000 - 50000 - 250
        assert!(treasury::balance<USDZ>() == 1750, 0); // 750 + 200000 * 0.005
    }

}