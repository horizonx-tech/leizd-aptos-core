module leizd::account_position {

    use std::error;
    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map::{Self,SimpleMap};
    use aptos_framework::account;
    use leizd_aptos_logic::rebalance::{Self,Rebalance};
    use leizd_aptos_logic::risk_factor;
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_common::permission;
    use leizd_aptos_common::pool_type;
    use leizd_aptos_common::position_type::{Self,AssetToShadow,ShadowToAsset};
    use leizd_aptos_external::price_oracle;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_lib::constant;
    use leizd_aptos_lib::math128;
    use leizd::asset_pool;
    use leizd::shadow_pool;

    const ENO_POSITION_RESOURCE: u64 = 1;
    const ENO_SAFE_POSITION: u64 = 2;
    const ENOT_EXISTED: u64 = 3;
    const EALREADY_PROTECTED: u64 = 4;
    const EOVER_DEPOSITED_AMOUNT: u64 = 5;
    const EOVER_BORROWED_AMOUNT: u64 = 6;
    const EPOSITION_EXISTED: u64 = 7;
    const EALREADY_DEPOSITED_AS_NORMAL: u64 = 8;
    const EALREADY_DEPOSITED_AS_COLLATERAL_ONLY: u64 = 9;
    const ECANNOT_REBALANCE: u64 = 10;
    const ENO_DEPOSITED: u64 = 11;

    //// resources
    /// access control
    struct OperatorKey has store, drop {}

    /// P: The position type - AssetToShadow or ShadowToAsset.
    struct Position<phantom P> has key {
        coins: vector<String>, // e.g. 0x1::module_name::WBTC
        protected_coins: SimpleMap<String,bool>, // e.g. 0x1::module_name::WBTC - true, NOTE: use only ShadowToAsset (need to refactor)
        balance: SimpleMap<String,Balance>,
    }

    struct Balance has copy, store, drop {
        normal_deposited_share: u64,
        conly_deposited_share: u64,
        borrowed_share: u64,
    }

    // Events
    struct UpdatePositionEvent has store, drop {
        key: String,
        normal_deposited: u64,
        conly_deposited: u64,
        borrowed: u64,
    }

    struct UpdateUserPositionEvent has store, drop {
        account: address,
        key: String,
        normal_deposited: u64,
        conly_deposited: u64,
        borrowed: u64,
    }

    struct AccountPositionEventHandle<phantom P> has key, store {
        update_position_event: event::EventHandle<UpdatePositionEvent>,
    }

    struct GlobalPositionEventHandle<phantom P> has key, store {
        update_global_position_event: event::EventHandle<UpdateUserPositionEvent>,
    }

    public entry fun initialize(owner: &signer): OperatorKey {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
        move_to(owner, GlobalPositionEventHandle<AssetToShadow> {
            update_global_position_event: account::new_event_handle<UpdateUserPositionEvent>(owner),
        });
        move_to(owner, GlobalPositionEventHandle<ShadowToAsset> {
            update_global_position_event: account::new_event_handle<UpdateUserPositionEvent>(owner),
        });
        OperatorKey {}
    }

    fun initialize_position_if_necessary(account: &signer) {
        if (!exists<Position<AssetToShadow>>(signer::address_of(account))) {
            move_to(account, Position<AssetToShadow> {
                coins: vector::empty<String>(),
                protected_coins: simple_map::create<String,bool>(),
                balance: simple_map::create<String,Balance>(),
            });
            move_to(account, Position<ShadowToAsset> {
                coins: vector::empty<String>(),
                protected_coins: simple_map::create<String,bool>(),
                balance: simple_map::create<String,Balance>(),
            });
            move_to(account, AccountPositionEventHandle<AssetToShadow> {
                update_position_event: account::new_event_handle<UpdatePositionEvent>(account),
            });
            move_to(account, AccountPositionEventHandle<ShadowToAsset> {
                update_position_event: account::new_event_handle<UpdatePositionEvent>(account),
            });
        }
    }

    ////////////////////////////////////////////////////
    /// Deposit
    ////////////////////////////////////////////////////
    public fun deposit<C,P>(
        account: &signer,
        depositor_addr: address,
        share: u64,
        is_collateral_only: bool,
        _key: &OperatorKey
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        deposit_internal<P>(key<C>(), account, depositor_addr, share, is_collateral_only);
    }
    public fun deposit_with<P>(
        key: String,
        account: &signer,
        depositor_addr: address,
        share: u64,
        is_collateral_only: bool,
        _key: &OperatorKey
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        deposit_internal<P>(key, account, depositor_addr, share, is_collateral_only);
    }
    fun deposit_internal<P>(key: String, account: &signer, depositor_addr: address, share: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        initialize_position_if_necessary(account);
        assert!(exists<Position<AssetToShadow>>(depositor_addr), error::invalid_argument(ENO_POSITION_RESOURCE));

        if (pool_type::is_type_asset<P>()) {
            assert_invalid_deposit_asset(key, depositor_addr, is_collateral_only);
            update_on_deposit<AssetToShadow>(key, depositor_addr, share, is_collateral_only);
        } else {
            assert_invalid_deposit_shadow(key, depositor_addr, is_collateral_only);
            update_on_deposit<ShadowToAsset>(key, depositor_addr, share, is_collateral_only);
        };
    }

    fun assert_invalid_deposit_asset(key: String, depositor_addr: address, is_collateral_only: bool) acquires Position {
        if (is_collateral_only) {
            let deposited = deposited_asset_share_with(key, depositor_addr);
            assert!(deposited == 0, error::invalid_argument(EALREADY_DEPOSITED_AS_NORMAL));
        } else {
            let conly_deposited = conly_deposited_asset_share_with(key, depositor_addr);
            assert!(conly_deposited == 0, error::invalid_argument(EALREADY_DEPOSITED_AS_COLLATERAL_ONLY));
        };
    }

    fun assert_invalid_deposit_shadow(key: String, depositor_addr: address, is_collateral_only: bool) acquires Position {
        if (is_collateral_only) {
            let deposited = deposited_shadow_share_with(key, depositor_addr);
            assert!(deposited == 0, error::invalid_argument(EALREADY_DEPOSITED_AS_NORMAL));
        } else {
            let conly_deposited = conly_deposited_shadow_share_with(key, depositor_addr);
            assert!(conly_deposited == 0, error::invalid_argument(EALREADY_DEPOSITED_AS_COLLATERAL_ONLY));
        };
    }

    public fun is_conly<C,P>(depositor_addr: address): bool acquires Position {
        if (pool_type::is_type_asset<P>()) {
            is_conly_asset(key<C>(), depositor_addr)
        } else {
            is_conly_shadow(key<C>(), depositor_addr)
        }
    }

    fun is_conly_asset(key: String, depositor_addr: address): bool acquires Position {
        let deposited = deposited_asset_share_with(key, depositor_addr);
        let conly_deposited = conly_deposited_asset_share_with(key, depositor_addr);
        assert!(deposited > 0 || conly_deposited > 0, error::invalid_argument(ENO_DEPOSITED));
        conly_deposited > 0
    }

    fun is_conly_shadow(key: String, depositor_addr: address): bool acquires Position {
        let deposited = deposited_shadow_share_with(key, depositor_addr);
        let conly_deposited = conly_deposited_shadow_share_with(key, depositor_addr);
        assert!(deposited > 0 || conly_deposited > 0, error::invalid_argument(ENO_DEPOSITED));
        conly_deposited > 0
    }

    ////////////////////////////////////////////////////
    /// Withdraw
    ////////////////////////////////////////////////////
    public fun withdraw<C,P>(
        depositor_addr: address,
        share: u64,
        is_collateral_only: bool,
        _key: &OperatorKey
    ): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        withdraw_internal<P>(key<C>(), depositor_addr, share, is_collateral_only)
    }
    public fun withdraw_with<P>(
        key: String,
        depositor_addr: address,
        share: u64,
        is_collateral_only: bool,
        _key: &OperatorKey
    ): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        withdraw_internal<P>(key, depositor_addr, share, is_collateral_only)
    }
    fun withdraw_internal<P>(key: String, depositor_addr: address, share: u64, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let withdrawn_amount;
        if (pool_type::is_type_asset<P>()) {
            withdrawn_amount = update_on_withdraw<AssetToShadow>(key, depositor_addr, share, is_collateral_only);
            assert!(is_safe_with<AssetToShadow>(key, depositor_addr), error::invalid_state(ENO_SAFE_POSITION));
        } else {
            withdrawn_amount = update_on_withdraw<ShadowToAsset>(key, depositor_addr, share, is_collateral_only);
            assert!(is_safe_with<ShadowToAsset>(key, depositor_addr), error::invalid_state(ENO_SAFE_POSITION));
        };
        withdrawn_amount
    }

    public fun withdraw_all<C,P>(
        depositor_addr: address,
        is_collateral_only: bool,
        _key: &OperatorKey
    ): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        withdraw_all_internal<C,P>(depositor_addr, is_collateral_only)
    }

    fun withdraw_all_internal<C,P>(depositor_addr: address, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let withdrawn_share;
        let key = key<C>();
        if (pool_type::is_type_asset<P>()) {
            let share = if (is_collateral_only) conly_deposited_asset_share<C>(depositor_addr) else deposited_asset_share<C>(depositor_addr);
            withdrawn_share = update_on_withdraw<AssetToShadow>(key, depositor_addr, share, is_collateral_only);
            assert!(is_safe_with<AssetToShadow>(key, depositor_addr), error::invalid_state(ENO_SAFE_POSITION));
        } else {
            let share = if (is_collateral_only) conly_deposited_shadow_share<C>(depositor_addr) else deposited_shadow_share<C>(depositor_addr);
            withdrawn_share = update_on_withdraw<ShadowToAsset>(key, depositor_addr, share, is_collateral_only);
            assert!(is_safe_with<ShadowToAsset>(key, depositor_addr), error::invalid_state(ENO_SAFE_POSITION));
        };
        withdrawn_share
    }

    public fun withdraw_unsafe<C,P>(
        depositor_addr: address,
        share: u64,
        is_collateral_only: bool,
        _key: &OperatorKey
    ): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        withdraw_unsafe_internal<C,P>(depositor_addr, share, is_collateral_only)
    }

    fun withdraw_unsafe_internal<C,P>(depositor_addr: address, share: u64, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let withdrawn_amount;
        if (pool_type::is_type_asset<P>()) {
            withdrawn_amount = update_on_withdraw<C,AssetToShadow>(depositor_addr, share, is_collateral_only);
        } else {
            withdrawn_amount = update_on_withdraw<C,ShadowToAsset>(depositor_addr, share, is_collateral_only);
        };
        withdrawn_amount
    }

    ////////////////////////////////////////////////////
    /// Borrow
    ////////////////////////////////////////////////////
    public fun borrow<C,P>(
        account: &signer,
        borrower_addr: address,
        share: u64,
        _key: &OperatorKey
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        borrow_internal<P>(key<C>(), account, borrower_addr, share);
    }
    public fun borrow_with<P>(
        key: String,
        account: &signer,
        borrower_addr: address,
        share: u64,
        _key: &OperatorKey
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        borrow_internal<P>(key, account, borrower_addr, share);
    }
    fun borrow_internal<P>(
        key: String,
        account: &signer,
        borrower_addr: address,
        share: u64,
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        initialize_position_if_necessary(account);
        assert!(exists<Position<AssetToShadow>>(borrower_addr), error::invalid_argument(ENO_POSITION_RESOURCE));

        if (pool_type::is_type_asset<P>()) {
            update_on_borrow<ShadowToAsset>(key, borrower_addr, share);
            assert!(is_safe_with<ShadowToAsset>(key, borrower_addr), error::invalid_state(ENO_SAFE_POSITION));
        } else {
            update_on_borrow<AssetToShadow>(key, borrower_addr, share);
            assert!(is_safe_with<AssetToShadow>(key, borrower_addr), error::invalid_state(ENO_SAFE_POSITION));
        };
    }

    public fun borrow_unsafe<C,P>(
        borrower_addr: address,
        share: u64,
        _key: &OperatorKey
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        borrow_unsafe_internal<C,P>(borrower_addr, share)
    }

    public fun borrow_unsafe_internal<C,P>(
        borrower_addr: address,
        share: u64,
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        assert!(exists<Position<AssetToShadow>>(borrower_addr), error::invalid_argument(ENO_POSITION_RESOURCE));

        if (pool_type::is_type_asset<P>()) {
            update_on_borrow<C,ShadowToAsset>(borrower_addr, share);
        } else {
            update_on_borrow<C,AssetToShadow>(borrower_addr, share);
        };
    }

    public fun borrow_asset_with_rebalance<C>(
        addr: address, 
        amount: u64,
        _key: &OperatorKey
    ):(
        vector<Rebalance>,
        vector<Rebalance>,
        vector<Rebalance>,
        vector<Rebalance>
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        borrow_asset_with_rebalance_internal<C>(addr, amount)
    }

    fun borrow_asset_with_rebalance_internal<C>(
        addr: address, 
        amount: u64,
    ):(
        vector<Rebalance>,
        vector<Rebalance>,
        vector<Rebalance>,
        vector<Rebalance>
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let result_amount_deposited = vector::empty<Rebalance>();
        let result_amount_withdrawed = vector::empty<Rebalance>();
        let result_amount_borrowed = vector::empty<Rebalance>();
        let result_amount_repaid = vector::empty<Rebalance>();
        
        let key = key<C>();
        update_on_borrow<ShadowToAsset>(key, addr, amount);
        if (is_safe<C,ShadowToAsset>(addr)) {
            return (result_amount_deposited, result_amount_withdrawed, result_amount_borrowed, result_amount_repaid)
        };

        // try to rebalance between pools
        let required_shadow = required_shadow(key, borrowed_asset_share<C>(addr), deposited_shadow_share<C>(addr));
        (result_amount_deposited, result_amount_withdrawed) = optimize_shadow__deposit_and_withdraw(addr, result_amount_deposited);
        if (vector::length<Rebalance>(&result_amount_deposited) != 0 
            || vector::length<Rebalance>(&result_amount_withdrawed) != 0) {
            return (result_amount_deposited, result_amount_withdrawed, result_amount_borrowed, result_amount_repaid)
        };

        // try to borrow and rebalance shadow
        (result_amount_borrowed, result_amount_deposited) = borrow_and_deposit_if_has_capacity<C>(addr, required_shadow);
        if (vector::length<Rebalance>(&result_amount_borrowed) != 0
            || vector::length<Rebalance>(&result_amount_deposited) != 0) {
            (result_amount_borrowed, result_amount_repaid) = optimize_shadow__borrow_and_repay(addr, result_amount_borrowed);
            (result_amount_deposited, result_amount_withdrawed) = optimize_shadow__deposit_and_withdraw(addr, result_amount_deposited);
            return (result_amount_deposited, result_amount_withdrawed, result_amount_borrowed, result_amount_repaid)
        };
        abort 0
    }

    fun required_shadow(borrowed_key: String, borrowed_asset_share: u64, deposited_shadow_share: u64): u64 {
        let borrowed_volume = price_oracle::volume(&borrowed_key, borrowed_asset_share);
        let deposited_volume = price_oracle::volume(&key<USDZ>(), deposited_shadow_share);
        let required_shadow_for_current_borrow = borrowed_volume * risk_factor::precision() / risk_factor::ltv_of_shadow();
        if (required_shadow_for_current_borrow < deposited_volume) return 0;
        (required_shadow_for_current_borrow - deposited_volume)
    }

    /// @returns (result_amount_deposited, result_amount_withdrawed)
    fun optimize_shadow__deposit_and_withdraw(addr: address, result_amount_deposited: vector<Rebalance>): (vector<Rebalance>, vector<Rebalance>) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        let coins = position_ref.coins;
        let protected_coins = position_ref.protected_coins;
        let result_amount_withdrawed = vector::empty<Rebalance>();

        let (sum_extra_shadow, sum_insufficient_shadow, sum_deposited, sum_borrowed) = sum_extra_and_insufficient_shadow(&coins, &protected_coins, addr);
        if (sum_extra_shadow >= sum_insufficient_shadow) {
            // reallocation
            let i = vector::length<String>(&coins);
            let opt_hf = risk_factor::health_factor_of(key<USDZ>(), sum_deposited, sum_borrowed);
            while (i > 0) {
                let key = *vector::borrow<String>(&coins, i-1);
                if (is_protected_internal(&protected_coins, key)) {
                    i = i - 1;
                    continue
                };
                let (_, _,deposited,borrowed) = extra_and_insufficient_shadow(key, addr);
                let hf = risk_factor::health_factor_of(key<USDZ>(), deposited, borrowed);
                if (hf > opt_hf) {
                    // withdraw
                    let opt_deposit = (borrowed * risk_factor::precision() / (risk_factor::precision() - opt_hf)) * risk_factor::precision() / risk_factor::lt_of_shadow();
                    let diff = deposited - opt_deposit;
                    update_position_for_withdraw<ShadowToAsset>(key, addr, diff, is_conly_shadow(key, addr));
                    vector::push_back<Rebalance>(&mut result_amount_withdrawed, rebalance::create(key, diff));
                } else if (opt_hf > hf) {
                    // deposit
                    let opt_deposit = (borrowed * risk_factor::precision() / (risk_factor::precision() - opt_hf)) * risk_factor::precision() / risk_factor::lt_of_shadow();
                    let diff = opt_deposit - deposited;
                    update_position_for_deposit<ShadowToAsset>(key, addr, diff, false);
                    vector::push_back<Rebalance>(&mut result_amount_deposited, rebalance::create(key, diff));
                };
                i = i -1;
            }
        };
        (result_amount_deposited, result_amount_withdrawed)
    }

    /// @returns (result_amount_deposited, result_amount_withdrawed)
    fun optimize_shadow__borrow_and_repay(addr: address, result_amount_borrowed: vector<Rebalance>): (vector<Rebalance>, vector<Rebalance>) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        let coins = position_ref.coins;
        let protected_coins = position_ref.protected_coins;
        let result_amount_repaid = vector::empty<Rebalance>();

        let (sum_capacity_shadow,sum_overdebt_shadow,keys,deposits,borrows) = sum_capacity_and_overdebt_shadow(&coins, &protected_coins, addr);
        if (sum_capacity_shadow >= sum_overdebt_shadow) {
            // reallocation
            let i = vector::length<String>(&coins);
            let opt_hf = risk_factor::health_factor_weighted_average(keys, deposits, borrows);
            while (i > 0) {
                let key = *vector::borrow<String>(&coins, i-1);
                if (is_protected_internal(&protected_coins, key)) {
                    i = i - 1;
                    continue
                };
                let (_, _,deposited,borrowed) = capacity_and_overdebt_shadow(key, addr);
                let hf = risk_factor::health_factor_of(key, deposited, borrowed);
                if (hf > opt_hf) {
                    // borrow
                    let opt_borrow = (deposited * (risk_factor::lt_of(key) * ((risk_factor::precision() - opt_hf)) / risk_factor::precision())) / risk_factor::precision();
                    let diff = opt_borrow - borrowed;
                    update_position_for_borrow<AssetToShadow>(key, addr, diff);
                    vector::push_back<Rebalance>(&mut result_amount_borrowed, rebalance::create(key, diff));
                } else if (opt_hf > hf) {
                    // repay
                    let opt_borrow = (deposited * (risk_factor::lt_of(key) * ((risk_factor::precision() - opt_hf)) / risk_factor::precision())) / risk_factor::precision();
                    let diff = borrowed - opt_borrow;
                    update_position_for_repay<AssetToShadow>(key, addr, diff);
                    vector::push_back<Rebalance>(&mut result_amount_repaid, rebalance::create(key, diff));
                };
                i = i -1;
            }
        };
        (result_amount_borrowed, result_amount_repaid)
    }

    fun sum_extra_and_insufficient_shadow(coins: &vector<String>, protected_coins: &SimpleMap<String,bool>, addr: address): (u64,u64,u64,u64) acquires Position {
        let i = vector::length<String>(coins);
        let sum_extra_shadow = 0;
        let sum_insufficient_shadow = 0;
        let sum_deposited = 0;
        let sum_borrowed = 0;

        while (i > 0) {
            let key = vector::borrow<String>(coins, i-1);
            if (!is_protected_internal(protected_coins, *key)) {
                let (extra, insufficient, deposited, borrowed) = extra_and_insufficient_shadow(*key, addr);
                sum_extra_shadow = sum_extra_shadow + extra;
                sum_insufficient_shadow = sum_insufficient_shadow + insufficient;
                sum_deposited = sum_deposited + deposited;
                sum_borrowed = sum_borrowed + borrowed;
            };
            i = i - 1;
        };
        (sum_extra_shadow, sum_insufficient_shadow, sum_deposited, sum_borrowed)
    }

    fun sum_capacity_and_overdebt_shadow(coins: &vector<String>, protected_coins: &SimpleMap<String,bool>, addr: address): (u64,u64,vector<String>,vector<u64>,vector<u64>) acquires Position {
        let i = vector::length<String>(coins);
        let sum_capacity_shadow = 0;
        let sum_overdebt_shadow = 0;
        let keys = vector::empty<String>();
        let deposits = vector::empty<u64>();
        let borrows = vector::empty<u64>();
        
        while (i > 0) {
            let key = vector::borrow<String>(coins, i-1);
            if (!is_protected_internal(protected_coins, *key)) {
                let (capacity, overdebt, deposited, borrowed) = capacity_and_overdebt_shadow(*key, addr);
                sum_capacity_shadow = sum_capacity_shadow + capacity;
                sum_overdebt_shadow = sum_overdebt_shadow + overdebt;
                vector::push_back(&mut keys, *key);
                vector::push_back(&mut deposits, deposited);
                vector::push_back(&mut borrows, borrowed);
            };
            i = i - 1;
        };
        (sum_capacity_shadow, sum_overdebt_shadow, keys, deposits, borrows)
    }

    /// @returns (result_amount_borrowed, result_amount_deposited)
    fun borrow_and_deposit_if_has_capacity<C>(addr: address, required_shadow: u64): (vector<Rebalance>, vector<Rebalance>) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        let coins = position_ref.coins;
        let protected_coins = position_ref.protected_coins;
        
        let result_amount_borrowed = vector::empty<Rebalance>();
        let result_amount_deposited = vector::empty<Rebalance>();

        let (sum_capacity_shadow,_,_,_,_) = sum_capacity_and_overdebt_shadow(&coins, &protected_coins, addr);
        if (required_shadow <= sum_capacity_shadow) {
            // borrow and deposit
            let i = vector::length<String>(&coins);
            while (i > 0 && required_shadow > 0) {
                let key = *vector::borrow<String>(&coins, i-1);
                if (!is_protected_internal(&protected_coins, key)) {
                    let (capacity, _, _, _) = capacity_and_overdebt_shadow(key, addr); // TODO: share
                    if (capacity > 0) {
                        let borrow_amount;
                        if (required_shadow > capacity) {
                            borrow_amount = capacity;
                        } else {
                            borrow_amount = required_shadow;
                        };
                        update_position_for_borrow<AssetToShadow>(key, addr, borrow_amount);
                        vector::push_back<Rebalance>(&mut result_amount_borrowed, rebalance::create(key, borrow_amount));
                        update_position_for_deposit<ShadowToAsset>(key<C>(), addr, borrow_amount, false);
                        vector::push_back<Rebalance>(&mut result_amount_deposited, rebalance::create(key, borrow_amount));
                        required_shadow = required_shadow - borrow_amount;
                    };
                };
                
                i = i - 1;
            };
        };
        (result_amount_borrowed, result_amount_deposited)
    }

    ////////////////////////////////////////////////////
    /// Repay
    ////////////////////////////////////////////////////
    public fun repay<C,P>(addr: address, share: u64,  _key: &OperatorKey): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        repay_internal<P>(key<C>(), addr, share)
    }
    public fun repay_with<P>(key: String, addr: address, share: u64,  _key: &OperatorKey): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        repay_internal<P>(key, addr, share)
    }
    fun repay_internal<P>(key: String, addr: address, share: u64): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let repaid_amount;
        if (pool_type::is_type_asset<P>()) {
            repaid_amount = update_on_repay<ShadowToAsset>(key, addr, share);
        } else {
            repaid_amount = update_on_repay<AssetToShadow>(key, addr, share);
        };
        repaid_amount
    }

    public fun repay_all<C,P>(addr: address, _key: &OperatorKey): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        repay_all_internal<C,P>(addr)
    }
    fun repay_all_internal<C,P>(addr: address): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let repaid_share;
        if (pool_type::is_type_asset<P>()) {
            let share = borrowed_asset_share<C>(addr);
            repaid_share = update_on_repay<ShadowToAsset>(key<C>(), addr, share);
        } else {
            let share = borrowed_shadow_share<C>(addr);
            repaid_share = update_on_repay<AssetToShadow>(key<C>(), addr, share);
        };
        repaid_share
    }

    ////////////////////////////////////////////////////
    /// Rebalance
    ////////////////////////////////////////////////////
    ////// for repay_shadow_with_rebalance
    public fun repay_shadow_with(
        key: String,
        addr: address,
        share: u64,
        _key: &OperatorKey
    ): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        update_position_for_repay<AssetToShadow>(key, addr, share)
    }

    ////////////////////////////////////////////////////
    /// Liquidate
    ////////////////////////////////////////////////////
    public fun liquidate<C,P>(target_addr: address, _key: &OperatorKey): (u64,u64,bool) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        liquidate_internal<C,P>(target_addr)
    }

    fun liquidate_internal<C,P>(target_addr: address): (u64,u64,bool) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        // TODO: rebalance between pools
        let key = key<C>();
        if (pool_type::is_type_asset<P>()) {
            assert!(!is_safe<C,AssetToShadow>(target_addr), error::invalid_state(ENO_SAFE_POSITION));

            let normal_deposited = deposited_asset_share<C>(target_addr);
            let conly_deposited = conly_deposited_asset_share<C>(target_addr);
            assert!(normal_deposited > 0 || conly_deposited > 0, error::invalid_argument(ENO_DEPOSITED));
            let is_collateral_only = conly_deposited > 0;
            let deposited = if (is_collateral_only) conly_deposited else normal_deposited;

            update_on_withdraw<AssetToShadow>(key, target_addr, deposited, is_collateral_only);
            let borrowed = borrowed_shadow_share<C>(target_addr);
            update_on_repay<AssetToShadow>(key, target_addr, borrowed);
            assert!(is_zero_position<C,AssetToShadow>(target_addr), error::invalid_state(EPOSITION_EXISTED));
            (deposited, borrowed, is_collateral_only)
        } else {
            assert!(!is_safe<C,ShadowToAsset>(target_addr), error::invalid_state(ENO_SAFE_POSITION));
            
            // rebalance shadow if possible
            // let from_key = key_rebalanced_from<C>(target_addr);
            // if (option::is_some(&from_key)) {
            //     // rebalance
            //     rebalance_shadow_internal(target_addr, *option::borrow<String>(&from_key), key<C>());
            //     return (0, 0, false)
            // };

            let normal_deposited = deposited_shadow_share<C>(target_addr);
            let conly_deposited = conly_deposited_shadow_share<C>(target_addr);
            assert!(normal_deposited > 0 || conly_deposited > 0, error::invalid_argument(ENO_DEPOSITED));
            let is_collateral_only = conly_deposited > 0;
            let deposited = if (is_collateral_only) conly_deposited else normal_deposited;

            update_on_withdraw<ShadowToAsset>(key, target_addr, deposited, is_collateral_only);
            let borrowed = borrowed_asset_share<C>(target_addr);
            update_on_repay<ShadowToAsset>(key, target_addr, borrowed);
            assert!(is_zero_position<C,ShadowToAsset>(target_addr), error::invalid_state(EPOSITION_EXISTED));
            (deposited, borrowed, is_collateral_only)
        }
    }

    public fun extra_and_insufficient_shadow(key: String, addr: address): (u64,u64,u64,u64) acquires Position {
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key);
        let deposited = deposited_volume<ShadowToAsset>(addr, key);
        let required_deposit = borrowed * risk_factor::precision() / risk_factor::ltv_of_shadow();
        if (deposited < required_deposit) {
            (0, (required_deposit - deposited), deposited, borrowed)
        } else {
            ((deposited - required_deposit), 0, deposited, borrowed)
        }
    }

    fun capacity_and_overdebt_shadow(key: String, addr: address): (u64,u64,u64,u64) acquires Position {
        let borrowed = borrowed_volume<AssetToShadow>(addr, key);
        let deposited = deposited_volume<AssetToShadow>(addr, key);
        let borrowable = deposited * risk_factor::ltv_of(key) / risk_factor::precision();
        if (borrowable < borrowed) {
            (0, (borrowable - borrowed), deposited, borrowed)
        } else {
            ((borrowable - borrowed), 0, deposited, borrowed)
        }
    }

    ////////////////////////////////////////////////////
    /// Rebalance Protection
    ////////////////////////////////////////////////////
    public fun enable_to_rebalance<C>(account: &signer) acquires Position {
        enable_to_rebalance_internal<C>(account);
    }
    fun enable_to_rebalance_internal<C>(account: &signer) acquires Position {
        let key = key<C>();
        let position_a2s_ref = borrow_global_mut<Position<AssetToShadow>>(signer::address_of(account));
        if (is_protected_internal(&position_a2s_ref.protected_coins, key)) {
            simple_map::remove<String,bool>(&mut position_a2s_ref.protected_coins, &key);
        };
        let position_s2a_ref = borrow_global_mut<Position<ShadowToAsset>>(signer::address_of(account));
        if (is_protected_internal(&position_s2a_ref.protected_coins, key)) {
            simple_map::remove<String,bool>(&mut position_s2a_ref.protected_coins, &key);
        };
    }

    public fun disable_to_rebalance<C>(account: &signer) acquires Position {
        disable_to_rebalance_internal<C>(account);
    }
    fun disable_to_rebalance_internal<C>(account: &signer) acquires Position {
        let key = key<C>();
        let position_a2s_ref = borrow_global_mut<Position<AssetToShadow>>(signer::address_of(account));
        if (!is_protected_internal(&position_a2s_ref.protected_coins, key)) {
            simple_map::add<String,bool>(&mut position_a2s_ref.protected_coins, key, true);
        };
        let position_s2a_ref = borrow_global_mut<Position<ShadowToAsset>>(signer::address_of(account));
        if (!is_protected_internal(&position_s2a_ref.protected_coins, key)) {
            simple_map::add<String,bool>(&mut position_s2a_ref.protected_coins, key, true);
        };
    }

    public fun is_protected<C>(account_addr: address): bool acquires Position {
        let position_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        is_protected_internal(&position_ref.protected_coins, key<C>())
    }
    public fun is_protected_with(key: String, account_addr: address): bool acquires Position {
        let position_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        is_protected_internal(&position_ref.protected_coins, key)
    }
    fun is_protected_internal(protected_coins: &SimpleMap<String,bool>, key: String): bool {
        simple_map::contains_key<String,bool>(protected_coins, &key)
    }

    ////////////////////////////////////////////////////
    /// Switch Collateral
    ////////////////////////////////////////////////////
    public fun switch_collateral<C,P>(addr: address, to_collateral_only: bool,  _key: &OperatorKey): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        switch_collateral_internal<C,P>(addr, to_collateral_only)
    }
    fun switch_collateral_internal<C,P>(addr: address, to_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let deposited;
        let key = key<C>();
        if (pool_type::is_type_asset<P>()) {
            if (to_collateral_only) {
                deposited = deposited_asset_share<C>(addr);
                update_on_withdraw<AssetToShadow>(key, addr, deposited, false);
                update_on_deposit<AssetToShadow>(key, addr, deposited, true);
            } else {
                deposited = conly_deposited_asset_share<C>(addr);
                update_on_withdraw<AssetToShadow>(key, addr, deposited, true);
                update_on_deposit<AssetToShadow>(key, addr, deposited, false);
            }
        } else {
            if (to_collateral_only) {
                deposited = deposited_shadow_share<C>(addr);
                update_on_withdraw<ShadowToAsset>(key, addr, deposited, false);
                update_on_deposit<ShadowToAsset>(key, addr, deposited, true);
            } else {
                deposited = conly_deposited_shadow_share<C>(addr);
                update_on_withdraw<ShadowToAsset>(key, addr, deposited, true);
                update_on_deposit<ShadowToAsset>(key, addr, deposited, false);
            }
        };
        deposited
    }

    //// internal functions to update position
    fun update_on_deposit<P>(
        key: String,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        update_position_for_deposit<P>(key, depositor_addr, amount, is_collateral_only);
    }

    fun update_on_withdraw<P>(
        key: String,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool
    ): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        update_position_for_withdraw<P>(key, depositor_addr, amount, is_collateral_only)
    }

    fun update_on_borrow<P>(
        key: String,
        depositor_addr: address,
        amount: u64
    ) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        update_position_for_borrow<P>(key, depositor_addr, amount);
    }

    fun update_on_repay<P>(
        key: String,
        depositor_addr: address,
        amount: u64
    ): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        update_position_for_repay<P>(key, depositor_addr, amount)
    }

    fun update_position_for_deposit<P>(key: String, addr: address, share: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
            if (is_collateral_only) {
                balance_ref.conly_deposited_share = balance_ref.conly_deposited_share + share;
            } else {
                balance_ref.normal_deposited_share = balance_ref.normal_deposited_share + share;
            };
            emit_update_position_event<P>(addr, key, balance_ref);
        } else {
            new_position<P>(addr, share, 0, is_collateral_only, key);
        };
    }

    fun update_position_for_withdraw<P>(key: String, addr: address, share: u64, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
        if (is_collateral_only) {
            share = if (share == constant::u64_max()) balance_ref.conly_deposited_share else share;
            assert!(balance_ref.conly_deposited_share >= share, error::invalid_argument(EOVER_DEPOSITED_AMOUNT));
            balance_ref.conly_deposited_share = balance_ref.conly_deposited_share - share;
        } else {
            share = if (share == constant::u64_max()) balance_ref.normal_deposited_share else share;
            assert!(balance_ref.normal_deposited_share >= share, error::invalid_argument(EOVER_DEPOSITED_AMOUNT));
            balance_ref.normal_deposited_share = balance_ref.normal_deposited_share - share;
        };
        emit_update_position_event<P>(addr, key, balance_ref);
        remove_balance_if_unused<P>(addr, key);
        share
    }

    fun update_position_for_borrow<P>(key: String, addr: address, share: u64) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
            balance_ref.borrowed_share = balance_ref.borrowed_share + share;
            emit_update_position_event<P>(addr, key, balance_ref);
        } else {
            new_position<P>(addr, 0, share, false, key);
        };
    }

    fun update_position_for_repay<P>(key: String, addr: address, share: u64): u64 acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
        share = if (share == constant::u64_max()) balance_ref.borrowed_share else share;
        assert!(balance_ref.borrowed_share >= share, error::invalid_argument(EOVER_BORROWED_AMOUNT));
        balance_ref.borrowed_share = balance_ref.borrowed_share - share;
        emit_update_position_event<P>(addr, key, balance_ref);
        remove_balance_if_unused<P>(addr, key);
        share
    }

    fun emit_update_position_event<P>(addr: address, key: String, balance_ref: &Balance) acquires AccountPositionEventHandle, GlobalPositionEventHandle {
        event::emit_event<UpdatePositionEvent>(
            &mut borrow_global_mut<AccountPositionEventHandle<P>>(addr).update_position_event,
            UpdatePositionEvent {
                key,
                normal_deposited: balance_ref.normal_deposited_share,
                conly_deposited: balance_ref.conly_deposited_share,
                borrowed: balance_ref.borrowed_share,
            },
        );
        let owner_address = permission::owner_address();
        event::emit_event<UpdateUserPositionEvent>(
            &mut borrow_global_mut<GlobalPositionEventHandle<P>>(owner_address).update_global_position_event,
            UpdateUserPositionEvent {
                account: addr,
                key,
                normal_deposited: balance_ref.normal_deposited_share,
                conly_deposited: balance_ref.conly_deposited_share,
                borrowed: balance_ref.borrowed_share,
            },
        );
    }

    fun new_position<P>(addr: address, deposit: u64, borrow: u64, is_collateral_only: bool, key: String) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        vector::push_back<String>(&mut position_ref.coins, key);

        if (is_collateral_only) {
            simple_map::add<String,Balance>(&mut position_ref.balance, key, Balance {
                normal_deposited_share: 0,
                conly_deposited_share: deposit,
                borrowed_share: borrow,
            });
        } else {
            simple_map::add<String,Balance>(&mut position_ref.balance, key, Balance {
                normal_deposited_share: deposit,
                conly_deposited_share: 0,
                borrowed_share: borrow,
            });
        };

        emit_update_position_event<P>(addr, key, simple_map::borrow<String,Balance>(&position_ref.balance, &key));
    }

    fun remove_balance_if_unused<P>(addr: address, key: String) acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        let balance_ref = simple_map::borrow<String,Balance>(&position_ref.balance, &key);
        if (
            balance_ref.normal_deposited_share == 0
            && balance_ref.conly_deposited_share == 0
            && balance_ref.borrowed_share == 0 // NOTE: maybe actually only `deposited` needs to be checked.
        ) {
            simple_map::remove<String, Balance>(&mut position_ref.balance, &key);
            let (_, i) = vector::index_of<String>(&position_ref.coins, &key);
            vector::remove<String>(&mut position_ref.coins, i);
        }
    }

    ////////////////////////////////////////////////////
    /// View Functions
    ////////////////////////////////////////////////////
    fun is_safe<C,P>(addr: address): bool acquires Position {
        is_safe_with<P>(key<C>(), addr)
    }
    fun is_safe_with<P>(key: String, addr: address): bool acquires Position {
        let position_ref = borrow_global<Position<P>>(addr);
        if (position_type::is_asset_to_shadow<P>()) {
            utilization_of<P>(position_ref, key) < risk_factor::lt_of(key)
        } else {
            utilization_of<P>(position_ref, key) < risk_factor::lt_of_shadow()
        }
    }

    fun is_zero_position<C,P>(addr: address): bool acquires Position {
        let key = key<C>();
        let position_ref = borrow_global<Position<P>>(addr);
        !vector::contains<String>(&position_ref.coins, &key)
    }

    fun utilization_of<P>(position_ref: &Position<P>, key: String): u64 {
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let deposited = deposited_volume_internal(position_ref, key);
            let borrowed = borrowed_volume_internal(position_ref, key);
            if (deposited == 0 && borrowed != 0) {
                return constant::u64_max()
            } else if (deposited == 0) { 
                return 0 
            };
            borrowed * risk_factor::precision() / deposited // TODO: check calculation order (division is last?)
        } else {
            0
        }
    }

    //// get volume, amount from share
    public fun deposited_volume<P>(addr: address, key: String): u64 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        deposited_volume_internal<P>(position_ref, key)
    }
    fun deposited_volume_internal<P>(position_ref: &Position<P>, key: String): u64 {
        let normal_deposited = normal_deposited_amount_internal(position_ref, key);
        let conly_deposited = conly_deposited_amount_internal(position_ref, key);
        if (normal_deposited > 0 || conly_deposited > 0) {
            price_oracle::volume(&key, ((normal_deposited + conly_deposited) as u64)) // TODO: consider cast
        } else {
            0
        }
    }
    fun normal_deposited_amount<P>(addr: address, key: String): u128 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        normal_deposited_amount_internal<P>(position_ref, key)
    }
    fun normal_deposited_amount_internal<P>(position_ref: &Position<P>, key: String): u128 {
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let normal_deposited_share = simple_map::borrow<String,Balance>(&position_ref.balance, &key).normal_deposited_share;
            let (total_amount, total_share) = total_normal_deposited<P>(key);
            if (total_amount == 0 && total_share == 0) {
                (normal_deposited_share as u128)
            } else {
                math128::to_amount((normal_deposited_share as u128), total_amount, total_share)
            }
        } else {
            0
        }
    }
    fun conly_deposited_amount<P>(addr: address, key: String): u128 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        conly_deposited_amount_internal<P>(position_ref, key)
    }
    fun conly_deposited_amount_internal<P>(position_ref: &Position<P>, key: String): u128 {
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let conly_deposited_share = simple_map::borrow<String,Balance>(&position_ref.balance, &key).conly_deposited_share;
            let (total_amount, total_share) = total_conly_deposited<P>(key);
            if (total_amount == 0 && total_share == 0) {
                (conly_deposited_share as u128)
            } else {
                math128::to_amount((conly_deposited_share as u128), total_amount, total_share)
            }
        } else {
            0
        }
    }

    public fun borrowed_volume<P>(addr: address, key: String): u64 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        borrowed_volume_internal<P>(position_ref, key)
    }
    fun borrowed_volume_internal<P>(position_ref: &Position<P>, key: String): u64 {
        let borrowed = borrowed_amount_internal(position_ref, key);
        if (borrowed > 0) {
            price_oracle::volume(&key, (borrowed as u64)) // TODO: consider cast
        } else {
            0
        }
    }
    fun borrowed_amount<P>(addr: address, key: String): u128 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        borrowed_amount_internal<P>(position_ref, key)
    }
    fun borrowed_amount_internal<P>(position_ref: &Position<P>, key: String): u128 {
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let (total_amount, total_share) = total_borrowed<P>(key);
            let borrowed_share = simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed_share;
            if (total_amount == 0 && total_share == 0) {
                (borrowed_share as u128)
            } else {
                math128::to_amount((borrowed_share as u128), total_amount, total_share)
            }
        } else {
            0
        }
    }

    //// getter about Resources in this module
    public fun deposited_asset_share<C>(addr: address): u64 acquires Position {
        deposited_asset_share_with(key<C>(), addr)
    }
    public fun deposited_asset_share_with(key: String, addr: address): u64 acquires Position {
        if (!exists<Position<AssetToShadow>>(addr)) return 0;
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).normal_deposited_share
        } else {
            0
        }
    }

    public fun conly_deposited_asset_share<C>(addr: address): u64 acquires Position {
        conly_deposited_asset_share_with(key<C>(), addr)
    }
    public fun conly_deposited_asset_share_with(key: String, addr: address): u64 acquires Position {
        if (!exists<Position<AssetToShadow>>(addr)) return 0;
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).conly_deposited_share
        } else {
            0
        }
    }

    public fun borrowed_asset_share<C>(addr: address): u64 acquires Position {
        let key = key<C>();
        if (!exists<Position<ShadowToAsset>>(addr)) return 0;
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed_share
        } else {
            0
        }
    }

    public fun deposited_shadow_share<C>(addr: address): u64 acquires Position {
        deposited_shadow_share_with(key<C>(), addr)
    }
    public fun deposited_shadow_share_with(key: String, addr: address): u64 acquires Position {
        if (!exists<Position<ShadowToAsset>>(addr)) return 0;
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).normal_deposited_share
        } else {
            0
        }
    }

    public fun conly_deposited_shadow_share<C>(addr: address): u64 acquires Position {
        conly_deposited_shadow_share_with(key<C>(), addr)
    }
    public fun conly_deposited_shadow_share_with(key: String, addr: address): u64 acquires Position {
        if (!exists<Position<ShadowToAsset>>(addr)) return 0;
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).conly_deposited_share
        } else {
            0
        }
    }

    public fun borrowed_shadow_share<C>(addr: address): u64 acquires Position {
        let key = key<C>();
        borrowed_shadow_share_with(key, addr)
    }
    public fun borrowed_shadow_share_with(key: String, addr: address): u64 acquires Position {
        if (!exists<Position<AssetToShadow>>(addr)) return 0;
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed_share
        } else {
            0
        }
    }

    ////// for repay_shadow_with_rebalance
    public fun borrowed_shadow_share_all(addr: address): (
        vector<String>, // keys
        vector<u64> // shares
    ) acquires Position {
        if (!exists<Position<AssetToShadow>>(addr)) return (vector::empty<String>(), vector::empty<u64>());
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);

        let i = vector::length<String>(&position_ref.coins);
        if (i == 0) return (vector::empty<String>(), vector::empty<u64>());

        let keys = vector::empty<String>();
        let borrowed_shares = vector::empty<u64>();
        while (i > 0) {
            let key = vector::borrow<String>(&position_ref.coins, i-1);
            let borrowed_share = simple_map::borrow<String,Balance>(&position_ref.balance, key).borrowed_share;
            if (borrowed_share > 0) {
                vector::push_back<String>(&mut keys, *key);
                vector::push_back<u64>(&mut borrowed_shares, borrowed_share);
            };
            i = i - 1;
        };
        (keys, borrowed_shares)
    }

    ////// for borrow_asset_with_rebalance
    public fun deposited_coins<P>(addr: address): vector<String> acquires Position {
        let (coins, _, balances) = position<P>(addr);
        let deposited_coins = vector::empty<String>();
        let i = 0;
        while (i < vector::length(&coins)) {
            let coin = vector::borrow(&coins, i);
            if (!simple_map::contains_key(&balances, coin)) continue;
            let balance = simple_map::borrow(&balances, coin);
            if (balance.normal_deposited_share > 0 || balance.conly_deposited_share > 0) {
                vector::push_back(&mut deposited_coins, *coin);
            };
            i = i + 1;
        };
        deposited_coins
    }
    public fun position<P>(addr: address): (vector<String>, SimpleMap<String,bool>, SimpleMap<String,Balance>) acquires Position {
        pool_type::assert_pool_type<P>();
        if (pool_type::is_type_asset<P>()) {
            position_internal<AssetToShadow>(addr)
        } else {
            position_internal<ShadowToAsset>(addr)
        }
    }
    fun position_internal<P>(addr: address): (vector<String>, SimpleMap<String,bool>, SimpleMap<String,Balance>) acquires Position {
        position_type::assert_position_type<P>();
        if (position_type::is_asset_to_shadow<P>()) {
            if (!exists<Position<AssetToShadow>>(addr)) return (vector::empty<String>(), simple_map::create<String, bool>(), simple_map::create<String, Balance>());
            position_value(borrow_global<Position<AssetToShadow>>(addr))
        } else {
            if (!exists<Position<ShadowToAsset>>(addr)) return (vector::empty<String>(), simple_map::create<String, bool>(), simple_map::create<String, Balance>());
            position_value(borrow_global<Position<ShadowToAsset>>(addr))
        }
    }

    public fun position_value<P>(position: &Position<P>): (vector<String>, SimpleMap<String,bool>, SimpleMap<String,Balance>) {
        (position.coins, position.protected_coins, position.balance)
    }

    public fun balance_value(balance: &Balance): (u64, u64, u64) {
        (
            balance.normal_deposited_share,
            balance.conly_deposited_share,
            balance.borrowed_share,
        )
    }

    //// get total from pools
    fun total_normal_deposited<P>(key: String): (u128, u128) {
        if (position_type::is_asset_to_shadow<P>()) {
            total_normal_deposited_for_asset(key)
        } else {
            total_normal_deposited_for_shadow(key)
        }
    }
    fun total_normal_deposited_for_asset(key: String): (u128, u128) {
        let total_amount = asset_pool::total_normal_deposited_amount_with(key);
        let total_shares = asset_pool::total_normal_deposited_share_with(key);
        (total_amount, total_shares)
    }
    fun total_normal_deposited_for_shadow(key: String): (u128, u128) {
        let total_amount = shadow_pool::normal_deposited_amount_with(key);
        let total_shares = shadow_pool::normal_deposited_share_with(key);
        (total_amount, total_shares)
    }
    fun total_conly_deposited<P>(key: String): (u128, u128) {
        if (position_type::is_asset_to_shadow<P>()) {
            total_conly_deposited_for_asset(key)
        } else {
            total_conly_deposited_for_shadow(key)
        }
    }
    fun total_conly_deposited_for_asset(key: String): (u128, u128) {
        let total_amount = asset_pool::total_conly_deposited_amount_with(key);
        let total_shares = asset_pool::total_conly_deposited_share_with(key);
        (total_amount, total_shares)
    }
    fun total_conly_deposited_for_shadow(key: String): (u128, u128) {
        let total_amount = shadow_pool::conly_deposited_amount_with(key);
        let total_shares = shadow_pool::conly_deposited_share_with(key);
        (total_amount, total_shares)
    }
    fun total_borrowed<P>(key: String): (u128, u128) {
        // NOTE: when you want to know borrowing asset's volume by depositing shadow (= position type is ShadowToAsset), check asset_pool's total about borrowed.
        if (position_type::is_shadow_to_asset<P>()) {
            total_borrowed_for_asset(key)
        } else {
            total_borrowed_for_shadow(key)
        }
    }
    fun total_borrowed_for_asset(key: String): (u128, u128) {
        let total_amount = asset_pool::total_borrowed_amount_with(key);
        let total_shares = asset_pool::total_borrowed_share_with(key);
        (total_amount, total_shares)
    }
    fun total_borrowed_for_shadow(key: String): (u128, u128) {
        let total_amount = shadow_pool::borrowed_amount_with(key);
        let total_shares = shadow_pool::borrowed_share_with(key);
        (total_amount, total_shares)
    }

    #[test_only]
    use leizd_aptos_common::pool_type::{Asset,Shadow};
    #[test_only]
    use leizd_aptos_common::test_coin::{WETH,UNI,USDC,USDT};
    #[test_only]
    use leizd::test_initializer;

    // for deposit
    #[test_only]
    fun setup(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        test_initializer::initialize(owner);
        asset_pool::initialize(owner);
        shadow_pool::initialize(owner);
        asset_pool::init_pool_for_test<WETH>(owner);
        asset_pool::init_pool_for_test<UNI>(owner);
        asset_pool::init_pool_for_test<USDC>(owner);
        asset_pool::init_pool_for_test<USDT>(owner);
    }
    #[test_only]
    fun borrow_unsafe_for_test<C,P>(borrower_addr: address, amount: u64) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        borrow_unsafe_internal<C,P>(borrower_addr, amount)
    }
    #[test_only]
    public fun initialize_position_if_necessary_for_test(account: &signer) {
        initialize_position_if_necessary(account);
    }

    #[test(owner=@leizd,account=@0x111)]
    public fun test_protect_coin_and_unprotect_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let key = key<WETH>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initialize_position_if_necessary(account);
        new_position<ShadowToAsset>(account_addr, 10, 0, false, key);
        assert!(!is_protected<WETH>(account_addr), 0);

        disable_to_rebalance_internal<WETH>(account);
        assert!(is_protected<WETH>(account_addr), 0);

        enable_to_rebalance_internal<WETH>(account);
        assert!(!is_protected<WETH>(account_addr), 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_weth(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 800000, false);
        assert!(deposited_asset_share<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 1, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222)]
    public entry fun test_deposit_weth_by_two(owner: &signer, account1: &signer, account2: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 800000, false);
        deposit_internal<Asset>(key<WETH>(), account2, account2_addr, 200000, false);
        assert!(deposited_asset_share<WETH>(account1_addr) == 800000, 0);
        assert!(deposited_asset_share<WETH>(account2_addr) == 200000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_weth_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 800000, true);
        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 800000, false);
        assert!(deposited_shadow_share<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_shadow_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 800000, true);
        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_with_all_patterns(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 1, false);
        deposit_internal<Asset>(key<UNI>(), account, account_addr, 2, true);
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 10, false);
        deposit_internal<Shadow>(key<UNI>(), account, account_addr, 20, true);
        assert!(deposited_asset_share<WETH>(account_addr) == 1, 0);
        assert!(conly_deposited_asset_share<UNI>(account_addr) == 2, 0);
        assert!(deposited_shadow_share<WETH>(account_addr) == 10, 0);
        assert!(conly_deposited_shadow_share<UNI>(account_addr) == 20, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 2, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 2, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65544)]
    fun test_deposit_asset_by_collateral_only_asset_after_depositing_normal(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 1, false);
        deposit_internal<Asset>(key<WETH>(), account, account_addr, 1, true);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65545)]
    fun test_deposit_asset_by_normal_after_depositing_collateral_only(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 1, true);
        deposit_internal<Asset>(key<WETH>(), account, account_addr, 1, false);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65544)]
    fun test_deposit_shadow_by_collateral_only_asset_after_depositing_normal(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 1, false);
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 1, true);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65545)]
    fun test_deposit_shadow_by_normal_after_depositing_collateral_only(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 1, true);
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 1, false);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_weth(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 700000, false);
        withdraw_internal<Asset>(key<WETH>(), account_addr, 600000, false);
        assert!(deposited_asset_share<WETH>(account_addr) == 100000, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 2, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_with_same_as_deposited_amount(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 30, false);
        withdraw_internal<Asset>(key<WETH>(), account_addr, 30, false);
        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 30, false);
        withdraw_internal<Asset>(key<WETH>(), account_addr, 31, false);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 700000, true);
        withdraw_internal<Asset>(key<WETH>(), account_addr, 600000, true);

        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 700000, false);
        withdraw_internal<Shadow>(key<WETH>(), account_addr, 600000, false);

        assert!(deposited_shadow_share<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_shadow_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 700000, true);
        withdraw_internal<Shadow>(key<WETH>(), account_addr, 600000, true);

        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_all(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 100000, true);
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 20000, true);
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 3000, true);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 123000, 0);

        let share = withdraw_all_internal<WETH,Shadow>(account_addr, true);
        assert!(share == 123000, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_with_all_patterns(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 100, false);
        deposit_internal<Asset>(key<UNI>(), account, account_addr, 100, true);
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 100, false);
        deposit_internal<Shadow>(key<UNI>(), account, account_addr, 100, true);
        withdraw_internal<Asset>(key<WETH>(), account_addr, 1, false);
        withdraw_internal<Asset>(key<UNI>(), account_addr, 2, true);
        withdraw_internal<Shadow>(key<WETH>(), account_addr, 10, false);
        withdraw_internal<Shadow>(key<UNI>(), account_addr, 20, true);
        assert!(deposited_asset_share<WETH>(account_addr) == 99, 0);
        assert!(conly_deposited_asset_share<UNI>(account_addr) == 98, 0);
        assert!(deposited_shadow_share<WETH>(account_addr) == 90, 0);
        assert!(conly_deposited_shadow_share<UNI>(account_addr) == 80, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 4, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 4, 0);
    }

    // for borrow
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_borrow_unsafe(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 1, false); // for generating Position
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 10);
        assert!(deposited_shadow_share<WETH>(account_addr) == 1, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 10, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 2, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_borrow_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 95 / 100, 0); // 95%

        // execute
        let deposit_amount = 10000;
        let borrow_amount = 8999;
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, deposit_amount, false);
        borrow_internal<Asset>(key<WETH>(), account, account_addr, borrow_amount);
        let weth_key = key<WETH>();
        assert!(deposited_shadow_share<WETH>(account_addr) == deposit_amount, 0);
        assert!(deposited_volume<ShadowToAsset>(account_addr, weth_key) == deposit_amount, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == borrow_amount, 0);
        assert!(borrowed_volume<ShadowToAsset>(account_addr, weth_key) == borrow_amount, 0);
        //// calculate
        let utilization = utilization_of<ShadowToAsset>(borrow_global<Position<ShadowToAsset>>(account_addr), key<WETH>());
        assert!(lt - utilization == (9500 - borrow_amount) * risk_factor::precision() / deposit_amount, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_borrow_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let weth_key = key<WETH>();
        let lt = risk_factor::lt_of(weth_key);
        assert!(lt == risk_factor::precision() * 85 / 100, 0); // 85%

        // execute
        let deposit_amount = 10000;
        let borrow_amount = 8499; // (10000 * 85%) - 1
        deposit_internal<Asset>(key<WETH>(), account, account_addr, deposit_amount, false);
        borrow_internal<Shadow>(key<WETH>(), account, account_addr, borrow_amount);
        assert!(deposited_asset_share<WETH>(account_addr) == deposit_amount, 0);
        assert!(deposited_volume<AssetToShadow>(account_addr, weth_key) == deposit_amount, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == borrow_amount, 0);
        assert!(borrowed_volume<AssetToShadow>(account_addr, weth_key) == borrow_amount, 0);
        //// calculate
        let utilization = utilization_of<AssetToShadow>(borrow_global<Position<AssetToShadow>>(account_addr), weth_key);
        assert!(lt - utilization == (8500 - borrow_amount) * risk_factor::precision() / deposit_amount, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 196610)]
    public entry fun test_borrow_asset_when_over_borrowable(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 95 / 100, 0); // 95%

        // execute
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 10000, false);
        borrow_internal<Asset>(key<WETH>(), account, account_addr, 10000);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 196610)]
    public entry fun test_borrow_shadow_when_over_borrowable(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let weth_key = key<WETH>();
        let lt = risk_factor::lt_of(weth_key);
        assert!(lt == risk_factor::precision() * 85 / 100, 0); // 85%

        // execute
        deposit_internal<Asset>(key<WETH>(), account, account_addr, 10000, false);
        borrow_internal<Shadow>(key<WETH>(), account, account_addr, 8500);
    }

    // borrow shadow with rebalance
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__optimize_shadow(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 100000, false);
        deposit_internal<Shadow>(key<USDC>(), account1, account1_addr, 100000, false);
        
        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(deposited_shadow_share<USDC>(account1_addr) == 0, 0);
        assert!(deposited_shadow_share<UNI>(account1_addr) == 100000, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__optimize_shadow2(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 100000, false);
        deposit_internal<Shadow>(key<USDC>(), account1, account1_addr, 100000, false);
        borrow_internal<Asset>(key<USDC>(), account1, account1_addr, 50000);
        
        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(deposited_shadow_share<USDC>(account1_addr) == 83332, 0); // TODO: 83333?
        assert!(deposited_shadow_share<UNI>(account1_addr) == 16666, 0); // TODO: 16667?
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__optimize_shadow3(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 100000, false);
        deposit_internal<Shadow>(key<WETH>(), account1, account1_addr, 50000, false);
        deposit_internal<Shadow>(key<USDC>(), account1, account1_addr, 100000, false);
        deposit_internal<Shadow>(key<UNI>(), account1, account1_addr, 10000, false);
        borrow_internal<Shadow>(key<WETH>(), account1, account1_addr, 10000);
        borrow_internal<Asset>(key<USDC>(), account1, account1_addr, 50000);
        
        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(deposited_shadow_share<USDC>(account1_addr) == 133332, 0); // TODO: 133333?
        assert!(deposited_shadow_share<UNI>(account1_addr) == 26666, 0); // TODO: 26667?
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 10000, 0);
        assert!(borrowed_asset_share<USDC>(account1_addr) == 50000, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__optimize_shadow4(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 100000, false);
        deposit_internal<Shadow>(key<WETH>(), account1, account1_addr, 50000, false);
        deposit_internal<Shadow>(key<USDC>(), account1, account1_addr, 100000, false);
        deposit_internal<Shadow>(key<UNI>(), account1, account1_addr, 10000, false);
        borrow_internal<Shadow>(key<WETH>(), account1, account1_addr, 10000);
        borrow_internal<Asset>(key<USDC>(), account1, account1_addr, 50000);
        disable_to_rebalance_internal<WETH>(account1);
        
        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 50000, 0);
        assert!(deposited_shadow_share<USDC>(account1_addr) == 91666, 0); // TODO: 91667?
        assert!(deposited_shadow_share<UNI>(account1_addr) == 18332, 0); // TODO: 18333?
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 10000, 0);
        assert!(borrowed_asset_share<USDC>(account1_addr) == 50000, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
    }

    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__borrow_and_deposit(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 100000, false);

        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 11111, 0);
        assert!(deposited_shadow_share<UNI>(account1_addr) == 11111, 0); // TODO: 11111?
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__borrow_and_deposit2(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 100000, false);
        deposit_internal<Asset>(key<USDC>(), account1, account1_addr, 50000, false);

        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_asset_share<USDC>(account1_addr) == 50000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 7407, 0);
        assert!(borrowed_shadow_share<USDC>(account1_addr) == 3703, 0); // TODO: 3704?
        assert!(deposited_shadow_share<UNI>(account1_addr) == 11111, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);        
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__borrow_and_deposit3(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 100000, false);
        deposit_internal<Asset>(key<USDC>(), account1, account1_addr, 50000, false);
        deposit_internal<Shadow>(key<USDT>(), account1, account1_addr, 50000, false);
        borrow_internal<Shadow>(key<WETH>(), account1, account1_addr, 9000);
        borrow_unsafe_for_test<USDT,Asset>(account1_addr, 47500);

        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 13407, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account1_addr) == 0, 0);

        assert!(deposited_asset_share<USDC>(account1_addr) == 50000, 0);
        assert!(borrowed_shadow_share<USDC>(account1_addr) == 6703, 0); // TODO: 6704?
        assert!(deposited_shadow_share<USDC>(account1_addr) == 0, 0);
        assert!(borrowed_asset_share<USDC>(account1_addr) == 0, 0);

        assert!(deposited_shadow_share<USDT>(account1_addr) == 50000, 0);
        assert!(borrowed_asset_share<USDT>(account1_addr) == 47500, 0);
        assert!(deposited_asset_share<USDT>(account1_addr) == 0, 0);
        assert!(borrowed_shadow_share<USDT>(account1_addr) == 0, 0);

        assert!(deposited_shadow_share<UNI>(account1_addr) == 11111, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
        assert!(deposited_asset_share<UNI>(account1_addr) == 0, 0);
        assert!(borrowed_shadow_share<UNI>(account1_addr) == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__borrow_and_deposit4(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 100000, false);
        deposit_internal<Asset>(key<USDC>(), account1, account1_addr, 50000, false);
        deposit_internal<Shadow>(key<USDT>(), account1, account1_addr, 50000, false);
        borrow_internal<Shadow>(key<WETH>(), account1, account1_addr, 50000);
        borrow_unsafe_for_test<USDT,Asset>(account1_addr, 47500);

        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 40740, 0); // TODO: 40741?
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account1_addr) == 0, 0);

        assert!(deposited_asset_share<USDC>(account1_addr) == 50000, 0);
        assert!(borrowed_shadow_share<USDC>(account1_addr) == 20370, 0);
        assert!(deposited_shadow_share<USDC>(account1_addr) == 0, 0);
        assert!(borrowed_asset_share<USDC>(account1_addr) == 0, 0);

        assert!(deposited_shadow_share<USDT>(account1_addr) == 50000, 0);
        assert!(borrowed_asset_share<USDT>(account1_addr) == 47500, 0);
        assert!(deposited_asset_share<USDT>(account1_addr) == 0, 0);
        assert!(borrowed_shadow_share<USDT>(account1_addr) == 0, 0);

        assert!(deposited_shadow_share<UNI>(account1_addr) == 11111, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
        assert!(deposited_asset_share<UNI>(account1_addr) == 0, 0);
        assert!(borrowed_shadow_share<UNI>(account1_addr) == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__borrow_and_deposit5(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 100000, false);
        deposit_internal<Asset>(key<USDC>(), account1, account1_addr, 50000, false);
        deposit_internal<Shadow>(key<USDT>(), account1, account1_addr, 50000, false);
        borrow_internal<Shadow>(key<WETH>(), account1, account1_addr, 50000);
        borrow_internal<Asset>(key<USDT>(), account1, account1_addr, 40000);
        disable_to_rebalance_internal<WETH>(account1);

        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 50000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account1_addr) == 0, 0);

        assert!(deposited_asset_share<USDC>(account1_addr) == 50000, 0);
        assert!(borrowed_shadow_share<USDC>(account1_addr) == 11111, 0);
        assert!(deposited_shadow_share<USDC>(account1_addr) == 0, 0);
        assert!(borrowed_asset_share<USDC>(account1_addr) == 0, 0);
        
        assert!(deposited_shadow_share<USDT>(account1_addr) == 48888, 0); // TODO: 48889?
        assert!(borrowed_asset_share<USDT>(account1_addr) == 40000, 0);
        assert!(deposited_asset_share<USDT>(account1_addr) == 0, 0);
        assert!(borrowed_shadow_share<USDT>(account1_addr) == 0, 0);

        assert!(deposited_shadow_share<UNI>(account1_addr) == 12222, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
        assert!(deposited_asset_share<UNI>(account1_addr) == 0, 0);
        assert!(borrowed_shadow_share<UNI>(account1_addr) == 0, 0);
    }
  
    // repay
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 1000, false); // for generating Position
        borrow_internal<Asset>(key<WETH>(), account, account_addr, 500);
        repay_internal<Asset>(key<WETH>(), account_addr, 250);
        assert!(deposited_shadow_share<WETH>(account_addr) == 1000, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 250, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 3, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 95 / 100, 0); // 95%

        // execute
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 10000, false);
        borrow_internal<Asset>(key<WETH>(), account, account_addr, 8999);
        repay_internal<Asset>(key<WETH>(), account_addr, 8999);
        let weth_key = key<WETH>();
        assert!(deposited_shadow_share<WETH>(account_addr) == 10000, 0);
        assert!(deposited_volume<ShadowToAsset>(account_addr, weth_key) == 10000, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_volume<ShadowToAsset>(account_addr, weth_key) == 0, 0);
        //// calculate
        assert!(utilization_of<ShadowToAsset>(borrow_global<Position<ShadowToAsset>>(account_addr), key<WETH>()) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_all_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 95 / 100, 0); // 95%

        // execute
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 10000, false);
        borrow_internal<Asset>(key<WETH>(), account, account_addr, 3999);
        borrow_internal<Asset>(key<WETH>(), account, account_addr, 5000);
        let share = repay_all_internal<WETH,Asset>(account_addr);
        assert!(share == 8999, 0);
        let weth_key = key<WETH>();
        assert!(deposited_shadow_share<WETH>(account_addr) == 10000, 0);
        assert!(deposited_volume<ShadowToAsset>(account_addr, weth_key) == 10000, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_volume<ShadowToAsset>(account_addr, weth_key) == 0, 0);
        //// calculate
        assert!(utilization_of<ShadowToAsset>(borrow_global<Position<ShadowToAsset>>(account_addr), key<WETH>()) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let weth_key = key<WETH>();
        let lt = risk_factor::lt_of(weth_key);
        assert!(lt == risk_factor::precision() * 85 / 100, 0); // 85%

        // execute
        deposit_internal<Asset>(key<WETH>(), account, account_addr, 10000, false);
        borrow_internal<Shadow>(key<WETH>(), account, account_addr, 6999);
        repay_internal<Shadow>(key<WETH>(), account_addr, 6999);
        assert!(deposited_asset_share<WETH>(account_addr) == 10000, 0);
        assert!(deposited_volume<AssetToShadow>(account_addr, weth_key) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_volume<AssetToShadow>(account_addr, weth_key) == 0, 0);
        //// calculate
        assert!(utilization_of<AssetToShadow>(borrow_global<Position<AssetToShadow>>(account_addr), weth_key) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_all_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let weth_key = key<WETH>();
        let lt = risk_factor::lt_of(weth_key);
        assert!(lt == risk_factor::precision() * 85 / 100, 0); // 85%

        // execute
        deposit_internal<Asset>(key<WETH>(), account, account_addr, 10000, false);
        borrow_internal<Shadow>(key<WETH>(), account, account_addr, 2999);
        borrow_internal<Shadow>(key<WETH>(), account, account_addr, 5000);
        let share = repay_all_internal<WETH,Shadow>(account_addr);
        assert!(share == 7999, 0);
        assert!(deposited_asset_share<WETH>(account_addr) == 10000, 0);
        assert!(deposited_volume<AssetToShadow>(account_addr, weth_key) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_volume<AssetToShadow>(account_addr, weth_key) == 0, 0);
        //// calculate
        assert!(utilization_of<AssetToShadow>(borrow_global<Position<AssetToShadow>>(account_addr), weth_key) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 196610)]
    public entry fun test_repay_asset_when_over_borrowed(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 10000, false);
        borrow_internal<Asset>(key<WETH>(), account, account_addr, 9999);
        repay_internal<Asset>(key<WETH>(), account_addr, 10000);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_repay_shadow_when_over_borrowed(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<Asset>(key<WETH>(), account, account_addr, 10000, false);
        borrow_internal<Shadow>(key<WETH>(), account, account_addr, 6999);
        repay_internal<Shadow>(key<WETH>(), account_addr, 7000);
    }

    // for liquidation
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 100, false);
        borrow_unsafe_for_test<WETH,Shadow>(account_addr, 90);
        assert!(deposited_asset_share<WETH>(account_addr) == 100, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 90, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Asset>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 90, 0);
        assert!(!is_collateral_only, 0);
        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 4, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_asset_conly(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 100, true);
        borrow_unsafe_for_test<WETH,Shadow>(account_addr, 90);
        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 100, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 90, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Asset>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 90, 0);
        assert!(is_collateral_only, 0);
        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 4, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 100, false);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 110);
        assert!(deposited_shadow_share<WETH>(account_addr) == 100, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 110, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 110, 0);
        assert!(!is_collateral_only, 0);
        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 4, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_shadow_conly(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 100, true);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 110);
        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 100, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 110, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 110, 0);
        assert!(is_collateral_only, 0);
        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 4, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_two_shadow_position(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 100, true);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 190);
        deposit_internal<Shadow>(key<UNI>(), account, account_addr, 80, false);
        borrow_unsafe_for_test<UNI,Asset>(account_addr, 170);
        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(deposited_shadow_share<UNI>(account_addr) == 80, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 100, 0);
        assert!(conly_deposited_shadow_share<UNI>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 190, 0);
        assert!(borrowed_asset_share<UNI>(account_addr) == 170, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 190, 0);
        assert!(is_collateral_only, 0);
        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 0, 0);
        let (deposited, borrowed, is_collateral_only) = liquidate_internal<UNI,Shadow>(account_addr);
        assert!(deposited == 80, 0);
        assert!(borrowed == 170, 0);
        assert!(!is_collateral_only, 0);
        assert!(deposited_shadow_share<UNI>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 8, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_asset_and_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 100, true);
        borrow_unsafe_for_test<WETH,Shadow>(account_addr, 190);
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 80, false);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 170);
        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(deposited_shadow_share<WETH>(account_addr) == 80, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 100, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 190, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 170, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Asset>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 190, 0);
        assert!(is_collateral_only, 0);
        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 0, 0);
        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
        assert!(deposited == 80, 0);
        assert!(borrowed == 170, 0);
        assert!(!is_collateral_only, 0);
        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 4, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 4, 0);
    }
    // #[test(owner=@leizd,account=@0x111)]
    // public entry fun test_liquidate_shadow_if_rebalance_should_be_done(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
    //     // TODO: logic

    //     setup(owner);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     let account_addr = signer::address_of(account);
    //     account::create_account_for_test(account_addr);

    //     deposit_internal<Shadow>(key<WETH>(), account, account_addr, 100, false);
    //     borrow_unsafe_for_test<WETH,Asset>(account_addr, 190);
    //     deposit_internal<Shadow>(key<UNI>(), account, account_addr, 100, false);
    //     assert!(deposited_shadow_share<WETH>(account_addr) == 100, 0);
    //     assert!(deposited_shadow_share<UNI>(account_addr) == 100, 0);
    //     assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
    //     assert!(conly_deposited_shadow_share<UNI>(account_addr) == 0, 0);
    //     assert!(borrowed_asset_share<WETH>(account_addr) == 190, 0);
    //     assert!(borrowed_asset_share<UNI>(account_addr) == 0, 0);

    //     let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
    //     assert!(deposited == 0, 0);
    //     assert!(borrowed == 0, 0);
    //     assert!(!is_collateral_only, 0);
    //     assert!(deposited_shadow_share<WETH>(account_addr) == 200, 0);
    //     // assert!(deposited_shadow_share<UNI>(account_addr) == 10, 0);
    //     // assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
    //     // assert!(conly_deposited_shadow_share<UNI>(account_addr) == 0, 0);
    //     // assert!(borrowed_asset_share<WETH>(account_addr) == 190, 0);
    //     // assert!(borrowed_asset_share<UNI>(account_addr) == 0, 0);
    // }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 196610)]
    public entry fun test_liquidate_asset_if_safe(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 1, true);
        liquidate_internal<WETH,Asset>(account_addr);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 196610)]
    public entry fun test_liquidate_shadow_if_safe(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 1, true);
        liquidate_internal<WETH,Shadow>(account_addr);
    }

    // mixture
    //// check existence of resources
    ////// withdraw all -> re-deposit (borrowable / asset)
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_check_existence_of_position_when_withdraw_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let coin_key = key<WETH>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<Asset>(key<WETH>(), account, account_addr, 10001, false);
        withdraw_internal<Asset>(key<WETH>(), account_addr, 10000, false);
        let pos_ref1 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(vector::contains<String>(&pos_ref1.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos_ref1.balance, &coin_key), 0);

        withdraw_internal<Asset>(key<WETH>(), account_addr, 1, false);
        let pos_ref2 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(!vector::contains<String>(&pos_ref2.coins, &coin_key), 0);
        assert!(!simple_map::contains_key<String,Balance>(&pos_ref2.balance, &coin_key), 0);

        deposit_internal<Asset>(key<WETH>(), account, account_addr, 1, false);
        let pos_ref3 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(vector::contains<String>(&pos_ref3.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos_ref3.balance, &coin_key), 0);
    }
    ////// withdraw all -> re-deposit (collateral only / shadow)
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_check_existence_of_position_when_withdraw_shadow_collateral_only(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let coin_key = key<UNI>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<Shadow>(key<UNI>(), account, account_addr, 10001, true);
        withdraw_internal<Shadow>(key<UNI>(), account_addr, 10000, true);
        let pos1_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(vector::contains<String>(&pos1_ref.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos1_ref.balance, &coin_key), 0);

        withdraw_internal<Shadow>(key<UNI>(), account_addr, 1, true);
        let pos2_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(!vector::contains<String>(&pos2_ref.coins, &coin_key), 0);
        assert!(!simple_map::contains_key<String,Balance>(&pos2_ref.balance, &coin_key), 0);

        deposit_internal<Shadow>(key<UNI>(), account, account_addr, 1, true);
        let pos3_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(vector::contains<String>(&pos3_ref.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos3_ref.balance, &coin_key), 0);
    }
    ////// repay all -> re-deposit (borrowable / asset)
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_check_existence_of_position_when_repay_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let coin_key = key<UNI>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // prepares (temp)
        initialize_position_if_necessary(account);
        new_position<AssetToShadow>(account_addr, 0, 0, false, coin_key);

        // execute
        borrow_unsafe_for_test<UNI, Shadow>(account_addr, 10001);
        repay_internal<Shadow>(key<UNI>(), account_addr, 10000);
        let pos_ref1 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(vector::contains<String>(&pos_ref1.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos_ref1.balance, &coin_key), 0);

        repay_internal<Shadow>(key<UNI>(), account_addr, 1);
        let pos_ref2 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(!vector::contains<String>(&pos_ref2.coins, &coin_key), 0);
        assert!(!simple_map::contains_key<String,Balance>(&pos_ref2.balance, &coin_key), 0);

        deposit_internal<Asset>(key<UNI>(), account, account_addr, 1, false);
        let pos_ref3 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(vector::contains<String>(&pos_ref3.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos_ref3.balance, &coin_key), 0);
    }
    ////// repay all -> re-deposit (collateral only / shadow)
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_check_existence_of_position_when_repay_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let coin_key = key<WETH>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // prepares (temp)
        initialize_position_if_necessary(account);
        new_position<ShadowToAsset>(account_addr, 0, 0, false, coin_key);

        // execute
        borrow_unsafe_for_test<WETH, Asset>(account_addr, 10001);
        repay_internal<Asset>(key<WETH>(), account_addr, 10000);
        let pos1_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(vector::contains<String>(&pos1_ref.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos1_ref.balance, &coin_key), 0);

        repay_internal<Asset>(key<WETH>(), account_addr, 1);
        let pos2_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(!vector::contains<String>(&pos2_ref.coins, &coin_key), 0);
        assert!(!simple_map::contains_key<String,Balance>(&pos2_ref.balance, &coin_key), 0);

        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 1, true);
        let pos3_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(vector::contains<String>(&pos3_ref.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos3_ref.balance, &coin_key), 0);
    }
    //// multiple executions
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_and_withdraw_more_than_once_sequentially(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<Asset>(key<WETH>(), account, account_addr, 10000, false);
        withdraw_internal<Asset>(key<WETH>(), account_addr, 10000, false);
        deposit_internal<Asset>(key<WETH>(), account, account_addr, 2000, false);
        deposit_internal<Asset>(key<WETH>(), account, account_addr, 3000, false);
        withdraw_internal<Asset>(key<WETH>(), account_addr, 1000, false);
        withdraw_internal<Asset>(key<WETH>(), account_addr, 4000, false);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 6, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_borrow_and_repay_more_than_once_sequentially(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<Shadow>(key<WETH>(), account, account_addr, 10000, false);
        borrow_internal<Asset>(key<WETH>(), account, account_addr, 5000);
        repay_internal<Asset>(key<WETH>(), account_addr, 5000);
        borrow_internal<Asset>(key<WETH>(), account, account_addr, 2000);
        borrow_internal<Asset>(key<WETH>(), account, account_addr, 3000);
        repay_internal<Asset>(key<WETH>(), account_addr, 1000);
        repay_internal<Asset>(key<WETH>(), account_addr, 4000);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 7, 0);
    }

    // switch collateral
    #[test(owner = @leizd, account1 = @0x111)]
    public entry fun test_switch_collateral_with_asset(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 10000, false);
        assert!(deposited_asset_share<WETH>(account1_addr) == 10000, 0);
        assert!(conly_deposited_asset_share<WETH>(account1_addr) == 0, 0);

        let deposited = switch_collateral_internal<WETH,Asset>(account1_addr, true);
        assert!(deposited == 10000, 0);
        assert!(deposited_asset_share<WETH>(account1_addr) == 0, 0);
        assert!(conly_deposited_asset_share<WETH>(account1_addr) == 10000, 0);

        deposit_internal<Asset>(key<WETH>(), account1, account1_addr, 30000, true);
        let deposited = switch_collateral_internal<WETH,Asset>(account1_addr, false);
        assert!(deposited == 40000, 0);
        assert!(deposited_asset_share<WETH>(account1_addr) == 40000, 0);
        assert!(conly_deposited_asset_share<WETH>(account1_addr) == 0, 0);
    }
    #[test(owner = @leizd, account1 = @0x111)]
    public entry fun test_switch_collateral_with_shadow(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle, GlobalPositionEventHandle {
        setup(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        deposit_internal<Shadow>(key<WETH>(), account1, account1_addr, 10000, true);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account1_addr) == 10000, 0);

        let deposited = switch_collateral_internal<WETH,Shadow>(account1_addr, false);
        assert!(deposited == 10000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 10000, 0);
        assert!(conly_deposited_shadow_share<WETH>(account1_addr) == 0, 0);

        deposit_internal<Shadow>(key<WETH>(), account1, account1_addr, 30000, false);
        let deposited = switch_collateral_internal<WETH,Shadow>(account1_addr, true);
        assert!(deposited == 40000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account1_addr) == 40000, 0);
    }
}
