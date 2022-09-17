module leizd::pool_status {
    use leizd_aptos_common::permission;
    use leizd::system_status;

    friend leizd::system_administrator;
    friend leizd::asset_pool;

    const E_IS_NOT_EXISTED: u64 = 1;

    struct Status<phantom C> has key {
        active: bool
    }

    public(friend) fun initialize<C>(owner: &signer) {
        move_to(owner, Status<C> {
            active: true
        });
    }

    public fun is_available<C>(): bool acquires Status {
        let owner_address = permission::owner_address();
        assert!(exists<Status<C>>(owner_address), E_IS_NOT_EXISTED);
        let system_is_active = system_status::status();
        let pool_status_ref = borrow_global<Status<C>>(owner_address);
        system_is_active && pool_status_ref.active 
    }

    public(friend) fun update_status<C>(active: bool) acquires Status {
        let pool_status_ref = borrow_global_mut<Status<C>>(permission::owner_address());
        pool_status_ref.active = active;
    }

    #[test_only]
    struct DummyStruct {}
    #[test(owner = @leizd)]
    fun test_end_to_end(owner: &signer) acquires Status {
        system_status::initialize(owner);
        initialize<DummyStruct>(owner);
        assert!(is_available<DummyStruct>(), 0);
        update_status<DummyStruct>(false);
        assert!(!is_available<DummyStruct>(), 0);
    }
}