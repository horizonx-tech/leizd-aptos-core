module leizd_aptos_common::pool_status {
    use std::error;
    use std::account;
    use std::signer;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map;
    use leizd_aptos_common::permission;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::system_status;

    friend leizd_aptos_common::system_administrator;

    const EIS_NOT_EXISTED: u64 = 1;

    struct Status has key {
        can_deposit: simple_map::SimpleMap<String,bool>,
        can_withdraw: simple_map::SimpleMap<String,bool>,
        can_borrow: simple_map::SimpleMap<String,bool>,
        can_repay: simple_map::SimpleMap<String,bool>,
        can_switch_collateral: simple_map::SimpleMap<String,bool>,
    }

    struct PoolStatusUpdateEvent has store, drop {
        key: String,
        can_deposit: bool,
        can_withdraw: bool,
        can_borrow: bool,
        can_repay: bool,
        can_switch_collateral: bool,
    }


    struct PoolStatusEventHandle has key, store {
        pool_status_update_event: event::EventHandle<PoolStatusUpdateEvent>
    }

    public fun initialize<C>(owner: &signer) acquires Status, PoolStatusEventHandle {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr); // NOTE: remove this validation if permission less
        let key = key<C>();
        if (exists<Status>(owner_addr)) {
            let status = borrow_global_mut<Status>(owner_addr);
            initialize_status(key, status);
        } else {
            let status = Status {
                can_deposit: simple_map::create<String,bool>(),
                can_withdraw: simple_map::create<String,bool>(),
                can_borrow: simple_map::create<String,bool>(),
                can_repay: simple_map::create<String,bool>(),
                can_switch_collateral: simple_map::create<String,bool>(),
            };
            initialize_status(key, &mut status);
            move_to(owner, status);
            move_to(owner, PoolStatusEventHandle {
                pool_status_update_event: account::new_event_handle<PoolStatusUpdateEvent>(owner),
            });
        };
        emit_current_pool_status(key);
    }
    fun initialize_status(key: String, status: &mut Status) {
        simple_map::add<String,bool>(&mut status.can_deposit, key, true);
        simple_map::add<String,bool>(&mut status.can_withdraw, key, true);
        simple_map::add<String,bool>(&mut status.can_borrow, key, true);
        simple_map::add<String,bool>(&mut status.can_repay, key, true);
        simple_map::add<String,bool>(&mut status.can_switch_collateral, key, true);
    }

    fun emit_current_pool_status(key: String) acquires Status, PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        let pool_status_ref = borrow_global<Status>(owner_address);
        event::emit_event<PoolStatusUpdateEvent>(
            &mut borrow_global_mut<PoolStatusEventHandle>(owner_address).pool_status_update_event,
                PoolStatusUpdateEvent {
                    key,
                    can_deposit: *simple_map::borrow<String,bool>(&pool_status_ref.can_deposit, &key),
                    can_withdraw: *simple_map::borrow<String,bool>(&pool_status_ref.can_withdraw, &key),
                    can_borrow: *simple_map::borrow<String,bool>(&pool_status_ref.can_borrow, &key),
                    can_repay: *simple_map::borrow<String,bool>(&pool_status_ref.can_repay, &key),
                    can_switch_collateral: *simple_map::borrow<String,bool>(&pool_status_ref.can_switch_collateral, &key)
            },
        );
    }

    fun is_initialized(owner_address: address, key: String): bool acquires Status {
        if (!exists<Status>(owner_address)) {
            false
        } else {
            let status = borrow_global_mut<Status>(owner_address);
            simple_map::contains_key<String,bool>(&status.can_deposit, &key)
        }
    }

    fun assert_pool_status_initialized(owner_address: address, key: String) acquires Status {
        assert!(is_initialized(owner_address, key), error::invalid_argument(EIS_NOT_EXISTED));
    }

    //// view functions
    public fun can_deposit<C>(): bool acquires Status {
        can_deposit_with(key<C>())
    }

    public fun can_deposit_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        if (!simple_map::contains_key<String,bool>(&pool_status_ref.can_deposit, &key)) return false;
        let can_deposit = simple_map::borrow<String,bool>(&pool_status_ref.can_deposit, &key);
        system_status::status() && *can_deposit
    }

    public fun can_withdraw<C>(): bool acquires Status {
        can_withdraw_with(key<C>())
    }

    public fun can_withdraw_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        if (!simple_map::contains_key<String,bool>(&pool_status_ref.can_withdraw, &key)) return false;
        let can_withdraw = simple_map::borrow<String,bool>(&pool_status_ref.can_withdraw, &key);
        system_status::status() && *can_withdraw
    }

    public fun can_borrow<C>(): bool acquires Status {
        let key = key<C>();
        can_borrow_with(key)
    }

    public fun can_borrow_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        if (!simple_map::contains_key<String,bool>(&pool_status_ref.can_borrow, &key)) return false;
        let can_borrow = simple_map::borrow<String,bool>(&pool_status_ref.can_borrow, &key);
        system_status::status() && *can_borrow
    }

    public fun can_repay<C>(): bool acquires Status {
        can_repay_with(key<C>())
    }

    public fun can_repay_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        if (!simple_map::contains_key<String,bool>(&pool_status_ref.can_repay, &key)) return false;
        let can_repay = simple_map::borrow<String,bool>(&pool_status_ref.can_repay, &key);
        system_status::status() && *can_repay
    }

    public fun can_switch_collateral<C>(): bool acquires Status {
        can_switch_collateral_with(key<C>())
    }

    public fun can_switch_collateral_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        if (!simple_map::contains_key<String,bool>(&pool_status_ref.can_switch_collateral, &key)) return false;
        let can_switch_collateral = simple_map::borrow<String,bool>(&pool_status_ref.can_switch_collateral, &key);
        system_status::status() && *can_switch_collateral
    }

    //// functions to update status
    public(friend) fun update_deposit_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_deposit_status_with(key<C>(), active);
    }

    public(friend) fun update_deposit_status_with(key: String, active: bool) acquires Status, PoolStatusEventHandle {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        assert!(simple_map::contains_key<String,bool>(&pool_status_ref.can_deposit, &key), 0);
        let can_deposit = simple_map::borrow_mut<String,bool>(&mut pool_status_ref.can_deposit, &key);
        *can_deposit = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_withdraw_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_withdraw_status_with(key<C>(), active);
    }

    public(friend) fun update_withdraw_status_with(key: String, active: bool) acquires Status, PoolStatusEventHandle {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        assert!(simple_map::contains_key<String,bool>(&pool_status_ref.can_withdraw, &key), 0);
        let can_withdraw = simple_map::borrow_mut<String,bool>(&mut pool_status_ref.can_withdraw, &key);
        *can_withdraw = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_borrow_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_borrow_status_with(key<C>(), active);
    }

    public(friend) fun update_borrow_status_with(key: String, active: bool) acquires Status, PoolStatusEventHandle {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        assert!(simple_map::contains_key<String,bool>(&pool_status_ref.can_borrow, &key), 0);
        let can_borrow = simple_map::borrow_mut<String,bool>(&mut pool_status_ref.can_borrow, &key);
        *can_borrow = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_repay_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_repay_status_with(key<C>(), active);
    }

    public(friend) fun update_repay_status_with(key: String, active: bool) acquires Status , PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        assert!(simple_map::contains_key<String,bool>(&pool_status_ref.can_repay, &key), 0);
        let can_repay = simple_map::borrow_mut<String,bool>(&mut pool_status_ref.can_repay, &key);
        *can_repay = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_switch_collateral_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_switch_collateral_status_with(key<C>(), active);
    }

    public(friend) fun update_switch_collateral_status_with(key: String, active: bool) acquires Status , PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        assert!(simple_map::contains_key<String,bool>(&pool_status_ref.can_switch_collateral, &key), 0);
        let can_switch_collateral = simple_map::borrow_mut<String,bool>(&mut pool_status_ref.can_switch_collateral, &key);
        *can_switch_collateral = active;
        emit_current_pool_status(key);
    }

    #[test_only]
    struct DummyStruct {}
    #[test_only]
    public fun update_deposit_status_for_test<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_deposit_status<C>(active);
    }
    #[test_only]
    public fun update_withdraw_status_for_test<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_withdraw_status<C>(active);
    }
    #[test_only]
    public fun update_borrow_status_for_test<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_borrow_status<C>(active);
    }
    #[test_only]
    public fun update_repay_status_for_test<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_repay_status<C>(active);
    }
    #[test_only]
    public fun update_switch_collateral_status_for_test<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_switch_collateral_status<C>(active);
    }
    #[test(owner = @leizd_aptos_common)]
    fun test_end_to_end(owner: &signer) acquires Status, PoolStatusEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        system_status::initialize(owner);
        initialize<DummyStruct>(owner);
        assert!(can_deposit<DummyStruct>(), 0);
        assert!(can_withdraw<DummyStruct>(), 0);
        assert!(can_borrow<DummyStruct>(), 0);
        assert!(can_repay<DummyStruct>(), 0);
        assert!(can_switch_collateral<DummyStruct>(), 0);
        update_deposit_status<DummyStruct>(false);
        update_withdraw_status<DummyStruct>(false);
        update_borrow_status<DummyStruct>(false);
        update_repay_status<DummyStruct>(false);
        update_switch_collateral_status<DummyStruct>(false);
        assert!(!can_deposit<DummyStruct>(), 0);
        assert!(!can_withdraw<DummyStruct>(), 0);
        assert!(!can_borrow<DummyStruct>(), 0);
        assert!(!can_repay<DummyStruct>(), 0);
        assert!(!can_switch_collateral<DummyStruct>(), 0);
    }
}
