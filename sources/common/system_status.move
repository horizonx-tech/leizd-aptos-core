module leizd::system_status { 

    friend leizd::system_administrator;

    struct SystemStatus has key {
        is_active: bool
    }

    public fun initialize(owner: &signer) {
        move_to(owner, SystemStatus { is_active: true });
    }

    public(friend) fun update_status(active: bool) acquires SystemStatus {
        let status_ref = borrow_global_mut<SystemStatus>(@leizd);
        status_ref.is_active = active;
    }

    public fun status(): bool acquires SystemStatus {
        borrow_global<SystemStatus>(@leizd).is_active
    }
}