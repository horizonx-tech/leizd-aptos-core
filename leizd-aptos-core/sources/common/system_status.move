module leizd::system_status { 

    use std::signer;
    use std::event;
    use leizd_aptos_common::permission;

    friend leizd::system_administrator;

    struct SystemStatus has key {
        is_active: bool
    }

    struct SystemStatusUpdateEvent has store, drop {
        is_active: bool,
    }
    struct SystemStatusEventHandle has key, store {
        system_status_upadte_event: event::EventHandle<SystemStatusUpdateEvent>,
    }

    public fun initialize(owner: &signer) acquires SystemStatus, SystemStatusEventHandle {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);
        move_to(owner, SystemStatus { is_active: true });
        emit_current_system_status();
    }

    fun emit_current_system_status() acquires SystemStatus, SystemStatusEventHandle {
        let owner_address = permission::owner_address();
        let status = borrow_global<SystemStatus>(owner_address);
        event::emit_event<SystemStatusUpdateEvent>(
            &mut borrow_global_mut<SystemStatusEventHandle>(owner_address).system_status_upadte_event,
                SystemStatusUpdateEvent {
                    is_active: status.is_active,
            },
        );
    }

    public(friend) fun update_status(active: bool) acquires SystemStatus, SystemStatusEventHandle {
        let status_ref = borrow_global_mut<SystemStatus>(permission::owner_address());
        status_ref.is_active = active;
        emit_current_system_status();
    }

    public fun status(): bool acquires SystemStatus {
        borrow_global<SystemStatus>(permission::owner_address()).is_active
    }

    #[test(owner = @leizd)]
    fun test_initialize(owner: &signer) acquires SystemStatus, SystemStatusEventHandle {
        initialize(owner);
        assert!(exists<SystemStatus>(@leizd), 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 1)]
    fun test_initialize_with_not_owner(account: &signer) acquires SystemStatus, SystemStatusEventHandle {
        initialize(account);
    }
}