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

    const ENOT_INITIALIZED: u64 = 1;
    const ENOT_INITIALIZED_ASSET: u64 = 2;

    //// resources
    /// access control
    struct AssetManagerKey has store, drop {}

    struct Status has key {
        can_repay_shadow_evenly: bool,
        assets: simple_map::SimpleMap<String, AssetStatus>,
    }

    struct AssetStatus has store {
        can_deposit: bool,
        can_withdraw: bool,
        can_borrow: bool,
        can_repay: bool,
        can_switch_collateral: bool,
        can_borrow_asset_with_rebalance: bool,
        can_liquidate: bool,
    }

    struct PoolStatusUpdateEvent has store, drop {
        key: String,
        can_deposit: bool,
        can_withdraw: bool,
        can_borrow: bool,
        can_repay: bool,
        can_switch_collateral: bool,
        can_borrow_asset_with_rebalance: bool,
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
            can_repay_shadow_evenly: true,
            assets: simple_map::create<String, AssetStatus>(),
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
        let asset_statuses = &mut borrow_global_mut<Status>(owner_addr).assets;
        simple_map::add(asset_statuses, key, AssetStatus {
            can_deposit: true,
            can_withdraw: true,
            can_borrow: true,
            can_repay: true,
            can_switch_collateral: true,
            can_borrow_asset_with_rebalance: true,
            can_liquidate: true,
        });
        emit_current_pool_status(key);
    }

    fun emit_current_pool_status(key: String) acquires Status, PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        let asset_status_ref = simple_map::borrow(&borrow_global<Status>(owner_address).assets, &key);
        event::emit_event<PoolStatusUpdateEvent>(
            &mut borrow_global_mut<PoolStatusEventHandle>(owner_address).pool_status_update_event,
                PoolStatusUpdateEvent {
                    key: copy key,
                    can_deposit: asset_status_ref.can_deposit,
                    can_withdraw: asset_status_ref.can_withdraw,
                    can_borrow: asset_status_ref.can_borrow,
                    can_repay: asset_status_ref.can_repay,
                    can_switch_collateral: asset_status_ref.can_switch_collateral,
                    can_borrow_asset_with_rebalance: asset_status_ref.can_borrow_asset_with_rebalance,
                    can_liquidate: asset_status_ref.can_liquidate,
            },
        );
    }

    fun is_initialized(owner_address: address): bool {
        exists<Status>(owner_address)
    }
    fun assert_is_initialized(owner_address: address) {
        assert!(is_initialized(owner_address), error::invalid_argument(ENOT_INITIALIZED));
    }

    fun is_initialized_asset(owner_address: address, key: String): bool acquires Status {
        if (is_initialized(owner_address)) {
            let status = borrow_global_mut<Status>(owner_address);
            simple_map::contains_key(&status.assets, &key)
        } else {
            false
        }
    }
    fun assert_is_initialized_asset(owner_address: address, key: String) acquires Status {
        assert!(is_initialized_asset(owner_address, key), error::invalid_argument(ENOT_INITIALIZED_ASSET));
    }

    //// view functions
    public fun can_deposit<C>(): bool acquires Status {
        can_deposit_with(key<C>())
    }

    public fun can_deposit_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        let asset_status = simple_map::borrow(&pool_status_ref.assets, &key);
        system_status::status() && asset_status.can_deposit
    }

    public fun can_withdraw<C>(): bool acquires Status {
        can_withdraw_with(key<C>())
    }

    public fun can_withdraw_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        let asset_status = simple_map::borrow(&pool_status_ref.assets, &key);
        system_status::status() && asset_status.can_withdraw
    }

    public fun can_borrow<C>(): bool acquires Status {
        let key = key<C>();
        can_borrow_with(key)
    }

    public fun can_borrow_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        let asset_status = simple_map::borrow(&pool_status_ref.assets, &key);
        system_status::status() && asset_status.can_borrow
    }

    public fun can_repay<C>(): bool acquires Status {
        can_repay_with(key<C>())
    }

    public fun can_repay_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        let asset_status = simple_map::borrow(&pool_status_ref.assets, &key);
        system_status::status() && asset_status.can_repay
    }

    public fun can_switch_collateral<C>(): bool acquires Status {
        can_switch_collateral_with(key<C>())
    }

    public fun can_switch_collateral_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        let asset_status = simple_map::borrow(&pool_status_ref.assets, &key);
        system_status::status() && asset_status.can_switch_collateral
    }

    public fun can_borrow_asset_with_rebalance<C>(): bool acquires Status {
        can_borrow_asset_with_rebalance_with(key<C>())
    }

    public fun can_borrow_asset_with_rebalance_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        let asset_status = simple_map::borrow(&pool_status_ref.assets, &key);
        system_status::status() && asset_status.can_borrow_asset_with_rebalance
    }

    public fun can_repay_shadow_evenly(): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_is_initialized(owner_address);
        let pool_status_ref = borrow_global<Status>(owner_address);
        system_status::status() && pool_status_ref.can_repay_shadow_evenly
    }

    public fun can_liquidate<C>(): bool acquires Status {
        can_liquidate_with(key<C>())
    }

    public fun can_liquidate_with(key: String): bool acquires Status {
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global<Status>(owner_address);
        let asset_status = simple_map::borrow(&pool_status_ref.assets, &key);
        system_status::status() && asset_status.can_liquidate
    }

    //// functions to update status
    public(friend) fun update_deposit_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_deposit_status_with(key<C>(), active);
    }

    public(friend) fun update_deposit_status_with(key: String, active: bool) acquires Status, PoolStatusEventHandle {
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        let asset_status = simple_map::borrow_mut(&mut pool_status_ref.assets, &key);
        asset_status.can_deposit = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_withdraw_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_withdraw_status_with(key<C>(), active);
    }

    public(friend) fun update_withdraw_status_with(key: String, active: bool) acquires Status, PoolStatusEventHandle {
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        let asset_status = simple_map::borrow_mut(&mut pool_status_ref.assets, &key);
        asset_status.can_withdraw = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_borrow_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_borrow_status_with(key<C>(), active);
    }

    public(friend) fun update_borrow_status_with(key: String, active: bool) acquires Status, PoolStatusEventHandle {
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        let asset_status = simple_map::borrow_mut(&mut pool_status_ref.assets, &key);
        asset_status.can_borrow = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_repay_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_repay_status_with(key<C>(), active);
    }

    public(friend) fun update_repay_status_with(key: String, active: bool) acquires Status, PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        let asset_status = simple_map::borrow_mut(&mut pool_status_ref.assets, &key);
        asset_status.can_repay = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_switch_collateral_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_switch_collateral_status_with(key<C>(), active);
    }

    public(friend) fun update_switch_collateral_status_with(key: String, active: bool) acquires Status, PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        let asset_status = simple_map::borrow_mut(&mut pool_status_ref.assets, &key);
        asset_status.can_switch_collateral = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_borrow_asset_with_rebalance_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_borrow_asset_with_rebalance_status_with(key<C>(), active);
    }

    public(friend) fun update_borrow_asset_with_rebalance_status_with(key: String, active: bool) acquires Status, PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        let asset_status = simple_map::borrow_mut(&mut pool_status_ref.assets, &key);
        asset_status.can_borrow_asset_with_rebalance = active;
        emit_current_pool_status(key);
    }

    public(friend) fun update_repay_shadow_evenly_status(active: bool) acquires Status {
        let owner_address = permission::owner_address();
        // assert_pool_status_initialized(owner_address, key); // TODO: check Status only
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        pool_status_ref.can_repay_shadow_evenly = active;
        // emit_current_pool_status(key); //TODO: event?
    }

    public(friend) fun update_liquidate_status<C>(active: bool) acquires Status, PoolStatusEventHandle {
        update_liquidate_status_with(key<C>(), active);
    }

    public(friend) fun update_liquidate_status_with(key: String, active: bool) acquires Status, PoolStatusEventHandle{
        let owner_address = permission::owner_address();
        assert_is_initialized_asset(owner_address, key);
        let pool_status_ref = borrow_global_mut<Status>(owner_address);
        let asset_status = simple_map::borrow_mut(&mut pool_status_ref.assets, &key);
        asset_status.can_liquidate = active;
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
        assert!(can_repay_shadow_evenly(), 0);
        assert!(can_liquidate<DummyStruct>(), 0);
        update_deposit_status<DummyStruct>(false);
        update_withdraw_status<DummyStruct>(false);
        update_borrow_status<DummyStruct>(false);
        update_repay_status<DummyStruct>(false);
        update_switch_collateral_status<DummyStruct>(false);
        update_borrow_asset_with_rebalance_status<DummyStruct>(false);
        update_repay_shadow_evenly_status(false);
        update_liquidate_status<DummyStruct>(false);
        assert!(!can_deposit<DummyStruct>(), 0);
        assert!(!can_withdraw<DummyStruct>(), 0);
        assert!(!can_borrow<DummyStruct>(), 0);
        assert!(!can_repay<DummyStruct>(), 0);
        assert!(!can_switch_collateral<DummyStruct>(), 0);
        assert!(!can_borrow_asset_with_rebalance<DummyStruct>(), 0);
        assert!(!can_repay_shadow_evenly(), 0);
        assert!(!can_liquidate<DummyStruct>(), 0);
    }
}
