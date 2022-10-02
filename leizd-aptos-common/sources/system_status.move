module leizd_aptos_common::system_status { 

    use std::signer;
    use std::event;
    use std::account;
    use leizd_aptos_common::permission;

    friend leizd_aptos_common::system_administrator;

    struct SystemStatus has key {
        is_active: bool
    }

    struct SystemStatusUpdateEvent has store, drop {
        is_active: bool,
    }
    struct SystemStatusEventHandle has key, store {
        system_status_update_event: event::EventHandle<SystemStatusUpdateEvent>,
    }

    public fun initialize(owner: &signer) acquires SystemStatus, SystemStatusEventHandle {
        let owner_address = signer::address_of(owner);
        permission::assert_owner(owner_address);
        move_to(owner, SystemStatus { is_active: true });
        move_to(owner, SystemStatusEventHandle {
            system_status_update_event: account::new_event_handle<SystemStatusUpdateEvent>(owner)
        });
        emit_current_system_status();
    }

    fun emit_current_system_status() acquires SystemStatus, SystemStatusEventHandle {
        let owner_address = permission::owner_address();
        let status = borrow_global<SystemStatus>(owner_address);
        event::emit_event<SystemStatusUpdateEvent>(
            &mut borrow_global_mut<SystemStatusEventHandle>(owner_address).system_status_update_event,
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

    #[test(owner = @leizd_aptos_common)]
    fun test_end_to_end(owner: &signer) acquires SystemStatus, SystemStatusEventHandle {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        assert!(exists<SystemStatus>(@leizd_aptos_common), 0);
        assert!(status(), 0);
        assert!(event::counter<SystemStatusUpdateEvent>(&borrow_global<SystemStatusEventHandle>(owner_addr).system_status_update_event) == 1, 0);

        update_status(false);        
        assert!(!status(), 0);
        assert!(event::counter<SystemStatusUpdateEvent>(&borrow_global<SystemStatusEventHandle>(owner_addr).system_status_update_event) == 2, 0);
    }
    #[test(account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_with_not_owner(account: &signer) acquires SystemStatus, SystemStatusEventHandle {
        account::create_account_for_test(signer::address_of(account));
        initialize(account);
    }
}