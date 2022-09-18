module leizd::system_administrator {

    use std::signer;
    use leizd_aptos_common::permission;
    use leizd::pool_status;
    use leizd::system_status;

    public entry fun activate_pool<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        pool_status::update_deposit_status<C>(true);
        pool_status::update_withdraw_status<C>(true);
        pool_status::update_borrow_status<C>(true);
        pool_status::update_repay_status<C>(true);
    }

    public entry fun deactivate_pool<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        pool_status::update_deposit_status<C>(false);
        pool_status::update_withdraw_status<C>(false);
        pool_status::update_borrow_status<C>(false);
        pool_status::update_repay_status<C>(false);
    }

    public entry fun freeze_pool<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        pool_status::update_deposit_status<C>(false);
        pool_status::update_borrow_status<C>(false);
    }

    public entry fun unfreeze_pool<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        pool_status::update_deposit_status<C>(true);
        pool_status::update_borrow_status<C>(true);
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
    use leizd::risk_factor;
    #[test_only]
    use leizd::pool_manager;
    #[test_only]
    use leizd::test_coin::{Self, WETH};
    #[test_only]
    fun prepare_for_test(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_weth(owner);
        pool_manager::initialize(owner);
        risk_factor::initialize(owner);
        pool_manager::add_pool<WETH>(owner);
        system_status::initialize(owner);
    }
    #[test(owner = @leizd)]
    fun test_operate_pool_to_deactivate(owner: &signer) {
        prepare_for_test(owner);
        assert!(pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
        deactivate_pool<WETH>(owner);
        assert!(!pool_status::can_deposit<WETH>(), 0);
        assert!(!pool_status::can_withdraw<WETH>(), 0);
        assert!(!pool_status::can_borrow<WETH>(), 0);
        assert!(!pool_status::can_repay<WETH>(), 0);
    }
    #[test(owner = @leizd)]
    fun test_operate_pool_to_activate(owner: &signer) {
        prepare_for_test(owner);
        deactivate_pool<WETH>(owner);
        assert!(!pool_status::can_deposit<WETH>(), 0);
        assert!(!pool_status::can_withdraw<WETH>(), 0);
        assert!(!pool_status::can_borrow<WETH>(), 0);
        assert!(!pool_status::can_repay<WETH>(), 0);
        activate_pool<WETH>(owner);
        assert!(pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
    }
    #[test(owner = @leizd)]
    fun test_operate_pool_to_freeze(owner: &signer) {
        prepare_for_test(owner);
        assert!(pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
        freeze_pool<WETH>(owner);
        assert!(!pool_status::can_deposit<WETH>(), 0);
        assert!(!pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
    }
    #[test(owner = @leizd)]
    fun test_operate_pool_to_unfreeze(owner: &signer) {
        prepare_for_test(owner);
        freeze_pool<WETH>(owner);
        assert!(!pool_status::can_deposit<WETH>(), 0);
        assert!(!pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
        unfreeze_pool<WETH>(owner);
        assert!(pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_operate_pool_to_activate_without_owner(account: &signer) {
        activate_pool<WETH>(account);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_operate_pool_to_deactivate_without_owner(account: &signer) {
        deactivate_pool<WETH>(account);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_operate_pool_to_freeze_without_owner(account: &signer) {
        freeze_pool<WETH>(account);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_operate_pool_to_unfreeze_without_owner(account: &signer) {
        unfreeze_pool<WETH>(account);
    }
    #[test(owner = @leizd)]
    fun test_operate_system_status(owner: &signer) {
        system_status::initialize(owner);
        assert!(system_status::status(), 0);
        pause_protocol(owner);
        assert!(!system_status::status(), 0);
        resume_protocol(owner);
        assert!(system_status::status(), 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_operate_system_status_to_pause_without_owner(account: &signer) {
        pause_protocol(account);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_operate_system_status_to_resume_without_owner(account: &signer) {
        resume_protocol(account);
    }
}
