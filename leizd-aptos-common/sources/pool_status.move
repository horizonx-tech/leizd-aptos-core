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

    //// resources
    /// access control
    struct AssetManagerKey has store, drop {}

    struct Status has key {
        can_deposit: simple_map::SimpleMap<String,bool>,
        can_withdraw: simple_map::SimpleMap<String,bool>,
        can_borrow: simple_map::SimpleMap<String,bool>,
        can_repay: simple_map::SimpleMap<String,bool>,
        can_switch_collateral: simple_map::SimpleMap<String,bool>,
        can_borrow_asset_with_rebalance: simple_map::SimpleMap<String,bool>,
        can_repay_shadow_evenly: simple_map::SimpleMap<String,bool>,
        can_liquidate: simple_map::SimpleMap<String,bool>,
    }

    struct PoolStatusUpdateEvent has store, drop {
        key: String,
        can_deposit: bool,
        can_withdraw: bool,
        can_borrow: bool,
        can_repay: bool,
        can_switch_collateral: bool,
        can_borrow_asset_with_rebalance: bool,
        can_repay_shadow_evenly: bool,
        can_liquidate: bool,
    }

    struct PoolStatusEventHandle has key, store {
        pool_status_update_event: event::EventHandle<PoolStatusUpdateEvent>
    }

    public fun initialize(owner: &signer) {
        initialize_internal(owner);
    }
    fun initialize_internal(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, Status {
            can_deposit: simple_map::create<String,bool>(),
            can_withdraw: simple_map::create<String,bool>(),
            can_borrow: simple_map::create<String,bool>(),
            can_repay: simple_map::create<String,bool>(),
            // advanced function
            can_switch_collateral: simple_map::create<String,bool>(),
            can_borrow_asset_with_rebalance: simple_map::create<String,bool>(),
            can_repay_shadow_evenly: simple_map::create<String,bool>(),
            can_liquidate: simple_map::create<String,bool>(),
        });
        move_to(owner, PoolStatusEventHandle {
            pool_status_update_event: account::new_event_handle<PoolStatusUpdateEvent>(owner),
        });
    }
    //// access control
    public fun publish_asset_manager_key(owner: &signer): AssetManagerKey {
        permission::assert_owner(signer::address_of(owner));
        AssetManagerKey {}
    }

    public fun initialize_for_asset<C>(
        account: &signer,
        _key: &AssetManagerKey
    ) acquires Status, PoolStatusEventHandle {
        initialize_for_asset_internal<C>(account);
    }
    fun initialize_for_asset_internal<C>(_account: &signer) acquires Status, PoolStatusEventHandle {
        let owner_addr = permission::owner_address();
        let key = key<C>();
        let status = borrow_global_mut<Status>(owner_addr);
        initialize_status(key, status);
        emit_current_pool_status(key);
    }
    fun initialize_status(key: String, status: &mut Status) {
        simple_map::add<String,bool>(&mut status.can_deposit, key, true);
        simple_map::add<String,bool>(&mut status.can_withdraw, key, true);
        simple_map::add<String,bool>(&mut status.can_borrow, key, true);
        simple_map::add<String,bool>(&mut status.can_repay, key, true);
        simple_map::add<String,bool>(&mut status.can_switch_collateral, key, true);
        simple_map::add<String,bool>(&mut status.can_borrow_asset_with_rebalance, key, true);
        simple_map::add<String,bool>(&mut status.can_repay_shadow_evenly, key, true);
        simple_map::add<String,bool>(&mut status.can_liquidate, key, true);
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
                    can_switch_collateral: *simple_map::borrow<String,bool>(&pool_status_ref.can_switch_collateral, &key),
                    can_borrow_asset_with_rebalance: *simple_map::borrow<String,bool>(&pool_status_ref.can_borrow_asset_with_rebalance, &key),
                    can_repay_shadow_evenly: *simple_map::borrow<String,bool>(&pool_status_ref.can_repay_shadow_evenly, &key),
                    can_liquidate: *simple_map::borrow<String,bool>(&pool_status_ref.can_liquidate, &key),
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

    public fun can_borrow_asset_with_rebalance<C>(): bool acquires Status {
        can_borrow_asset_with_rebalance_with(key<C>())
    }

    public fun can_borrow_asset_with_rebalance_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        if (!simple_map::contains_key<String,bool>(&pool_status_ref.can_borrow_asset_with_rebalance, &key)) return false;
        let can_borrow_asset_with_rebalance = simple_map::borrow<String,bool>(&pool_status_ref.can_borrow_asset_with_rebalance, &key);
        system_status::status() && *can_borrow_asset_with_rebalance
    }

    public fun can_repay_shadow_evenly<C>(): bool acquires Status {
        can_repay_shadow_evenly_with(key<C>())
    }

    public fun can_repay_shadow_evenly_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        if (!simple_map::contains_key<String,bool>(&pool_status_ref.can_repay_shadow_evenly, &key)) return false;
        let can_repay_shadow_evenly = simple_map::borrow<String,bool>(&pool_status_ref.can_repay_shadow_evenly, &key);
        system_status::status() && *can_repay_shadow_evenly
    }

    public fun can_liquidate<C>(): bool acquires Status {
        can_liquidate_with(key<C>())
    }

    public fun can_liquidate_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        if (!simple_map::contains_key<String,bool>(&pool_status_ref.can_liquidate, &key)) return false;
        let can_liquidate = simple_map::borrow<String,bool>(&pool_status_ref.can_liquidate, &key);
        system_status::status() && *can_liquidate
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

    public(friend) fun update_borrow_asset_with_rebalance_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_borrow_asset_with_rebalance_status_with(key<C>(), active);
    }

    public(friend) fun update_borrow_asset_with_rebalance_status_with(key: String, active: bool) acquires Status , PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        assert!(simple_map::contains_key<String,bool>(&pool_status_ref.can_borrow_asset_with_rebalance, &key), 0);
        let can_borrow_asset_with_rebalance = simple_map::borrow_mut<String,bool>(&mut pool_status_ref.can_borrow_asset_with_rebalance, &key);
        *can_borrow_asset_with_rebalance = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_repay_shadow_evenly_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_repay_shadow_evenly_status_with(key<C>(), active);
    }

    public(friend) fun update_repay_shadow_evenly_status_with(key: String, active: bool) acquires Status , PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        assert!(simple_map::contains_key<String,bool>(&pool_status_ref.can_repay_shadow_evenly, &key), 0);
        let can_repay_shadow_evenly = simple_map::borrow_mut<String,bool>(&mut pool_status_ref.can_repay_shadow_evenly, &key);
        *can_repay_shadow_evenly = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_liquidate_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_liquidate_status_with(key<C>(), active);
    }

    public(friend) fun update_liquidate_status_with(key: String, active: bool) acquires Status , PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        assert_pool_status_initialized(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        assert!(simple_map::contains_key<String,bool>(&pool_status_ref.can_liquidate, &key), 0);
        let can_liquidate = simple_map::borrow_mut<String,bool>(&mut pool_status_ref.can_liquidate, &key);
        *can_liquidate = active;
        emit_current_pool_status(key);
    }

    #[test_only]
    public fun initialize_for_asset_for_test<C>(owner: &signer) acquires Status, PoolStatusEventHandle {
        initialize_for_asset_internal<C>(owner);
    }
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
    #[test_only]
    public fun update_borrow_asset_with_rebalance_status_for_test<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_borrow_asset_with_rebalance_status<C>(active);
    }
    #[test_only]
    public fun update_repay_shadow_evenly_status_for_test<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_repay_shadow_evenly_status<C>(active);
    }
    #[test_only]
    public fun update_liquidate_status_for_test<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_liquidate_status<C>(active);
    }
    #[test_only]
    struct DummyStruct {}
    #[test(owner = @leizd_aptos_common)]
    fun test_end_to_end(owner: &signer) acquires Status, PoolStatusEventHandle {
        account::create_account_for_test(signer::address_of(owner));
        system_status::initialize(owner);
        initialize(owner);
        initialize_for_asset_internal<DummyStruct>(owner);
        assert!(can_deposit<DummyStruct>(), 0);
        assert!(can_withdraw<DummyStruct>(), 0);
        assert!(can_borrow<DummyStruct>(), 0);
        assert!(can_repay<DummyStruct>(), 0);
        assert!(can_switch_collateral<DummyStruct>(), 0);
        assert!(can_borrow_asset_with_rebalance<DummyStruct>(), 0);
        assert!(can_repay_shadow_evenly<DummyStruct>(), 0);
        assert!(can_liquidate<DummyStruct>(), 0);
        update_deposit_status<DummyStruct>(false);
        update_withdraw_status<DummyStruct>(false);
        update_borrow_status<DummyStruct>(false);
        update_repay_status<DummyStruct>(false);
        update_switch_collateral_status<DummyStruct>(false);
        update_borrow_asset_with_rebalance_status<DummyStruct>(false);
        update_repay_shadow_evenly_status<DummyStruct>(false);
        update_liquidate_status<DummyStruct>(false);
        assert!(!can_deposit<DummyStruct>(), 0);
        assert!(!can_withdraw<DummyStruct>(), 0);
        assert!(!can_borrow<DummyStruct>(), 0);
        assert!(!can_repay<DummyStruct>(), 0);
        assert!(!can_switch_collateral<DummyStruct>(), 0);
        assert!(!can_borrow_asset_with_rebalance<DummyStruct>(), 0);
        assert!(!can_repay_shadow_evenly<DummyStruct>(), 0);
        assert!(!can_liquidate<DummyStruct>(), 0);
    }
}
