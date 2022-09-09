module leizd::pool_status {
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
        let system_is_active = system_status::status();
        assert!(exists<Status<C>>(@leizd), E_IS_NOT_EXISTED);
        let pool_status_ref = borrow_global<Status<C>>(@leizd);
        system_is_active && pool_status_ref.active 
    }

    public(friend) fun update_status<C>(active: bool) acquires Status {
        let pool_status_ref = borrow_global_mut<Status<C>>(@leizd);
        pool_status_ref.active = active;
    }
}