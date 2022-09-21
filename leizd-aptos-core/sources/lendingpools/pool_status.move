module leizd::pool_status {
    use std::error;
    use std::account;
    use leizd_aptos_common::permission;
    use leizd::system_status;
    use aptos_std::event;

    friend leizd::system_administrator;
    friend leizd::asset_pool;

    const E_IS_NOT_EXISTED: u64 = 1;

    struct Status<phantom C> has key {
        can_deposit: bool,
        can_withdraw: bool,
        can_borrow: bool,
        can_repay: bool
    }

    public(friend) fun initialize<C>(owner: &signer) acquires Status, PoolStatusEventHandle {
        move_to(owner, Status<C> {
            can_deposit: true,
            can_withdraw: true,
            can_borrow: true,
            can_repay: true
        });
        move_to(owner, PoolStatusEventHandle<C> {
            pool_status_update_event: account::new_event_handle<PoolStatusUpdateEvent>(owner),
        });
        emit_current_pool_status<C>();
    }

    struct PoolStatusUpdateEvent has store, drop {
        can_deposit: bool,
        can_withdraw: bool,
        can_borrow: bool,
        can_repay: bool,
    }


    struct PoolStatusEventHandle<phantom C> has key, store {
        pool_status_update_event: event::EventHandle<PoolStatusUpdateEvent>
    }

    fun emit_current_pool_status<C>() acquires Status, PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        let pool_status_ref = borrow_global<Status<C>>(owner_address);
        event::emit_event<PoolStatusUpdateEvent>(
            &mut borrow_global_mut<PoolStatusEventHandle<C>>(owner_address).pool_status_update_event,
                PoolStatusUpdateEvent {
                    can_deposit: pool_status_ref.can_deposit,
                    can_withdraw: pool_status_ref.can_withdraw,
                    can_borrow: pool_status_ref.can_borrow,
                    can_repay: pool_status_ref.can_repay
            },
        );             
    }

    fun assert_pool_status_initialized<C>(owner_address: address) {
        assert!(exists<Status<C>>(owner_address), error::not_found(E_IS_NOT_EXISTED));
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

    public(friend) fun update_deposit_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global_mut<Status<C>>(owner_address);
        pool_status_ref.can_deposit = active;
        emit_current_pool_status<C>();
    }

    public(friend) fun update_withdraw_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global_mut<Status<C>>(owner_address);
        pool_status_ref.can_withdraw = active;
        emit_current_pool_status<C>();
    }

    public(friend) fun update_borrow_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global_mut<Status<C>>(owner_address);
        pool_status_ref.can_borrow = active;
        emit_current_pool_status<C>();
    }

    public(friend) fun update_repay_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized<C>(owner_address);
        let pool_status_ref = borrow_global_mut<Status<C>>(owner_address);
        pool_status_ref.can_repay = active;
        emit_current_pool_status<C>();
    }

    #[test_only]
    struct DummyStruct {}
    #[test(owner = @leizd)]
    fun test_end_to_end(owner: &signer) acquires Status, PoolStatusEventHandle{
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
