module leizd::account_position {

    use std::error;
    use std::signer;
    use std::vector;
    use std::option::{Self,Option};
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::comparator;
    use aptos_std::simple_map;
    use aptos_framework::account;
    use leizd::rebalance::{Self,Rebalance};
    use leizd_aptos_common::pool_type;
    use leizd_aptos_common::position_type::{Self,AssetToShadow,ShadowToAsset};
    use leizd_aptos_common::coin_key::{key};
    use leizd_aptos_external::price_oracle;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd_aptos_lib::constant;
    use leizd::risk_factor;

    friend leizd::money_market;

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

    /// P: The position type - AssetToShadow or ShadowToAsset.
    struct Position<phantom P> has key {
        coins: vector<String>, // e.g. 0x1::module_name::WBTC
        protected_coins: simple_map::SimpleMap<String,bool>, // e.g. 0x1::module_name::WBTC - true, NOTE: use only ShadowToAsset (need to refactor)
        balance: simple_map::SimpleMap<String,Balance>,
    }

    struct Balance has store, drop {
        deposited: u64,
        conly_deposited: u64,
        borrowed: u64,
    }

    // Events
    struct UpdatePositionEvent has store, drop {
        key: String,
        deposited: u64,
        conly_deposited: u64,
        borrowed: u64,
    }

    struct AccountPositionEventHandle<phantom P> has key, store {
        update_position_event: event::EventHandle<UpdatePositionEvent>,
    }

    public fun deposited_asset<C>(addr: address): u64 acquires Position {
        if (!exists<Position<AssetToShadow>>(addr)) return 0;
        let key = key<C>();
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).deposited
        } else {
            0
        }
    }

    public fun conly_deposited_asset<C>(addr: address): u64 acquires Position {
        conly_deposited_asset_with(addr, key<C>())
    }

    public fun conly_deposited_asset_with(addr: address, key: String): u64 acquires Position {
        if (!exists<Position<AssetToShadow>>(addr)) return 0;
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).conly_deposited
        } else {
            0
        }
    }

    public fun borrowed_asset<C>(addr: address): u64 acquires Position {
        let key = key<C>();
        if (!exists<Position<ShadowToAsset>>(addr)) return 0;
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed
        } else {
            0
        }
    }

    public fun deposited_shadow<C>(addr: address): u64 acquires Position {
        deposited_shadow_with(key<C>(), addr)
    }

    public fun deposited_shadow_with(key: String, addr: address): u64 acquires Position {
        if (!exists<Position<ShadowToAsset>>(addr)) return 0;
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).deposited
        } else {
            0
        }
    }

    public fun conly_deposited_shadow<C>(addr: address): u64 acquires Position {
        let key = key<C>();
        conly_deposited_shadow_with(addr, key)
    }

    public fun conly_deposited_shadow_with(addr: address, key: String): u64 acquires Position {
        if (!exists<Position<ShadowToAsset>>(addr)) return 0;
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).conly_deposited
        } else {
            0
        }
    }

    public fun borrowed_shadow<C>(addr: address): u64 acquires Position {
        let key = key<C>();
        borrowed_shadow_with(key, addr)
    }

    public fun borrowed_shadow_with(key: String, addr: address): u64 acquires Position {
        if (!exists<Position<AssetToShadow>>(addr)) return 0;
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed
        } else {
            0
        }
    }

    fun initialize_if_necessary(account: &signer) {
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

    public(friend) fun enable_to_rebalance<C>(account: &signer) acquires Position {
        let key = key<C>();
        let position_ref = borrow_global_mut<Position<ShadowToAsset>>(signer::address_of(account));
        // assert!(vector::contains<String>(&position_ref.coins, &key), ENOT_EXISTED); // TODO: temp
        assert!(!is_protected_internal(&position_ref.protected_coins, key), EALREADY_PROTECTED);

        simple_map::add<String,bool>(&mut position_ref.protected_coins, key, true);
    }

    public(friend) fun unable_to_rebalance<C>(account: &signer) acquires Position {
        let key = key<C>();
        let position_ref = borrow_global_mut<Position<ShadowToAsset>>(signer::address_of(account));
        // assert!(vector::contains<String>(&position_ref.coins, &key), ENOT_EXISTED); // TODO: temp
        assert!(is_protected_internal(&position_ref.protected_coins, key), EALREADY_PROTECTED);

        simple_map::remove<String,bool>(&mut position_ref.protected_coins, &key);
    }

    public fun is_protected<C>(account_addr: address): bool acquires Position {
        let key = key<C>();
        let position_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        is_protected_internal(&position_ref.protected_coins, key)
    }
    fun is_protected_internal(protected_coins: &simple_map::SimpleMap<String,bool>, key: String): bool {
        simple_map::contains_key<String,bool>(protected_coins, &key)
    }

    public(friend) fun deposit<C,P>(account: &signer, depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        deposit_internal<C,P>(account, depositor_addr, amount, is_collateral_only);
    }

    fun deposit_internal<C,P>(account: &signer, depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        initialize_if_necessary(account);
        assert!(exists<Position<AssetToShadow>>(depositor_addr), error::invalid_argument(ENO_POSITION_RESOURCE));

        if (pool_type::is_type_asset<P>()) {
            assert_invalid_deposit_asset<C>(depositor_addr, is_collateral_only);
            update_on_deposit<C,AssetToShadow>(depositor_addr, amount, is_collateral_only);
        } else {
            assert_invalid_deposit_shadow<C>(depositor_addr, is_collateral_only);
            update_on_deposit<C,ShadowToAsset>(depositor_addr, amount, is_collateral_only);
        };
    }

    fun assert_invalid_deposit_asset<C>(depositor_addr: address, is_collateral_only: bool) acquires Position {
        let deposited = deposited_asset<C>(depositor_addr);
        if (deposited > 0) {
            let conly_deposited = conly_deposited_asset<C>(depositor_addr);
            if (conly_deposited > 0) {
                assert!(is_collateral_only, error::invalid_argument(EALREADY_DEPOSITED_AS_COLLATERAL_ONLY));
            } else {
                assert!(!is_collateral_only, error::invalid_argument(EALREADY_DEPOSITED_AS_NORMAL));
            }
        }
    }

    fun assert_invalid_deposit_shadow<C>(depositor_addr: address, is_collateral_only: bool) acquires Position {
        let deposited = deposited_shadow<C>(depositor_addr);
        if (deposited > 0) {
            let conly_deposited = conly_deposited_shadow<C>(depositor_addr);
            if (conly_deposited > 0) {
                assert!(is_collateral_only, error::invalid_argument(EALREADY_DEPOSITED_AS_COLLATERAL_ONLY));
            } else {
                assert!(!is_collateral_only, error::invalid_argument(EALREADY_DEPOSITED_AS_NORMAL));
            }
        }
    }

    public(friend) fun withdraw<C,P>(depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        withdraw_internal<C,P>(depositor_addr, amount, is_collateral_only);
    }

    fun withdraw_internal<C,P>(depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        if (pool_type::is_type_asset<P>()) {
            update_on_withdraw<C,AssetToShadow>(depositor_addr, amount, is_collateral_only);
            assert!(is_safe<C,AssetToShadow>(depositor_addr), error::invalid_state(ENO_SAFE_POSITION));
        } else {
            update_on_withdraw<C,ShadowToAsset>(depositor_addr, amount, is_collateral_only);
            assert!(is_safe<C,ShadowToAsset>(depositor_addr), error::invalid_state(ENO_SAFE_POSITION));
        };
    }

    public(friend) fun borrow<C,P>(addr: address, amount: u64) acquires Position, AccountPositionEventHandle {
        borrow_internal<C,P>(addr, amount);
    }

    fun borrow_internal<C,P>(borrower_addr: address, amount: u64) acquires Position, AccountPositionEventHandle {
        if (pool_type::is_type_asset<P>()) {
            update_on_borrow<C,ShadowToAsset>(borrower_addr, amount);
            assert!(is_safe<C,ShadowToAsset>(borrower_addr), error::invalid_state(ENO_SAFE_POSITION));
        } else {
            update_on_borrow<C,AssetToShadow>(borrower_addr, amount);
            assert!(is_safe<C,AssetToShadow>(borrower_addr), error::invalid_state(ENO_SAFE_POSITION));
        };
    }

    fun required_shadow(borrowed_key: String, borrowed_asset: u64, deposited_shadow: u64): u64 {
        let borrowed_volume = price_oracle::volume(&borrowed_key, borrowed_asset);
        let deposited_volume = price_oracle::volume(&key<USDZ>(), deposited_shadow);
        let required_shadow_for_current_borrow = borrowed_volume * risk_factor::precision() / risk_factor::ltv_of(borrowed_key);
        if (required_shadow_for_current_borrow < deposited_volume) return 0;
        (required_shadow_for_current_borrow - deposited_volume)
    }

    /// @returns (sum_extra_shadow, result_amount_deposited, result_amount_withdrawed)
    fun deposit_and_withdraw_evenly(addr: address, required_shadow: u64, borrowed_now: u64, repaid_now: u64): (u64,vector<Rebalance>, vector<Rebalance>) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        let coins = position_ref.coins;
        let result_amount_deposited = vector::empty<Rebalance>();
        let result_amount_withdrawed = vector::empty<Rebalance>();
        let i = vector::length<String>(&coins);
        let sum_extra_shadow = 0;
        while (i > 0) {
            let key = vector::borrow<String>(&coins, i-1);
            sum_extra_shadow = sum_extra_shadow + extra_shadow(*key, addr);
            i = i - 1;
        };
        // borrowed_now/repaid_now: still not deposited
        sum_extra_shadow = sum_extra_shadow + borrowed_now - repaid_now;

        if (required_shadow <= sum_extra_shadow) {
            // reallocation
            let i = vector::length<String>(&coins);
            let extra_for_each = required_shadow / i;
            while (i > 0) {
                let key = *vector::borrow<String>(&coins, i-1);
                let deposited_shadow = deposited_shadow_with(key, addr);
                if (extra_for_each == deposited_shadow) {
                    // nothing happens
                    // skip
                } else if (extra_for_each > deposited_shadow) {
                    // deposit
                    let amount = extra_for_each - deposited_shadow;
                    update_position_for_deposit<ShadowToAsset>(key, addr, amount, false); // TODO: put collateral only
                    vector::push_back<Rebalance>(&mut result_amount_deposited, rebalance::create(key, amount));
                } else {
                    // withdraw
                    let amount = deposited_shadow - extra_for_each;
                    update_position_for_withdraw<ShadowToAsset>(key, addr, amount, false); // TODO: put collateral only
                    vector::push_back<Rebalance>(&mut result_amount_withdrawed, rebalance::create(key, amount));
                };
                i = i - 1;
            };
        };
        (sum_extra_shadow, result_amount_deposited, result_amount_withdrawed)
    }

    /// @returns (sum_extra_shadow, borrowed_sum, repaid_sum, result_amount_borrowed, result_amount_repaied)
    fun borrow_and_repay_evenly(addr: address, required_shadow: u64, sum_extra_shadow: u64): (u64,u64,u64,vector<Rebalance>, vector<Rebalance>) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        let coins = position_ref.coins;
        
        // return params
        let borrowed_sum = 0;
        let repaid_sum = 0;
        let result_amount_borrowed = vector::empty<Rebalance>();
        let result_amount_repaid = vector::empty<Rebalance>();

        let i = vector::length<String>(&coins);
        let sum_borrowable_shadow = 0;
        while (i > 0) {
            let key = vector::borrow<String>(&coins, i-1);
            sum_borrowable_shadow = sum_borrowable_shadow + borrowable_shadow(*key, addr);
            i = i - 1;
        };
        if (required_shadow <= sum_extra_shadow + sum_borrowable_shadow) {
            // borrow and rebalance

            // 1.borrow
            let i = vector::length<String>(&coins);
            let borrow_amount = required_shadow - sum_extra_shadow;
            let borrow_for_each = borrow_amount / i;
            while (i > 0) {
                let key = *vector::borrow<String>(&coins, i-1);
                let borrowed_shadow = borrowed_shadow_with(key, addr);
                if (borrow_for_each == borrowed_shadow) {
                    // nothing happens
                    // skip
                } else if (borrow_for_each > borrowed_shadow) {
                    // borrow
                    let amount = borrow_for_each - borrowed_shadow;
                    update_position_for_borrow<AssetToShadow>(key, addr, amount);
                    vector::push_back<Rebalance>(&mut result_amount_borrowed, rebalance::create(key, amount));
                    borrowed_sum = borrowed_sum + amount;
                } else {
                    // repay
                    let amount = borrowed_shadow - borrow_for_each;
                    update_position_for_repay<AssetToShadow>(key, addr, amount);
                    vector::push_back<Rebalance>(&mut result_amount_repaid, rebalance::create(key, amount));
                    repaid_sum = repaid_sum + amount;
                };
                i = i - 1;
            };
        };
        (sum_borrowable_shadow, borrowed_sum, repaid_sum, result_amount_borrowed, result_amount_repaid)
    }

    public(friend) fun borrow_asset_with_rebalance<C>(
        addr: address, 
        amount: u64
    ):(
        vector<Rebalance>,
        vector<Rebalance>,
        vector<Rebalance>,
        vector<Rebalance>
    ) acquires Position, AccountPositionEventHandle {
        let result_amount_deposited = vector::empty<Rebalance>();
        let result_amount_withdrawed = vector::empty<Rebalance>();
        let result_amount_borrowed = vector::empty<Rebalance>();
        let result_amount_repaid = vector::empty<Rebalance>();
        let borrowed_now;
        let repaid_now;
        
        update_on_borrow<C,ShadowToAsset>(addr, amount);
        if (is_safe<C,ShadowToAsset>(addr)) {
            return (result_amount_deposited, result_amount_withdrawed, result_amount_borrowed, result_amount_repaid)
        };

        // try to rebalance between pools
        let sum_extra_shadow;
        let required_shadow = required_shadow(key<C>(), borrowed_asset<C>(addr), deposited_shadow<C>(addr));
        (sum_extra_shadow, result_amount_deposited, result_amount_withdrawed) = deposit_and_withdraw_evenly(addr, required_shadow, 0, 0);
        if (vector::length<Rebalance>(&result_amount_deposited) != 0 
            || vector::length<Rebalance>(&result_amount_withdrawed) != 0) {
            return (result_amount_deposited, result_amount_withdrawed, result_amount_borrowed, result_amount_repaid)
        };

        // try to borrow and rebalance shadow
        (_,borrowed_now,repaid_now,result_amount_borrowed, result_amount_repaid) = borrow_and_repay_evenly(addr, required_shadow, sum_extra_shadow);
        if (vector::length<Rebalance>(&result_amount_borrowed) != 0
            || vector::length<Rebalance>(&result_amount_repaid) != 0) {
            (_, result_amount_deposited, result_amount_withdrawed) = deposit_and_withdraw_evenly(addr, required_shadow, borrowed_now, repaid_now);
            return (result_amount_deposited, result_amount_withdrawed, result_amount_borrowed, result_amount_repaid)
        };
        abort 0
    }

    public(friend) fun repay<C,P>(addr: address, amount: u64) acquires Position, AccountPositionEventHandle {
        if (pool_type::is_type_asset<P>()) {
            update_on_repay<C,ShadowToAsset>(addr, amount);
        } else {
            update_on_repay<C,AssetToShadow>(addr, amount);
        };
    }

    public(friend) fun repay_shadow_with_rebalance(addr: address, amount: u64): (vector<String>, vector<u64>) acquires Position, AccountPositionEventHandle {
        let result_key = vector::empty<String>();
        let result_amount = vector::empty<u64>();

        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        let coins = position_ref.coins;

        let i = vector::length<String>(&coins);
        let sum_borrowed_shadow = 0;
        while (i > 0) {
            let key = vector::borrow<String>(&coins, i-1);
            sum_borrowed_shadow = sum_borrowed_shadow + borrowed_shadow_with(*key, addr);
            i = i - 1;
        };
        
        if (sum_borrowed_shadow <= amount) {
            // repay all
            let i = vector::length<String>(&coins);
            while (i > 0) {
                let key = vector::borrow<String>(&coins, i-1);
                let repayable = borrowed_shadow_with(*key, addr);
                update_position_for_repay<AssetToShadow>(*key, addr, repayable);
                vector::push_back<String>(&mut result_key, *key);
                vector::push_back<u64>(&mut result_amount, repayable);
                i = i - 1;
            };
        } else {
            // repay to even out
            let i = vector::length<String>(&coins);
            let debt_left = sum_borrowed_shadow - amount;
            let each_debt = debt_left / i;
            while (i > 0) {
                let key = vector::borrow<String>(&coins, i-1);
                let repayable = borrowed_shadow_with(*key, addr) - each_debt;
                update_position_for_repay<AssetToShadow>(*key, addr, repayable);
                vector::push_back<String>(&mut result_key, *key);
                vector::push_back<u64>(&mut result_amount, repayable);
                i = i - 1;
            };
        };
        (result_key, result_amount)
    }

    public(friend) fun liquidate<C,P>(target_addr: address): (u64,u64,bool) acquires Position, AccountPositionEventHandle {
        liquidate_internal<C,P>(target_addr)
    }

    fun liquidate_internal<C,P>(target_addr: address): (u64,u64,bool) acquires Position, AccountPositionEventHandle {
        if (pool_type::is_type_asset<P>()) {
            assert!(!is_safe<C,AssetToShadow>(target_addr), error::invalid_state(ENO_SAFE_POSITION));
            let deposited = deposited_asset<C>(target_addr);
            assert!(deposited > 0, error::invalid_argument(ENO_DEPOSITED));
            let is_collateral_only = conly_deposited_asset<C>(target_addr) > 0;
            update_on_withdraw<C, AssetToShadow>(target_addr, deposited, is_collateral_only);
            let borrowed = borrowed_shadow<C>(target_addr);
            update_on_repay<C,AssetToShadow>(target_addr, borrowed);
            assert!(is_zero_position<C,AssetToShadow>(target_addr), error::invalid_state(EPOSITION_EXISTED));
            (deposited, borrowed, is_collateral_only)
        } else {
            assert!(!is_safe<C,ShadowToAsset>(target_addr), error::invalid_state(ENO_SAFE_POSITION));
            
            // rebalance shadow if possible
            let from_key = key_rebalanced_from<C>(target_addr);
            if (option::is_some(&from_key)) {
                // rebalance
                rebalance_shadow_internal(target_addr, *option::borrow<String>(&from_key), key<C>());
                return (0, 0, false)
            };

            let deposited = deposited_shadow<C>(target_addr);
            assert!(deposited > 0, error::invalid_argument(ENO_DEPOSITED));
            let is_collateral_only = conly_deposited_shadow<C>(target_addr) > 0;
            update_on_withdraw<C,ShadowToAsset>(target_addr, deposited, is_collateral_only);
            let borrowed = borrowed_asset<C>(target_addr);
            update_on_repay<C,ShadowToAsset>(target_addr, borrowed);
            assert!(is_zero_position<C,ShadowToAsset>(target_addr), error::invalid_state(EPOSITION_EXISTED));
            (deposited, borrowed, is_collateral_only)
        }
    }

    // Rebalance between shadow pools

    public(friend) fun rebalance_shadow<C1,C2>(addr: address): (u64,bool,bool) acquires Position, AccountPositionEventHandle {
        let key1 = key<C1>();
        let key2 = key<C2>();
        rebalance_shadow_internal(addr, key1, key2)
    }

    fun rebalance_shadow_internal(addr: address, key1: String, key2: String): (u64,bool,bool) acquires Position, AccountPositionEventHandle {
        let is_collateral_only_C1 = conly_deposited_shadow_with(addr, key1) > 0;
        let is_collateral_only_C2 = conly_deposited_shadow_with(addr, key2) > 0;
        
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        assert!(vector::contains<String>(&position_ref.coins, &key1), ENOT_EXISTED);
        assert!(vector::contains<String>(&position_ref.coins, &key2), ENOT_EXISTED);
        assert!(!is_protected_internal(&position_ref.protected_coins, key1), EALREADY_PROTECTED);
        assert!(!is_protected_internal(&position_ref.protected_coins, key2), EALREADY_PROTECTED);

        let (can_rebalance,_,insufficient) = can_rebalance_shadow_between(addr, key1, key2);

        assert!(can_rebalance, error::invalid_argument(ECANNOT_REBALANCE));
        update_position_for_withdraw<ShadowToAsset>(key1, addr, insufficient, is_collateral_only_C1);
        update_position_for_deposit<ShadowToAsset>(key2, addr, insufficient, is_collateral_only_C2);

        (insufficient, is_collateral_only_C1, is_collateral_only_C2)
    }

    fun is_the_same(key1: String, key2: String): bool {
        comparator::is_equal(
            &comparator::compare<String>(
                &key1,
                &key2,
            )
        )
    }

    fun extra_shadow(key: String, addr: address): u64 acquires Position {
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key);
        let deposited = deposited_volume<ShadowToAsset>(addr, key);
        let required_deposit = borrowed * risk_factor::precision() / risk_factor::lt_of_shadow();
        if (deposited < required_deposit) return 0;
        deposited - required_deposit
    }

    fun can_rebalance_shadow_between(addr: address, key1: String, key2: String): (bool,u64,u64) acquires Position {
        if (is_the_same(key1, key2)) {
            return (false, 0, 0)
        };

        // extra in key1
        let extra = extra_shadow(key1, addr);
        if (extra == 0) return (false, 0, 0);

        // insufficient in key2
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key2);
        let deposited = deposited_volume<ShadowToAsset>(addr, key2);
        let required_deposit = borrowed * risk_factor::precision() / risk_factor::lt_of_shadow();
        if (required_deposit < deposited) return (false, 0, 0);
        let insufficient = required_deposit - deposited;

        (extra >= insufficient, extra, insufficient)
    }

    fun key_rebalanced_from<C>(addr: address): Option<String> acquires Position {
        let key_insufficient = key<C>();
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        let coins = position_ref.coins;

        let i = vector::length<String>(&coins);
        while (i > 0) {
            let key_coin = vector::borrow<String>(&coins, i-1);
            let (can_rebalance,_,_) = can_rebalance_shadow_between(addr, *key_coin, key_insufficient);
            if (can_rebalance) {
                return option::some(*key_coin)
            };
            i = i - 1;
        };
        option::none()
    }

    // Rebalance after borrowing additonal shadow

    public(friend) fun borrow_and_rebalance<C1,C2>(addr: address, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle {
        let key1 = key<C1>();
        let key2 = key<C2>();
        borrow_and_rebalance_internal(addr, key1, key2, is_collateral_only)
    }

    fun key_rebalanced_with_borrow_from<C>(addr: address): Option<String> acquires Position {
        let key_insufficient = key<C>();
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        let coins = position_ref.coins;

        let i = vector::length<String>(&coins);
        while (i > 0) {
            let key_coin = vector::borrow<String>(&coins, i-1);
            let (can_rebalance,_,_) = can_borrow_and_rebalance(addr, *key_coin, key_insufficient);
            if (can_rebalance) {
                return option::some(*key_coin)
            };
            i = i - 1;
        };
        option::none()
    }

    fun borrowable_shadow(key: String, addr: address): u64 acquires Position {
        let borrowed = borrowed_volume<AssetToShadow>(addr, key);
        let deposited = deposited_volume<AssetToShadow>(addr, key);
        let borrowable = deposited * risk_factor::lt_of(key) / risk_factor::precision();
        if (borrowable < borrowed) return 0;
        borrowable - borrowed
    }

    fun can_borrow_and_rebalance(addr: address, key1: String, key2: String):(bool,u64,u64) acquires Position {
        if (is_the_same(key1, key2)) {
            return (false, 0, 0)
        };

        // extra in key1
        let extra_borrow = borrowable_shadow(key1, addr);
        if (extra_borrow == 0) return (false, 0, 0);

        // insufficient in key2
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key2);
        let deposited = deposited_volume<ShadowToAsset>(addr, key2);
        let required_deposit = borrowed * risk_factor::precision() / risk_factor::lt_of_shadow();
        let insufficient = required_deposit - deposited;

        (extra_borrow >= insufficient, extra_borrow, insufficient)
    }

    fun borrow_and_rebalance_internal(addr: address, key1:String, key2: String, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle {
        let pos_ref_asset_to_shadow = borrow_global<Position<AssetToShadow>>(addr);
        let pos_ref_shadow_to_asset = borrow_global<Position<ShadowToAsset>>(addr);
        assert!(vector::contains<String>(&pos_ref_asset_to_shadow.coins, &key1), ENOT_EXISTED);
        assert!(vector::contains<String>(&pos_ref_shadow_to_asset.coins, &key2), ENOT_EXISTED);
        assert!(!is_protected_internal(&pos_ref_shadow_to_asset.protected_coins, key1), EALREADY_PROTECTED); // NOTE: use only Position<ShadowToAsset> to check protected coin
        assert!(!is_protected_internal(&pos_ref_shadow_to_asset.protected_coins, key2), EALREADY_PROTECTED); // NOTE: use only Position<ShadowToAsset> to check protected coin

        let (possible, _, insufficient) = can_borrow_and_rebalance(addr, key1, key2);
        assert!(possible, 0);
        update_position_for_borrow<AssetToShadow>(key1, addr, insufficient);
        update_position_for_deposit<ShadowToAsset>(key2, addr, insufficient, is_collateral_only);

        insufficient
    }

    public(friend) fun switch_collateral<C,P>(addr: address, to_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle {
        let deposited;
        if (pool_type::is_type_asset<P>()) {
            if (to_collateral_only) {
                deposited = deposited_asset<C>(addr);
                update_on_withdraw<C,AssetToShadow>(addr, deposited, false);
                update_on_deposit<C,AssetToShadow>(addr, deposited, true);
            } else {
                deposited = conly_deposited_asset<C>(addr);
                update_on_withdraw<C,AssetToShadow>(addr, deposited, true);
                update_on_deposit<C,AssetToShadow>(addr, deposited, false);
            }
        } else {
            if (to_collateral_only) {
                deposited = deposited_shadow<C>(addr);
                update_on_withdraw<C,ShadowToAsset>(addr, deposited, false);
                update_on_deposit<C,ShadowToAsset>(addr, deposited, true);
            } else {
                deposited = conly_deposited_shadow<C>(addr);
                update_on_withdraw<C,ShadowToAsset>(addr, deposited, true);
                update_on_deposit<C,ShadowToAsset>(addr, deposited, false);
            }
        };
        deposited
    }

    fun deposited_volume<P>(addr: address, key: String): u64 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let deposited = simple_map::borrow<String,Balance>(&position_ref.balance, &key).deposited;
            price_oracle::volume(&key, deposited)
        } else {
            0
        }
    }

    fun borrowed_volume<P>(addr: address, key: String): u64 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let borrowed = simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed;
            price_oracle::volume(&key, borrowed)
        } else {
            0
        }
    }

    fun update_on_deposit<C,P>(
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool
    ) acquires Position, AccountPositionEventHandle {
        let key = key<C>();
        update_position_for_deposit<P>(key, depositor_addr, amount, is_collateral_only);
    }

    fun update_on_withdraw<C,P>(
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool
    ) acquires Position, AccountPositionEventHandle {
        let key = key<C>();
        update_position_for_withdraw<P>(key, depositor_addr, amount, is_collateral_only);
    }

    fun update_on_borrow<C,P>(
        depositor_addr: address,
        amount: u64
    ) acquires Position, AccountPositionEventHandle {
        let key = key<C>();
        update_position_for_borrow<P>(key, depositor_addr, amount);
    }

    fun update_on_repay<C,P>(
        depositor_addr: address,
        amount: u64
    ) acquires Position, AccountPositionEventHandle {
        let key = key<C>();
        update_position_for_repay<P>(key, depositor_addr, amount);
    }

    fun update_position_for_deposit<P>(key: String, addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
            balance_ref.deposited = balance_ref.deposited + amount;
            if (is_collateral_only) {
                balance_ref.conly_deposited = balance_ref.conly_deposited + amount;
            };
            emit_update_position_event<P>(addr, key, balance_ref);
        } else {
            new_position<P>(addr, amount, 0, is_collateral_only, key);
        };
    }

    fun update_position_for_withdraw<P>(key: String, addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
        assert!(balance_ref.deposited >= amount, error::invalid_argument(EOVER_DEPOSITED_AMOUNT));
        balance_ref.deposited = balance_ref.deposited - amount;
        if (is_collateral_only) {
            balance_ref.conly_deposited = balance_ref.conly_deposited - amount;
        };
        emit_update_position_event<P>(addr, key, balance_ref);
        remove_balance_if_unused<P>(addr, key);
    }

    fun update_position_for_borrow<P>(key: String, addr: address, amount: u64) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
            balance_ref.borrowed = balance_ref.borrowed + amount;
            emit_update_position_event<P>(addr, key, balance_ref);
        } else {
            new_position<P>(addr, 0, amount, false, key);
        };
    }

    fun update_position_for_repay<P>(key: String, addr: address, amount: u64) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
        assert!(balance_ref.borrowed >= amount, error::invalid_argument(EOVER_BORROWED_AMOUNT));
        balance_ref.borrowed = balance_ref.borrowed - amount;
        emit_update_position_event<P>(addr, key, balance_ref);
        remove_balance_if_unused<P>(addr, key);
    }

    fun emit_update_position_event<P>(addr: address, key: String, balance_ref: &Balance) acquires AccountPositionEventHandle {
        event::emit_event<UpdatePositionEvent>(
            &mut borrow_global_mut<AccountPositionEventHandle<P>>(addr).update_position_event,
            UpdatePositionEvent {
                key,
                deposited: balance_ref.deposited,
                conly_deposited: balance_ref.conly_deposited,
                borrowed: balance_ref.borrowed,
            },
        );
    }

    fun new_position<P>(addr: address, deposit: u64, borrow: u64, is_collateral_only: bool, key: String) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        vector::push_back<String>(&mut position_ref.coins, key);

        let conly_amount = if (is_collateral_only) deposit else 0;
        simple_map::add<String,Balance>(&mut position_ref.balance, key, Balance {
            deposited: deposit,
            conly_deposited: conly_amount,
            borrowed: borrow,
        });
        emit_update_position_event<P>(addr, key, simple_map::borrow<String,Balance>(&position_ref.balance, &key));
    }

    fun remove_balance_if_unused<P>(addr: address, key: String) acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        let balance_ref = simple_map::borrow<String,Balance>(&position_ref.balance, &key);
        if (
            balance_ref.deposited == 0
            && balance_ref.conly_deposited == 0
            && balance_ref.borrowed == 0 // NOTE: maybe actually only `deposited` needs to be checked.
        ) {
            simple_map::remove<String, Balance>(&mut position_ref.balance, &key);
            let (_, i) = vector::index_of<String>(&position_ref.coins, &key);
            vector::remove<String>(&mut position_ref.coins, i);
        }
    }

    fun is_safe<C,P>(addr: address): bool acquires Position {
        let key = key<C>();
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
            let deposited = simple_map::borrow<String,Balance>(&position_ref.balance, &key).deposited;
            let borrowed = simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed;
            if (deposited == 0 && borrowed != 0) {
                return constant::u64_max()
            } else if (deposited == 0) { 
                return 0 
            };
            price_oracle::volume(&key, borrowed) * risk_factor::precision() / price_oracle::volume(&key, deposited)
        } else {
            0
        }
    }

    // #[test_only]
    // use aptos_framework::debug;
    #[test_only]
    use leizd_aptos_common::pool_type::{Asset,Shadow};
    #[test_only]
    use leizd::test_coin::{WETH,UNI,USDC};
    #[test_only]
    use leizd::test_initializer;

    // for deposit
    #[test_only]
    fun setup_for_test_to_initialize_coins(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        risk_factor::initialize(owner);
        risk_factor::new_asset_for_test<WETH>(owner);
        risk_factor::new_asset_for_test<UNI>(owner);
        risk_factor::new_asset_for_test<USDC>(owner);
    }
    #[test_only]
    fun borrow_unsafe_for_test<C,P>(borrower_addr: address, amount: u64) acquires Position, AccountPositionEventHandle {
        if (pool_type::is_type_asset<P>()) {
            update_on_borrow<C,ShadowToAsset>(borrower_addr, amount);
        } else {
            update_on_borrow<C,AssetToShadow>(borrower_addr, amount);
        };
    }
    #[test_only]
    public fun initialize_if_necessary_for_test(account: &signer) {
        initialize_if_necessary(account);
    }

    #[test(account=@0x111)]
    public fun test_protect_coin_and_unprotect_coin(account: &signer) acquires Position, AccountPositionEventHandle {
        let key = key<WETH>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initialize_if_necessary(account);
        new_position<ShadowToAsset>(account_addr, 0, 0, false, key);
        assert!(!is_protected<WETH>(account_addr), 0);

        enable_to_rebalance<WETH>(account);
        assert!(is_protected<WETH>(account_addr), 0);

        unable_to_rebalance<WETH>(account);
        assert!(!is_protected<WETH>(account_addr), 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_weth(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 800000, false);
        assert!(deposited_asset<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 1, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222)]
    public entry fun test_deposit_weth_by_two(owner: &signer, account1: &signer, account2: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 800000, false);
        deposit_internal<WETH,Asset>(account2, account2_addr, 200000, false);
        assert!(deposited_asset<WETH>(account1_addr) == 800000, 0);
        assert!(deposited_asset<WETH>(account2_addr) == 200000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_weth_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 800000, true);
        assert!(deposited_asset<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 800000, false);
        assert!(deposited_shadow<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_shadow_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 800000, true);
        assert!(deposited_shadow<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_with_all_patterns(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 1, false);
        deposit_internal<UNI,Asset>(account, account_addr, 2, true);
        deposit_internal<WETH,Shadow>(account, account_addr, 10, false);
        deposit_internal<UNI,Shadow>(account, account_addr, 20, true);
        assert!(deposited_asset<WETH>(account_addr) == 1, 0);
        assert!(conly_deposited_asset<UNI>(account_addr) == 2, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 10, 0);
        assert!(conly_deposited_shadow<UNI>(account_addr) == 20, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 2, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 2, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65544)]
    fun test_deposit_asset_by_collateral_only_asset_after_depositing_normal(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 1, false);
        deposit_internal<WETH,Asset>(account, account_addr, 1, true);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65545)]
    fun test_deposit_asset_by_normal_after_depositing_collateral_only(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 1, true);
        deposit_internal<WETH,Asset>(account, account_addr, 1, false);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65544)]
    fun test_deposit_shadow_by_collateral_only_asset_after_depositing_normal(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 1, false);
        deposit_internal<WETH,Shadow>(account, account_addr, 1, true);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65545)]
    fun test_deposit_shadow_by_normal_after_depositing_collateral_only(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 1, true);
        deposit_internal<WETH,Shadow>(account, account_addr, 1, false);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_weth(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 700000, false);
        withdraw_internal<WETH,Asset>(account_addr, 600000, false);
        assert!(deposited_asset<WETH>(account_addr) == 100000, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 2, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_with_same_as_deposited_amount(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 30, false);
        withdraw_internal<WETH,Asset>(account_addr, 30, false);
        assert!(deposited_asset<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 30, false);
        withdraw_internal<WETH,Asset>(account_addr, 31, false);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 700000, true);
        withdraw_internal<WETH,Asset>(account_addr, 600000, true);

        assert!(deposited_asset<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 700000, false);
        withdraw_internal<WETH,Shadow>(account_addr, 600000, false);

        assert!(deposited_shadow<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_shadow_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 700000, true);
        withdraw_internal<WETH,Shadow>(account_addr, 600000, true);

        assert!(deposited_shadow<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_with_all_patterns(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 100, false);
        deposit_internal<UNI,Asset>(account, account_addr, 100, true);
        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        deposit_internal<UNI,Shadow>(account, account_addr, 100, true);
        withdraw_internal<WETH,Asset>(account_addr, 1, false);
        withdraw_internal<UNI,Asset>(account_addr, 2, true);
        withdraw_internal<WETH,Shadow>(account_addr, 10, false);
        withdraw_internal<UNI,Shadow>(account_addr, 20, true);
        assert!(deposited_asset<WETH>(account_addr) == 99, 0);
        assert!(conly_deposited_asset<UNI>(account_addr) == 98, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 90, 0);
        assert!(conly_deposited_shadow<UNI>(account_addr) == 80, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 4, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 4, 0);
    }

    // for borrow
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_borrow_unsafe(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 1, false); // for generating Position
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 10);
        assert!(deposited_shadow<WETH>(account_addr) == 1, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 10, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 2, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_borrow_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 100 / 100, 0); // 100%

        // execute
        let deposit_amount = 10000;
        let borrow_amount = 9999;
        deposit_internal<WETH,Shadow>(account, account_addr, deposit_amount, false);
        borrow_internal<WETH,Asset>(account_addr, borrow_amount);
        let weth_key = key<WETH>();
        assert!(deposited_shadow<WETH>(account_addr) == deposit_amount, 0);
        assert!(deposited_volume<ShadowToAsset>(account_addr, weth_key) == deposit_amount, 0);
        assert!(borrowed_asset<WETH>(account_addr) == borrow_amount, 0);
        assert!(borrowed_volume<ShadowToAsset>(account_addr, weth_key) == borrow_amount, 0);
        //// calculate
        let utilization = utilization_of<ShadowToAsset>(borrow_global<Position<ShadowToAsset>>(account_addr), key<WETH>());
        assert!(lt - utilization == (10000 - borrow_amount) * risk_factor::precision() / deposit_amount, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_borrow_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let weth_key = key<WETH>();
        let lt = risk_factor::lt_of(weth_key);
        assert!(lt == risk_factor::precision() * 70 / 100, 0); // 70%

        // execute
        let deposit_amount = 10000;
        let borrow_amount = 6999; // (10000 * 70%) - 1
        deposit_internal<WETH,Asset>(account, account_addr, deposit_amount, false);
        borrow_internal<WETH,Shadow>(account_addr, borrow_amount);
        assert!(deposited_asset<WETH>(account_addr) == deposit_amount, 0);
        assert!(deposited_volume<AssetToShadow>(account_addr, weth_key) == deposit_amount, 0);
        assert!(borrowed_shadow<WETH>(account_addr) == borrow_amount, 0);
        assert!(borrowed_volume<AssetToShadow>(account_addr, weth_key) == borrow_amount, 0);
        //// calculate
        let utilization = utilization_of<AssetToShadow>(borrow_global<Position<AssetToShadow>>(account_addr), weth_key);
        assert!(lt - utilization == (7000 - borrow_amount) * risk_factor::precision() / deposit_amount, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 196610)]
    public entry fun test_borrow_asset_when_over_borrowable(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 100 / 100, 0); // 100%

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account_addr, 10000);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 196610)]
    public entry fun test_borrow_shadow_when_over_borrowable(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let weth_key = key<WETH>();
        let lt = risk_factor::lt_of(weth_key);
        assert!(lt == risk_factor::precision() * 70 / 100, 0); // 70%

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account_addr, 7000);
    }

    // repay
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 1000, false); // for generating Position
        borrow_internal<WETH,Asset>(account_addr, 500);
        repay<WETH,Asset>(account_addr, 250);
        assert!(deposited_shadow<WETH>(account_addr) == 1000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 250, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 3, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 100 / 100, 0); // 100%

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account_addr, 9999);
        repay<WETH,Asset>(account_addr, 9999);
        let weth_key = key<WETH>();
        assert!(deposited_shadow<WETH>(account_addr) == 10000, 0);
        assert!(deposited_volume<ShadowToAsset>(account_addr, weth_key) == 10000, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 0, 0);
        assert!(borrowed_volume<ShadowToAsset>(account_addr, weth_key) == 0, 0);
        //// calculate
        assert!(utilization_of<ShadowToAsset>(borrow_global<Position<ShadowToAsset>>(account_addr), key<WETH>()) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let weth_key = key<WETH>();
        let lt = risk_factor::lt_of(weth_key);
        assert!(lt == risk_factor::precision() * 70 / 100, 0); // 70%

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account_addr, 6999);
        repay<WETH,Shadow>(account_addr, 6999);
        assert!(deposited_asset<WETH>(account_addr) == 10000, 0);
        assert!(deposited_volume<AssetToShadow>(account_addr, weth_key) == 10000, 0);
        assert!(borrowed_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_volume<AssetToShadow>(account_addr, weth_key) == 0, 0);
        //// calculate
        assert!(utilization_of<AssetToShadow>(borrow_global<Position<AssetToShadow>>(account_addr), weth_key) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_repay_asset_when_over_borrowed(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account_addr, 9999);
        repay<WETH,Asset>(account_addr, 10000);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_repay_shadow_when_over_borrowed(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account_addr, 6999);
        repay<WETH,Shadow>(account_addr, 7000);
    }

    // for liquidation
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 100, false);
        borrow_unsafe_for_test<WETH,Shadow>(account_addr, 90);
        assert!(deposited_asset<WETH>(account_addr) == 100, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 0, 0);
        assert!(borrowed_shadow<WETH>(account_addr) == 90, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Asset>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 90, 0);
        assert!(!is_collateral_only, 0);
        assert!(deposited_asset<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 0, 0);
        assert!(borrowed_shadow<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 4, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_asset_conly(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 100, true);
        borrow_unsafe_for_test<WETH,Shadow>(account_addr, 90);
        assert!(deposited_asset<WETH>(account_addr) == 100, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 100, 0);
        assert!(borrowed_shadow<WETH>(account_addr) == 90, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Asset>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 90, 0);
        assert!(is_collateral_only, 0);
        assert!(deposited_asset<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 0, 0);
        assert!(borrowed_shadow<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 4, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 110);
        assert!(deposited_shadow<WETH>(account_addr) == 100, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 110, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 110, 0);
        assert!(!is_collateral_only, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 4, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_shadow_conly(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, true);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 110);
        assert!(deposited_shadow<WETH>(account_addr) == 100, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 100, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 110, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 110, 0);
        assert!(is_collateral_only, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 4, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_two_shadow_position(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, true);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 190);
        deposit_internal<UNI,Shadow>(account, account_addr, 80, false);
        borrow_unsafe_for_test<UNI,Asset>(account_addr, 170);
        assert!(deposited_shadow<WETH>(account_addr) == 100, 0);
        assert!(deposited_shadow<UNI>(account_addr) == 80, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 100, 0);
        assert!(conly_deposited_shadow<UNI>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 190, 0);
        assert!(borrowed_asset<UNI>(account_addr) == 170, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 190, 0);
        assert!(is_collateral_only, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 0, 0);
        let (deposited, borrowed, is_collateral_only) = liquidate_internal<UNI,Shadow>(account_addr);
        assert!(deposited == 80, 0);
        assert!(borrowed == 170, 0);
        assert!(!is_collateral_only, 0);
        assert!(deposited_shadow<UNI>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 8, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_asset_and_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 100, true);
        borrow_unsafe_for_test<WETH,Shadow>(account_addr, 190);
        deposit_internal<WETH,Shadow>(account, account_addr, 80, false);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 170);
        assert!(deposited_asset<WETH>(account_addr) == 100, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 80, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 100, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_shadow<WETH>(account_addr) == 190, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 170, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Asset>(account_addr);
        assert!(deposited == 100, 0);
        assert!(borrowed == 190, 0);
        assert!(is_collateral_only, 0);
        assert!(deposited_asset<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 0, 0);
        assert!(borrowed_shadow<WETH>(account_addr) == 0, 0);
        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
        assert!(deposited == 80, 0);
        assert!(borrowed == 170, 0);
        assert!(!is_collateral_only, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 0, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 4, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 4, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_shadow_if_rebalance_should_be_done(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 190);
        deposit_internal<UNI,Shadow>(account, account_addr, 100, false);
        assert!(deposited_shadow<WETH>(account_addr) == 100, 0);
        assert!(deposited_shadow<UNI>(account_addr) == 100, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow<UNI>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 190, 0);
        assert!(borrowed_asset<UNI>(account_addr) == 0, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
        assert!(deposited == 0, 0);
        assert!(borrowed == 0, 0);
        assert!(!is_collateral_only, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 190, 0);
        assert!(deposited_shadow<UNI>(account_addr) == 10, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow<UNI>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 190, 0);
        assert!(borrowed_asset<UNI>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 196610)]
    public entry fun test_liquidate_asset_if_safe(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 1, true);
        liquidate_internal<WETH,Asset>(account_addr);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 196610)]
    public entry fun test_liquidate_shadow_if_safe(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 1, true);
        liquidate_internal<WETH,Shadow>(account_addr);
    }

    // mixture
    //// check existence of resources
    ////// withdraw all -> re-deposit (borrowable / asset)
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_check_existence_of_position_when_withdraw_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let coin_key = key<WETH>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10001, false);
        withdraw_internal<WETH,Asset>(account_addr, 10000, false);
        let pos_ref1 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(vector::contains<String>(&pos_ref1.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos_ref1.balance, &coin_key), 0);

        withdraw_internal<WETH,Asset>(account_addr, 1, false);
        let pos_ref2 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(!vector::contains<String>(&pos_ref2.coins, &coin_key), 0);
        assert!(!simple_map::contains_key<String,Balance>(&pos_ref2.balance, &coin_key), 0);

        deposit_internal<WETH,Asset>(account, account_addr, 1, false);
        let pos_ref3 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(vector::contains<String>(&pos_ref3.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos_ref3.balance, &coin_key), 0);
    }
    ////// withdraw all -> re-deposit (collateral only / shadow)
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_check_existence_of_position_when_withdraw_shadow_collateral_only(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let coin_key = key<UNI>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<UNI,Shadow>(account, account_addr, 10001, true);
        withdraw_internal<UNI,Shadow>(account_addr, 10000, true);
        let pos1_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(vector::contains<String>(&pos1_ref.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos1_ref.balance, &coin_key), 0);

        withdraw_internal<UNI,Shadow>(account_addr, 1, true);
        let pos2_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(!vector::contains<String>(&pos2_ref.coins, &coin_key), 0);
        assert!(!simple_map::contains_key<String,Balance>(&pos2_ref.balance, &coin_key), 0);

        deposit_internal<UNI,Shadow>(account, account_addr, 1, true);
        let pos3_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(vector::contains<String>(&pos3_ref.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos3_ref.balance, &coin_key), 0);
    }
    ////// repay all -> re-deposit (borrowable / asset)
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_check_existence_of_position_when_repay_asset(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let coin_key = key<UNI>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // prepares (temp)
        initialize_if_necessary(account);
        new_position<AssetToShadow>(account_addr, 0, 0, false, coin_key);

        // execute
        borrow_unsafe_for_test<UNI, Shadow>(account_addr, 10001);
        repay<UNI,Shadow>(account_addr, 10000);
        let pos_ref1 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(vector::contains<String>(&pos_ref1.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos_ref1.balance, &coin_key), 0);

        repay<UNI,Shadow>(account_addr, 1);
        let pos_ref2 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(!vector::contains<String>(&pos_ref2.coins, &coin_key), 0);
        assert!(!simple_map::contains_key<String,Balance>(&pos_ref2.balance, &coin_key), 0);

        deposit_internal<UNI,Asset>(account, account_addr, 1, false);
        let pos_ref3 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(vector::contains<String>(&pos_ref3.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos_ref3.balance, &coin_key), 0);
    }
    ////// repay all -> re-deposit (collateral only / shadow)
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_check_existence_of_position_when_repay_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let coin_key = key<WETH>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // prepares (temp)
        initialize_if_necessary(account);
        new_position<ShadowToAsset>(account_addr, 0, 0, false, coin_key);

        // execute
        borrow_unsafe_for_test<WETH, Asset>(account_addr, 10001);
        repay<WETH,Asset>(account_addr, 10000);
        let pos1_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(vector::contains<String>(&pos1_ref.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos1_ref.balance, &coin_key), 0);

        repay<WETH,Asset>(account_addr, 1);
        let pos2_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(!vector::contains<String>(&pos2_ref.coins, &coin_key), 0);
        assert!(!simple_map::contains_key<String,Balance>(&pos2_ref.balance, &coin_key), 0);

        deposit_internal<WETH,Shadow>(account, account_addr, 1, true);
        let pos3_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(vector::contains<String>(&pos3_ref.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos3_ref.balance, &coin_key), 0);
    }
    //// multiple executions
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_and_withdraw_more_than_once_sequentially(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        withdraw_internal<WETH,Asset>(account_addr, 10000, false);
        deposit_internal<WETH,Asset>(account, account_addr, 2000, false);
        deposit_internal<WETH,Asset>(account, account_addr, 3000, false);
        withdraw_internal<WETH,Asset>(account_addr, 1000, false);
        withdraw_internal<WETH,Asset>(account_addr, 4000, false);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account_addr).update_position_event) == 6, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_borrow_and_repay_more_than_once_sequentially(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account_addr, 5000);
        repay<WETH,Asset>(account_addr, 5000);
        borrow_internal<WETH,Asset>(account_addr, 2000);
        borrow_internal<WETH,Asset>(account_addr, 3000);
        repay<WETH,Asset>(account_addr, 1000);
        repay<WETH,Asset>(account_addr, 4000);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account_addr).update_position_event) == 7, 0);
    }

    // rebalance shadow
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_rebalance_shadow(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Shadow>(account1, account1_addr, 100000, false);
        borrow_internal<WETH,Asset>(account1_addr, 50000);
        deposit_internal<UNI,Shadow>(account1, account1_addr, 100000, false);
        borrow_internal<UNI,Asset>(account1_addr, 90000);
        borrow_unsafe_for_test<UNI,Asset>(account1_addr, 20000);
        assert!(deposited_shadow<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 100000, 0);
        assert!(borrowed_asset<WETH>(account1_addr) == 50000, 0);
        assert!(borrowed_asset<UNI>(account1_addr) == 110000, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 5, 0);

        // execute rebalance
        let (insufficient, is_collateral_only_C1, is_collateral_only_C2) = rebalance_shadow_internal(account1_addr, key<WETH>(), key<UNI>());
        assert!(insufficient == 10000, 0);
        assert!(is_collateral_only_C1 == false, 0);
        assert!(is_collateral_only_C2 == false, 0);
        assert!(deposited_shadow<WETH>(account1_addr) == 90000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 110000, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 7, 0);

        // not execute rebalance
        rebalance_shadow_internal(account1_addr, key<WETH>(), key<UNI>()); // TODO: check - should be revert (?) when not necessary to rebalance
    }
    #[test(owner=@leizd, account1=@0x111, account2=@0x222)]
    public entry fun test_rebalance_shadow_with_patterns_collateral_only_or_borrowable(owner: &signer, account1: &signer, account2: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        // collateral only & borrowable
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        deposit_internal<WETH, Shadow>(account1, account1_addr, 1000, true);
        deposit_internal<UNI, Shadow>(account1, account1_addr, 1000, false);
        borrow_unsafe_for_test<UNI, Asset>(account1_addr, 1200);
        let (insufficient, is_collateral_only_C1, is_collateral_only_C2) = rebalance_shadow<WETH, UNI>(account1_addr);
        assert!(insufficient == 200, 0);
        assert!(is_collateral_only_C1, 0);
        assert!(!is_collateral_only_C2, 0);
        assert!(deposited_shadow<WETH>(account1_addr) == 800, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 1200, 0);

        // borrowable & borrowable
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account2_addr);
        deposit_internal<WETH, Shadow>(account2, account2_addr, 2000, false);
        borrow<WETH, Asset>(account2_addr, 1800);
        deposit_internal<UNI, Shadow>(account2, account2_addr, 1000, false);
        borrow_unsafe_for_test<UNI, Asset>(account2_addr, 1200);
        let (insufficient, is_collateral_only_C1, is_collateral_only_C2) = rebalance_shadow<WETH, UNI>(account2_addr);
        assert!(insufficient == 200, 0);
        assert!(!is_collateral_only_C1, 0);
        assert!(!is_collateral_only_C2, 0);
        assert!(deposited_shadow<WETH>(account2_addr) == 1800, 0);
        assert!(deposited_shadow<UNI>(account2_addr) == 1200, 0);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65546)]
    fun test_rebalance_shadow_with_no_need_to_rebalance(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH, Shadow>(account, account_addr, 1, false);
        deposit_internal<UNI, Shadow>(account, account_addr, 1, false);
        rebalance_shadow<WETH, UNI>(account_addr);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 3)]
    fun test_rebalance_shadow_if_no_position_of_key1_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<UNI,Shadow>(account, account_addr, 100, false);
        rebalance_shadow<WETH, UNI>(account_addr);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 3)]
    fun test_rebalance_shadow_if_no_position_of_key2_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        rebalance_shadow<WETH, UNI>(account_addr);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 4)]
    fun test_rebalance_shadow_if_protect_key1_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        deposit_internal<UNI,Shadow>(account, account_addr, 100, false);
        enable_to_rebalance<WETH>(account);
        rebalance_shadow<WETH, UNI>(account_addr);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 4)]
    fun test_rebalance_shadow_if_protect_key2_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        deposit_internal<UNI,Shadow>(account, account_addr, 100, false);
        enable_to_rebalance<UNI>(account);
        rebalance_shadow<WETH, UNI>(account_addr);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_and_rebalance(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
        borrow_internal<WETH,Shadow>(account1_addr, 50000);
        deposit_internal<UNI,Shadow>(account1, account1_addr, 100000, false);
        borrow_internal<UNI,Asset>(account1_addr, 90000);
        borrow_unsafe_for_test<UNI,Asset>(account1_addr, 20000);
        assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 50000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 100000, 0);
        assert!(borrowed_asset<UNI>(account1_addr) == 110000, 0);

        borrow_and_rebalance_internal(account1_addr, key<WETH>(), key<UNI>(), false);
        assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 60000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 110000, 0);

        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account1_addr).update_position_event) == 3, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 4, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_and_rebalance_2(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 10000, false);
        deposit_internal<UNI,Shadow>(account1, account1_addr, 10000, false);
        borrow_unsafe_for_test<UNI,Asset>(account1_addr, 15000);
        assert!(deposited_asset<WETH>(account1_addr) == 10000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 0, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 10000, 0);
        assert!(borrowed_asset<UNI>(account1_addr) == 15000, 0);

        borrow_and_rebalance_internal(account1_addr, key<WETH>(), key<UNI>(), false);
        assert!(deposited_asset<WETH>(account1_addr) == 10000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 5000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 15000, 0);
        assert!(borrowed_asset<UNI>(account1_addr) == 15000, 0);

    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 3)]
    fun test_borrow_and_rebalance_if_no_position_of_key1_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 2000, false);
        borrow_internal<WETH,Shadow>(account_addr, 1000);
        borrow_and_rebalance<WETH, UNI>(account_addr, false);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 3)]
    fun test_borrow_and_rebalance_if_no_position_of_key2_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<UNI,Shadow>(account, account_addr, 1000, false);
        borrow_unsafe_for_test<UNI,Asset>(account_addr, 1500);
        borrow_and_rebalance<WETH, UNI>(account_addr, false);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 4)]
    fun test_borrow_and_rebalance_if_protect_key1_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 2000, false);
        borrow_internal<WETH,Shadow>(account_addr, 1000);
        deposit_internal<UNI,Shadow>(account, account_addr, 1000, false);
        borrow_unsafe_for_test<UNI,Asset>(account_addr, 1500);
        enable_to_rebalance<WETH>(account);
        borrow_and_rebalance<WETH, UNI>(account_addr, false);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 4)]
    fun test_borrow_and_rebalance_if_protect_key2_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 2000, false);
        borrow_internal<WETH,Shadow>(account_addr, 1000);
        deposit_internal<UNI,Shadow>(account, account_addr, 1000, false);
        borrow_unsafe_for_test<UNI,Asset>(account_addr, 1500);
        enable_to_rebalance<UNI>(account);
        borrow_and_rebalance<WETH, UNI>(account_addr, false);
    }
    //// utils for rebalance
    ////// can_rebalance_shadow_between
    #[test(owner = @leizd, account = @0x111)]
    fun test_can_rebalance_shadow_between(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH, Shadow>(account, account_addr, 1000, false);
        deposit_internal<UNI, Shadow>(account, account_addr, 1000, false);
        borrow_unsafe_for_test<UNI, Asset>(account_addr, 1200);
        let (can_rebalance, extra, insufficient) = can_rebalance_shadow_between(account_addr, key<WETH>(), key<UNI>());
        assert!(can_rebalance, 0);
        assert!(extra == 1000, 0);
        assert!(insufficient == 200, 0);
    }
    #[test(owner = @leizd, account = @0x111)]
    fun test_can_rebalance_shadow_between_with_insufficient_extra(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH, Shadow>(account, account_addr, 1000, false);
        deposit_internal<UNI, Shadow>(account, account_addr, 1000, false);
        borrow_unsafe_for_test<UNI, Asset>(account_addr, 2500);
        let (can_rebalance, extra, insufficient) = can_rebalance_shadow_between(account_addr, key<WETH>(), key<UNI>());
        assert!(!can_rebalance, 0);
        assert!(extra == 1000, 0);
        assert!(insufficient == 1500, 0);
    }
    #[test(owner = @leizd, account = @0x111)]
    fun test_can_rebalance_shadow_between_with_no_extra(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH, Shadow>(account, account_addr, 1000, false);
        borrow_unsafe_for_test<WETH, Asset>(account_addr, 1001);
        deposit_internal<UNI, Shadow>(account, account_addr, 1, false);
        let (can_rebalance, extra, insufficient) = can_rebalance_shadow_between(account_addr, key<WETH>(), key<UNI>());
        assert!(!can_rebalance, 0);
        assert!(extra == 0, 0);
        assert!(insufficient == 0, 0);
    }
    #[test(owner = @leizd, account = @0x111)]
    fun test_can_rebalance_shadow_between_with_no_insufficient(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH, Shadow>(account, account_addr, 1000, false);
        deposit_internal<UNI, Shadow>(account, account_addr, 1, false);
        let (can_rebalance, extra, insufficient) = can_rebalance_shadow_between(account_addr, key<WETH>(), key<UNI>());
        assert!(!can_rebalance, 0);
        assert!(extra == 0, 0);
        assert!(insufficient == 0, 0);
    }
    #[test(account = @0x111)]
    fun test_can_rebalance_shadow_between_with_same_coins(account: &signer) acquires Position {
        let key = key<WETH>();
        let (can_rebalance, extra, insufficient) = can_rebalance_shadow_between(signer::address_of(account), key, key);
        assert!(!can_rebalance, 0);
        assert!(extra == 0, 0);
        assert!(insufficient == 0, 0);
    }

    // borrow asset with rebalance
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false); // 100,000*70%=70,000
        borrow_asset_with_rebalance<UNI>(account1_addr, 10000);
        assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 20000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 20000, 0);
        assert!(borrowed_asset<UNI>(account1_addr) == 10000, 0);

        // assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 7, 0);
    }

    // borrow asset with rebalance
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalancing_several_positions(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
        deposit_internal<USDC,Asset>(account1, account1_addr, 100000, false);
        borrow_asset_with_rebalance<UNI>(account1_addr, 10000);
        assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_asset<USDC>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 10000, 0);
        assert!(borrowed_shadow<USDC>(account1_addr) == 10000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 20000, 0);
        assert!(borrowed_asset<UNI>(account1_addr) == 10000, 0);

        // assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 7, 0);
    }

    // repay shadow with rebalance
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_shadow_with_rebalance(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // 2 positions
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account_addr, 6999);
        deposit_internal<UNI,Asset>(account, account_addr, 10000, false);
        borrow_internal<UNI,Shadow>(account_addr, 6999);
        assert!(borrowed_shadow<WETH>(account_addr) == 6999, 0);
        assert!(borrowed_shadow<UNI>(account_addr) == 6999, 0);

        // execute
        repay_shadow_with_rebalance(account_addr, 10000);
        assert!(borrowed_shadow<WETH>(account_addr) == 1999, 0);
        assert!(borrowed_shadow<UNI>(account_addr) == 1999, 0);
    }

    // switch collateral
    #[test(account1=@0x111)]
    public entry fun test_switch_collateral_with_asset(account1: &signer) acquires Position, AccountPositionEventHandle {
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        deposit_internal<WETH,Asset>(account1, account1_addr, 10000, false);
        assert!(deposited_asset<WETH>(account1_addr) == 10000, 0);
        assert!(conly_deposited_asset<WETH>(account1_addr) == 0, 0);

        let deposited = switch_collateral<WETH,Asset>(account1_addr, true);
        assert!(deposited == 10000, 0);
        assert!(deposited_asset<WETH>(account1_addr) == 10000, 0);
        assert!(conly_deposited_asset<WETH>(account1_addr) == 10000, 0);

        deposit_internal<WETH,Asset>(account1, account1_addr, 30000, true);
        let deposited = switch_collateral<WETH,Asset>(account1_addr, false);
        assert!(deposited == 40000, 0);
        assert!(deposited_asset<WETH>(account1_addr) == 40000, 0);
        assert!(conly_deposited_asset<WETH>(account1_addr) == 0, 0);
    }
    #[test(account1=@0x111)]
    public entry fun test_switch_collateral_with_shadow(account1: &signer) acquires Position, AccountPositionEventHandle {
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        deposit_internal<WETH,Shadow>(account1, account1_addr, 10000, true);
        assert!(deposited_shadow<WETH>(account1_addr) == 10000, 0);
        assert!(conly_deposited_shadow<WETH>(account1_addr) == 10000, 0);

        let deposited = switch_collateral<WETH,Shadow>(account1_addr, false);
        assert!(deposited == 10000, 0);
        assert!(deposited_shadow<WETH>(account1_addr) == 10000, 0);
        assert!(conly_deposited_shadow<WETH>(account1_addr) == 0, 0);

        deposit_internal<WETH,Shadow>(account1, account1_addr, 30000, false);
        let deposited = switch_collateral<WETH,Shadow>(account1_addr, true);
        assert!(deposited == 40000, 0);
        assert!(deposited_shadow<WETH>(account1_addr) == 40000, 0);
        assert!(conly_deposited_shadow<WETH>(account1_addr) == 40000, 0);
    }
}
