module leizd::pool_status {
    use std::error;
    use std::account;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_framework::type_info;
    use leizd_aptos_common::permission;
    use leizd::system_status;
    use aptos_std::event;

    friend leizd::system_administrator;
    friend leizd::asset_pool;

    const E_IS_NOT_EXISTED: u64 = 1;

    struct Status has key {
        can_deposit: simple_map::SimpleMap<String,bool>,
        can_withdraw: simple_map::SimpleMap<String,bool>,
        can_borrow: simple_map::SimpleMap<String,bool>,
        can_repay: simple_map::SimpleMap<String,bool>,
    }

    struct PoolStatusUpdateEvent has store, drop {
        can_deposit: bool,
        can_withdraw: bool,
        can_borrow: bool,
        can_repay: bool,
    }


    struct PoolStatusEventHandle has key, store {
        pool_status_update_event: event::EventHandle<PoolStatusUpdateEvent>
    }

    fun emit_current_pool_status(key: String) acquires Status, PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        let pool_status_ref = borrow_global<Status>(owner_address);
        event::emit_event<PoolStatusUpdateEvent>(
            &mut borrow_global_mut<PoolStatusEventHandle>(owner_address).pool_status_update_event,
                PoolStatusUpdateEvent {
                    can_deposit: *simple_map::borrow<String,bool>(&pool_status_ref.can_deposit, &key),
                    can_withdraw: *simple_map::borrow<String,bool>(&pool_status_ref.can_withdraw, &key),
                    can_borrow: *simple_map::borrow<String,bool>(&pool_status_ref.can_borrow, &key),
                    can_repay: *simple_map::borrow<String,bool>(&pool_status_ref.can_repay, &key)
            },
        );
    }

    public(friend) fun initialize<C>(owner: &signer) acquires Status {
        let key = type_info::type_name<C>();
        let owner_address = permission::owner_address();
        if (exists<Status>(owner_address)) {
            let status = borrow_global_mut<Status>(owner_address);
            simple_map::add<String,bool>(&mut status.can_deposit, key, true);
            simple_map::add<String,bool>(&mut status.can_withdraw, key, true);
            simple_map::add<String,bool>(&mut status.can_borrow, key, true);
            simple_map::add<String,bool>(&mut status.can_repay, key, true);
        } else {
            let status = Status {
                can_deposit: simple_map::create<String,bool>(),
                can_withdraw: simple_map::create<String,bool>(),
                can_borrow: simple_map::create<String,bool>(),
                can_repay: simple_map::create<String,bool>(),
            };
            simple_map::add<String,bool>(&mut status.can_deposit, key, true);
            simple_map::add<String,bool>(&mut status.can_withdraw, key, true);
            simple_map::add<String,bool>(&mut status.can_borrow, key, true);
            simple_map::add<String,bool>(&mut status.can_repay, key, true);
            move_to(owner, status);
        }
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
        assert!(is_initialized(owner_address, key), error::not_found(E_IS_NOT_EXISTED));
    }

    public fun can_deposit<C>(): bool acquires Status {
        let key = type_info::type_name<C>();
        can_deposit_with(key)
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
        let key = type_info::type_name<C>();
        can_withdraw_with(key)
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
        let key = type_info::type_name<C>();
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
        let key = type_info::type_name<C>();
        can_repay_with(key)
    }

    public fun can_repay_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        if (!simple_map::contains_key<String,bool>(&pool_status_ref.can_repay, &key)) return false;
        let can_repay = simple_map::borrow<String,bool>(&pool_status_ref.can_repay, &key);
        system_status::status() && *can_repay
    }

    public(friend) fun update_deposit_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        let key = type_info::type_name<C>();
        update_deposit_status_with(key, active);
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
        let key = type_info::type_name<C>();
        update_withdraw_status_with(key, active);
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
        let key = type_info::type_name<C>();
        update_borrow_status_with(key, active);
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
        let key = type_info::type_name<C>();
        update_repay_status_with(key, active);
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

    #[test_only]
    use std::signer;

    #[test_only]
    struct DummyStruct {}
    #[test(owner = @leizd)]
    fun test_end_to_end(owner: &signer) acquires Status, PoolStatusEventHandle {
        account::create_account_for_test(signer::address_of(owner));
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
