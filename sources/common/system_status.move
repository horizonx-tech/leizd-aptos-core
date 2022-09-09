module leizd::system_status { 

    use std::signer;
    use leizd::permission;

    friend leizd::system_administrator;

    struct SystemStatus has key {
        is_active: bool
    }

    public fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, SystemStatus { is_active: true });
    }

    public(friend) fun update_status(active: bool) acquires SystemStatus {
        let status_ref = borrow_global_mut<SystemStatus>(permission::owner_address());
        status_ref.is_active = active;
    }

    public fun status(): bool acquires SystemStatus {
        borrow_global<SystemStatus>(permission::owner_address()).is_active
    }

    #[test(owner = @leizd)]
    fun test_initialize(owner: &signer) {
        initialize(owner);
        assert!(exists<SystemStatus>(@leizd), 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_initialize_with_not_owner(account: &signer) {
        initialize(account);
    }
}