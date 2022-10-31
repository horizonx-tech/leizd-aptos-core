module leizd_aptos_common::system_administrator {

    use std::signer;
    use std::string::{String};
    use std::vector;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::permission;
    use leizd_aptos_common::pool_status;
    use leizd_aptos_common::system_status;

    public entry fun activate_pool<C>(owner: &signer) {
        activate_pool_internal(key<C>(), owner);
    }
    public entry fun activate_all_pool(owner: &signer) {
        let assets = pool_status::managed_assets();
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            activate_pool_internal(*key, owner);
            i = i + 1;
        }
    }
    fun activate_pool_internal(key: String, owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        pool_status::update_deposit_status_with(key, true);
        pool_status::update_withdraw_status_with(key, true);
        pool_status::update_borrow_status_with(key, true);
        pool_status::update_repay_status_with(key, true);
        pool_status::update_switch_collateral_status_with(key, true);
        update_borrow_asset_with_rebalance_status(key, true);
        update_liquidate_status(key, true);
    }

    public entry fun deactivate_pool<C>(owner: &signer) {
        deactivate_pool_internal(key<C>(), owner);
    }
    public entry fun deactivate_all_pool(owner: &signer) {
        let assets = pool_status::managed_assets();
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            deactivate_pool_internal(*key, owner);
            i = i + 1;
        }
    }
    fun deactivate_pool_internal(key: String, owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        pool_status::update_deposit_status_with(key, false);
        pool_status::update_withdraw_status_with(key, false);
        pool_status::update_borrow_status_with(key, false);
        pool_status::update_repay_status_with(key, false);
        pool_status::update_switch_collateral_status_with(key, false);
        update_borrow_asset_with_rebalance_status(key, false);
        update_liquidate_status(key, false);
    }

    public entry fun freeze_pool<C>(owner: &signer) {
        freeze_pool_internal(key<C>(), owner);
    }
    public entry fun freeze_all_pool(owner: &signer) {
        let assets = pool_status::managed_assets();
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            freeze_pool_internal(*key, owner);
            i = i + 1;
        }
    }
    fun freeze_pool_internal(key: String, owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        pool_status::update_deposit_status_with(key, false);
        pool_status::update_borrow_status_with(key, false);
        update_borrow_asset_with_rebalance_status(key, false);
        update_liquidate_status(key, false);
    }

    public entry fun unfreeze_pool<C>(owner: &signer) {
        unfreeze_pool_internal(key<C>(), owner);
    }
    public entry fun unfreeze_all_pool(owner: &signer) {
        let assets = pool_status::managed_assets();
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            unfreeze_pool_internal(*key, owner);
            i = i + 1;
        }
    }
    public entry fun unfreeze_pool_internal(key: String, owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        pool_status::update_deposit_status_with(key, true);
        pool_status::update_borrow_status_with(key, true);
        update_borrow_asset_with_rebalance_status(key, true);
        update_liquidate_status(key, true);
    }

    public entry fun enable_borrow_asset_with_rebalance<C>(owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        update_borrow_asset_with_rebalance_status(key<C>(), true);
    }
    public entry fun enable_borrow_asset_with_rebalance_for_all_pool(owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        let assets = pool_status::managed_assets();
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            update_borrow_asset_with_rebalance_status(*key, true);
            i = i + 1;
        }
    }
    public entry fun disable_borrow_asset_with_rebalance<C>(owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        update_borrow_asset_with_rebalance_status(key<C>(), false);
    }
    public entry fun disable_borrow_asset_with_rebalance_for_all_pool(owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        let assets = pool_status::managed_assets();
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            update_borrow_asset_with_rebalance_status(*key, false);
            i = i + 1;
        }
    }
    fun update_borrow_asset_with_rebalance_status(key: String, is_active: bool) {
        pool_status::update_borrow_asset_with_rebalance_status_with(key, is_active);
    }

    public entry fun enable_repay_shadow_evenly(owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        pool_status::update_repay_shadow_evenly_status(true);
    }
    public entry fun disable_repay_shadow_evenly(owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        pool_status::update_repay_shadow_evenly_status(false);
    }

    public entry fun enable_liquidate<C>(owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        update_liquidate_status(key<C>(), true);
    }
    public entry fun enable_liquidate_for_all_pool(owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        let assets = pool_status::managed_assets();
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            update_liquidate_status(*key, true);
            i = i + 1;
        }
    }
    public entry fun disable_liquidate<C>(owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        update_liquidate_status(key<C>(), false);
    }
    public entry fun disable_liquidate_for_all_pool(owner: &signer) {
        permission::assert_operator(signer::address_of(owner));
        let assets = pool_status::managed_assets();
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            update_liquidate_status(*key, false);
            i = i + 1;
        }
    }
    fun update_liquidate_status(key: String, is_active: bool) {
        pool_status::update_liquidate_status_with(key, is_active);
    }

    public entry fun pause_protocol(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        system_status::update_status(false);
    }

    public entry fun resume_protocol(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        system_status::update_status(true);
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use leizd_aptos_common::test_coin::{WETH, USDC, USDT, UNI};
    #[test_only]
    fun prepare_for_test(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        system_status::initialize(owner);
        pool_status::initialize(owner);
        pool_status::initialize_for_asset_for_test<WETH>(owner);
        permission::initialize(owner);
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_operate_pool_to_deactivate(owner: &signer) {
        prepare_for_test(owner);
        assert!(pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
        assert!(pool_status::can_switch_collateral<WETH>(), 0);
        assert!(pool_status::can_borrow_asset_with_rebalance<WETH>(), 0);
        assert!(pool_status::can_liquidate<WETH>(), 0);
        deactivate_pool<WETH>(owner);
        assert!(!pool_status::can_deposit<WETH>(), 0);
        assert!(!pool_status::can_withdraw<WETH>(), 0);
        assert!(!pool_status::can_borrow<WETH>(), 0);
        assert!(!pool_status::can_repay<WETH>(), 0);
        assert!(!pool_status::can_switch_collateral<WETH>(), 0);
        assert!(!pool_status::can_borrow_asset_with_rebalance<WETH>(), 0);
        assert!(!pool_status::can_liquidate<WETH>(), 0);
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_deactivate_all_pool(owner: &signer) {
        prepare_for_test(owner);
        pool_status::initialize_for_asset_for_test<USDC>(owner);
        pool_status::initialize_for_asset_for_test<USDT>(owner);
        pool_status::initialize_for_asset_for_test<UNI>(owner);

        // prerequisite
        let assets = pool_status::managed_assets();
        assert!(vector::borrow(&assets, 0) == &key<WETH>(), 0);
        assert!(vector::borrow(&assets, 1) == &key<USDC>(), 0);
        assert!(vector::borrow(&assets, 2) == &key<USDT>(), 0);
        assert!(vector::borrow(&assets, 3) == &key<UNI>(), 0);

        // execute
        deactivate_all_pool(owner);
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            assert!(!pool_status::can_deposit_with(*key), 0);
            assert!(!pool_status::can_withdraw_with(*key), 0);
            assert!(!pool_status::can_borrow_with(*key), 0);
            assert!(!pool_status::can_repay_with(*key), 0);
            assert!(!pool_status::can_switch_collateral_with(*key), 0);
            assert!(!pool_status::can_borrow_asset_with_rebalance_with(*key), 0);
            assert!(!pool_status::can_liquidate_with(*key), 0);
            i = i + 1;
        };
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_operate_pool_to_activate(owner: &signer) {
        prepare_for_test(owner);
        deactivate_pool<WETH>(owner);
        assert!(!pool_status::can_deposit<WETH>(), 0);
        assert!(!pool_status::can_withdraw<WETH>(), 0);
        assert!(!pool_status::can_borrow<WETH>(), 0);
        assert!(!pool_status::can_repay<WETH>(), 0);
        assert!(!pool_status::can_switch_collateral<WETH>(), 0);
        assert!(!pool_status::can_borrow_asset_with_rebalance<WETH>(), 0);
        assert!(!pool_status::can_liquidate<WETH>(), 0);
        activate_pool<WETH>(owner);
        assert!(pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
        assert!(pool_status::can_switch_collateral<WETH>(), 0);
        assert!(pool_status::can_borrow_asset_with_rebalance<WETH>(), 0);
        assert!(pool_status::can_liquidate<WETH>(), 0);
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_activate_all_pool(owner: &signer) {
        prepare_for_test(owner);
        pool_status::initialize_for_asset_for_test<USDC>(owner);
        pool_status::initialize_for_asset_for_test<USDT>(owner);
        pool_status::initialize_for_asset_for_test<UNI>(owner);

        // prerequisite
        let assets = pool_status::managed_assets();
        assert!(vector::borrow(&assets, 0) == &key<WETH>(), 0);
        assert!(vector::borrow(&assets, 1) == &key<USDC>(), 0);
        assert!(vector::borrow(&assets, 2) == &key<USDT>(), 0);
        assert!(vector::borrow(&assets, 3) == &key<UNI>(), 0);
        deactivate_all_pool(owner);

        // execute
        activate_all_pool(owner);
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            assert!(pool_status::can_deposit_with(*key), 0);
            assert!(pool_status::can_withdraw_with(*key), 0);
            assert!(pool_status::can_borrow_with(*key), 0);
            assert!(pool_status::can_repay_with(*key), 0);
            assert!(pool_status::can_switch_collateral_with(*key), 0);
            assert!(pool_status::can_borrow_asset_with_rebalance_with(*key), 0);
            assert!(pool_status::can_liquidate_with(*key), 0);
            i = i + 1;
        };
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_operate_pool_to_freeze(owner: &signer) {
        prepare_for_test(owner);
        assert!(pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
        assert!(pool_status::can_switch_collateral<WETH>(), 0);
        assert!(pool_status::can_borrow_asset_with_rebalance<WETH>(), 0);
        assert!(pool_status::can_liquidate<WETH>(), 0);
        freeze_pool<WETH>(owner);
        assert!(!pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(!pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
        assert!(pool_status::can_switch_collateral<WETH>(), 0);
        assert!(!pool_status::can_borrow_asset_with_rebalance<WETH>(), 0);
        assert!(!pool_status::can_liquidate<WETH>(), 0);
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_freeze_all_pool(owner: &signer) {
        prepare_for_test(owner);
        pool_status::initialize_for_asset_for_test<USDC>(owner);
        pool_status::initialize_for_asset_for_test<USDT>(owner);
        pool_status::initialize_for_asset_for_test<UNI>(owner);

        // prerequisite
        let assets = pool_status::managed_assets();
        assert!(vector::borrow(&assets, 0) == &key<WETH>(), 0);
        assert!(vector::borrow(&assets, 1) == &key<USDC>(), 0);
        assert!(vector::borrow(&assets, 2) == &key<USDT>(), 0);
        assert!(vector::borrow(&assets, 3) == &key<UNI>(), 0);

        // execute
        freeze_all_pool(owner);
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            assert!(!pool_status::can_deposit_with(*key), 0);
            assert!(pool_status::can_withdraw_with(*key), 0);
            assert!(!pool_status::can_borrow_with(*key), 0);
            assert!(pool_status::can_repay_with(*key), 0);
            assert!(pool_status::can_switch_collateral_with(*key), 0);
            assert!(!pool_status::can_borrow_asset_with_rebalance_with(*key), 0);
            assert!(!pool_status::can_liquidate_with(*key), 0);
            i = i + 1;
        };
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_operate_pool_to_unfreeze(owner: &signer) {
        prepare_for_test(owner);
        freeze_pool<WETH>(owner);
        assert!(!pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(!pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
        assert!(pool_status::can_switch_collateral<WETH>(), 0);
        assert!(!pool_status::can_borrow_asset_with_rebalance<WETH>(), 0);
        assert!(!pool_status::can_liquidate<WETH>(), 0);
        unfreeze_pool<WETH>(owner);
        assert!(pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
        assert!(pool_status::can_switch_collateral<WETH>(), 0);
        assert!(pool_status::can_borrow_asset_with_rebalance<WETH>(), 0);
        assert!(pool_status::can_liquidate<WETH>(), 0);
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_unfreeze_all_pool(owner: &signer) {
        prepare_for_test(owner);
        pool_status::initialize_for_asset_for_test<USDC>(owner);
        pool_status::initialize_for_asset_for_test<USDT>(owner);
        pool_status::initialize_for_asset_for_test<UNI>(owner);

        // prerequisite
        let assets = pool_status::managed_assets();
        assert!(vector::borrow(&assets, 0) == &key<WETH>(), 0);
        assert!(vector::borrow(&assets, 1) == &key<USDC>(), 0);
        assert!(vector::borrow(&assets, 2) == &key<USDT>(), 0);
        assert!(vector::borrow(&assets, 3) == &key<UNI>(), 0);
        deactivate_all_pool(owner);

        // execute
        unfreeze_all_pool(owner);
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            assert!(pool_status::can_deposit_with(*key), 0);
            assert!(!pool_status::can_withdraw_with(*key), 0);
            assert!(pool_status::can_borrow_with(*key), 0);
            assert!(!pool_status::can_repay_with(*key), 0);
            assert!(!pool_status::can_switch_collateral_with(*key), 0);
            assert!(pool_status::can_borrow_asset_with_rebalance_with(*key), 0);
            assert!(pool_status::can_liquidate_with(*key), 0);
            i = i + 1;
        };
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_control_status_to_borrow_asset_with_rebalance(owner: &signer) {
        prepare_for_test(owner);
        disable_borrow_asset_with_rebalance<WETH>(owner);
        assert!(!pool_status::can_borrow_asset_with_rebalance<WETH>(), 0);
        enable_borrow_asset_with_rebalance<WETH>(owner);
        assert!(pool_status::can_borrow_asset_with_rebalance<WETH>(), 0);
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_control_borrow_asset_with_rebalance_for_all_pool(owner: &signer) {
        prepare_for_test(owner);
        pool_status::initialize_for_asset_for_test<USDC>(owner);
        pool_status::initialize_for_asset_for_test<USDT>(owner);
        pool_status::initialize_for_asset_for_test<UNI>(owner);

        // prerequisite
        let assets = pool_status::managed_assets();
        assert!(vector::borrow(&assets, 0) == &key<WETH>(), 0);
        assert!(vector::borrow(&assets, 1) == &key<USDC>(), 0);
        assert!(vector::borrow(&assets, 2) == &key<USDT>(), 0);
        assert!(vector::borrow(&assets, 3) == &key<UNI>(), 0);

        // execute
        disable_borrow_asset_with_rebalance_for_all_pool(owner);
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            assert!(pool_status::can_deposit_with(*key), 0);
            assert!(pool_status::can_withdraw_with(*key), 0);
            assert!(pool_status::can_borrow_with(*key), 0);
            assert!(pool_status::can_repay_with(*key), 0);
            assert!(pool_status::can_switch_collateral_with(*key), 0);
            assert!(!pool_status::can_borrow_asset_with_rebalance_with(*key), 0);
            assert!(pool_status::can_liquidate_with(*key), 0);
            i = i + 1;
        };
        enable_borrow_asset_with_rebalance_for_all_pool(owner);
        i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            assert!(pool_status::can_borrow_asset_with_rebalance_with(*key), 0);
            i = i + 1;
        };
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_control_status_to_repay_shadow_evenly(owner: &signer) {
        prepare_for_test(owner);
        disable_repay_shadow_evenly(owner);
        assert!(!pool_status::can_repay_shadow_evenly(), 0);
        enable_repay_shadow_evenly(owner);
        assert!(pool_status::can_repay_shadow_evenly(), 0);
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_control_status_to_liquidate(owner: &signer) {
        prepare_for_test(owner);
        disable_liquidate<WETH>(owner);
        assert!(!pool_status::can_liquidate<WETH>(), 0);
        enable_liquidate<WETH>(owner);
        assert!(pool_status::can_liquidate<WETH>(), 0);
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_control_liquidate_for_all_pool(owner: &signer) {
        prepare_for_test(owner);
        pool_status::initialize_for_asset_for_test<USDC>(owner);
        pool_status::initialize_for_asset_for_test<USDT>(owner);
        pool_status::initialize_for_asset_for_test<UNI>(owner);

        // prerequisite
        let assets = pool_status::managed_assets();
        assert!(vector::borrow(&assets, 0) == &key<WETH>(), 0);
        assert!(vector::borrow(&assets, 1) == &key<USDC>(), 0);
        assert!(vector::borrow(&assets, 2) == &key<USDT>(), 0);
        assert!(vector::borrow(&assets, 3) == &key<UNI>(), 0);

        // execute
        disable_liquidate_for_all_pool(owner);
        let i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            assert!(pool_status::can_deposit_with(*key), 0);
            assert!(pool_status::can_withdraw_with(*key), 0);
            assert!(pool_status::can_borrow_with(*key), 0);
            assert!(pool_status::can_repay_with(*key), 0);
            assert!(pool_status::can_switch_collateral_with(*key), 0);
            assert!(pool_status::can_borrow_asset_with_rebalance_with(*key), 0);
            assert!(!pool_status::can_liquidate_with(*key), 0);
            i = i + 1;
        };
        enable_liquidate_for_all_pool(owner);
        i = 0;
        while (i < vector::length(&assets)) {
            let key = vector::borrow<String>(&assets, i);
            assert!(pool_status::can_liquidate_with(*key), 0);
            i = i + 1;
        };
    }
    #[test(owner = @leizd_aptos_common, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_operate_pool_to_activate_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        activate_pool<WETH>(account);
    }
    #[test(owner = @leizd_aptos_common, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_activate_all_pool_without_operator(owner: &signer, account: &signer) {
        prepare_for_test(owner);
        activate_all_pool(account);
    }
    #[test(owner = @leizd_aptos_common, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_operate_pool_to_deactivate_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        deactivate_pool<WETH>(account);
    }
    #[test(owner = @leizd_aptos_common, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_deactivate_all_pool_without_operator(owner: &signer, account: &signer) {
        prepare_for_test(owner);
        deactivate_all_pool(account);
    }
    #[test(owner = @leizd_aptos_common, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_operate_pool_to_freeze_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        freeze_pool<WETH>(account);
    }
    #[test(owner = @leizd_aptos_common, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_freeze_all_pool_without_operator(owner: &signer, account: &signer) {
        prepare_for_test(owner);
        freeze_all_pool(account);
    }
    #[test(owner = @leizd_aptos_common, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_operate_pool_to_unfreeze_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        unfreeze_pool<WETH>(account);
    }
    #[test(owner = @leizd_aptos_common, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_unfreeze_all_pool_without_operator(owner: &signer, account: &signer) {
        prepare_for_test(owner);
        unfreeze_all_pool(account);
    }
    #[test(owner = @leizd_aptos_common, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_disable_borrow_asset_with_rebalance_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        disable_borrow_asset_with_rebalance<WETH>(account);
    }
    #[test(owner = @leizd_aptos_common, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_disable_borrow_asset_with_rebalance_for_all_pool_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        disable_borrow_asset_with_rebalance_for_all_pool(account);
    }
    #[test(owner = @leizd_aptos_common,account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_enable_borrow_asset_with_rebalance_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        enable_borrow_asset_with_rebalance<WETH>(account);
    }
    #[test(owner = @leizd_aptos_common,account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_enable_borrow_asset_with_rebalance_for_all_pool_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        enable_borrow_asset_with_rebalance_for_all_pool(account);
    }
    #[test(owner = @leizd_aptos_common,account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_disable_repay_shadow_evenly_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        disable_repay_shadow_evenly(account);
    }
    #[test(owner = @leizd_aptos_common,account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_enable_repay_shadow_evenly_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        enable_repay_shadow_evenly(account);
    }
    #[test(owner = @leizd_aptos_common,account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_disable_liquidate_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        disable_liquidate<WETH>(account);
    }
    #[test(owner = @leizd_aptos_common,account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_enable_liquidate_for_all_pool_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        enable_liquidate_for_all_pool(account);
    }
    #[test(owner = @leizd_aptos_common,account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_enable_liquidate_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        enable_liquidate<WETH>(account);
    }
    #[test(owner = @leizd_aptos_common,account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_disable_liquidate_for_all_pool_without_operator(owner: &signer, account: &signer) {
        permission::initialize(owner);
        disable_liquidate_for_all_pool(account);
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_operate_system_status(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        system_status::initialize(owner);
        assert!(system_status::status(), 0);
        pause_protocol(owner);
        assert!(!system_status::status(), 0);
        resume_protocol(owner);
        assert!(system_status::status(), 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_operate_system_status_to_pause_without_owner(account: &signer) {
        pause_protocol(account);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_operate_system_status_to_resume_without_owner(account: &signer) {
        resume_protocol(account);
    }
}
