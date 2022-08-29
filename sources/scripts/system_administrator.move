module leizd::system_administrator {

    use std::signer;
    use leizd::permission;
    use leizd::pool;
    use leizd::system_status;

    public entry fun pause_pool<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        pool::update_status<C>(false);
    }

    public entry fun resume_pool<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        pool::update_status<C>(true);
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
    use leizd::repository;
    #[test_only]
    use leizd::test_coin::{Self, WETH};
    #[test(owner = @leizd)]
    fun test_operate_pool(owner: &signer) {
        let owner_address = signer::address_of(owner);
        account::create_account_for_test(owner_address);
        test_coin::init_weth(owner);
        repository::initialize(owner);
        pool::init_pool<WETH>(owner);
        system_status::initialize(owner);
        assert!(pool::is_available<WETH>(), 0);
        pause_pool<WETH>(owner);
        assert!(!pool::is_available<WETH>(), 0);
        resume_pool<WETH>(owner);
        assert!(pool::is_available<WETH>(), 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_operate_pool_to_pause_without_owner(account: &signer) {
        pause_pool<WETH>(account);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_operate_pool_to_resume_without_owner(account: &signer) {
        resume_pool<WETH>(account);
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