module leizd::pool_status {
    use std::error;
    use leizd_aptos_common::permission;
    use leizd::system_status;

    friend leizd::system_administrator;
    friend leizd::asset_pool;

    const E_IS_NOT_EXISTED: u64 = 1;

    struct Status<phantom C> has key {
        can_deposit: bool,
        can_withdraw: bool,
        can_borrow: bool,
        can_repay: bool
    }

    public(friend) fun initialize<C>(owner: &signer) {
        move_to(owner, Status<C> {
            can_deposit: true,
            can_withdraw: true,
            can_borrow: true,
            can_repay: true
        });
    }

    fun assert_pool_status_initialized<C>(owner_address: address) {
        assert!(exists<Status<C>>(owner_address), error::invalid_argument(E_IS_NOT_EXISTED));
    }

    public fun can_deposit<C>(): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global<Status<C>>(owner_address);
        system_status::status() && pool_status_ref.can_deposit
    }

    public fun can_withdraw<C>(): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global<Status<C>>(owner_address);
        system_status::status() && pool_status_ref.can_withdraw
    }

    public fun can_borrow<C>(): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global<Status<C>>(owner_address);
        system_status::status() && pool_status_ref.can_borrow
    }

    public fun can_repay<C>(): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global<Status<C>>(owner_address);
        system_status::status() && pool_status_ref.can_repay
    }

    public(friend) fun update_deposit_status<C>(active: bool) acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global_mut<Status<C>>(owner_address);
        pool_status_ref.can_deposit = active;
    }

    public(friend) fun update_withdraw_status<C>(active: bool) acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global_mut<Status<C>>(owner_address);
        pool_status_ref.can_withdraw = active;
    }

    public(friend) fun update_borrow_status<C>(active: bool) acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global_mut<Status<C>>(owner_address);
        pool_status_ref.can_borrow = active;
    }

    public(friend) fun update_repay_status<C>(active: bool) acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global_mut<Status<C>>(owner_address);
        pool_status_ref.can_repay = active;
    }

    #[test_only]
    struct DummyStruct {}
    #[test(owner = @leizd)]
    fun test_end_to_end(owner: &signer) acquires Status {
        system_status::initialize(owner);
        initialize<DummyStruct>(owner);
        assert!(can_deposit<DummyStruct>(), 0);
        assert!(can_withdraw<DummyStruct>(), 0);
        assert!(can_borrow<DummyStruct>(), 0);
        assert!(can_repay<DummyStruct>(), 0);
        update_deposit_status<DummyStruct>(false);
        update_withdraw_status<DummyStruct>(false);
        update_borrow_status<DummyStruct>(false);
        update_repay_status<DummyStruct>(false);
        assert!(!can_deposit<DummyStruct>(), 0);
        assert!(!can_withdraw<DummyStruct>(), 0);
        assert!(!can_borrow<DummyStruct>(), 0);
        assert!(!can_repay<DummyStruct>(), 0);
    }
}
