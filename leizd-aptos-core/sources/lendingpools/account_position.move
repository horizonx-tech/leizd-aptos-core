module leizd::account_position {

    use std::error;
    use std::signer;
    use std::vector;
    use std::option::{Self,Option};
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::comparator;
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

    struct Balance has store, drop {
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

    struct AccountPositionEventHandle<phantom P> has key, store {
        update_position_event: event::EventHandle<UpdatePositionEvent>,
    }

    public entry fun initialize(owner: &signer): OperatorKey {
        let owner_addr = signer::address_of(owner);
        permission::assert_owner(owner_addr);
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
        amount: u64,
        is_collateral_only: bool,
        _key: &OperatorKey
    ) acquires Position, AccountPositionEventHandle {
        deposit_internal<C,P>(account, depositor_addr, amount, is_collateral_only);
    }

    fun deposit_internal<C,P>(account: &signer, depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        initialize_position_if_necessary(account);
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
        if (is_collateral_only) {
            let deposited = deposited_asset_share<C>(depositor_addr);
            assert!(deposited == 0, error::invalid_argument(EALREADY_DEPOSITED_AS_NORMAL));
        } else {
            let conly_deposited = conly_deposited_asset_share<C>(depositor_addr);
            assert!(conly_deposited == 0, error::invalid_argument(EALREADY_DEPOSITED_AS_COLLATERAL_ONLY));
        };
    }

    fun assert_invalid_deposit_shadow<C>(depositor_addr: address, is_collateral_only: bool) acquires Position {
        if (is_collateral_only) {
            let deposited = deposited_shadow_share<C>(depositor_addr);
            assert!(deposited == 0, error::invalid_argument(EALREADY_DEPOSITED_AS_NORMAL));
        } else {
            let conly_deposited = conly_deposited_shadow_share<C>(depositor_addr);
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
        amount: u64,
        is_collateral_only: bool,
        _key: &OperatorKey
    ): u64 acquires Position, AccountPositionEventHandle {
        withdraw_internal<C,P>(depositor_addr, amount, is_collateral_only)
    }

    fun withdraw_internal<C,P>(depositor_addr: address, amount: u64, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle {
        let withdrawn_amount;
        if (pool_type::is_type_asset<P>()) {
            withdrawn_amount = update_on_withdraw<C,AssetToShadow>(depositor_addr, amount, is_collateral_only);
            assert!(is_safe<C,AssetToShadow>(depositor_addr), error::invalid_state(ENO_SAFE_POSITION));
        } else {
            withdrawn_amount = update_on_withdraw<C,ShadowToAsset>(depositor_addr, amount, is_collateral_only);
            assert!(is_safe<C,ShadowToAsset>(depositor_addr), error::invalid_state(ENO_SAFE_POSITION));
        };
        withdrawn_amount
    }


    ////////////////////////////////////////////////////
    /// Borrow
    ////////////////////////////////////////////////////
    public fun borrow<C,P>(
        account: &signer,
        borrower_addr: address,
        amount: u64,
        _key: &OperatorKey
    ) acquires Position, AccountPositionEventHandle {
        borrow_internal<C,P>(account, borrower_addr, amount);
    }

    fun borrow_internal<C,P>(
        account: &signer,
        borrower_addr: address,
        amount: u64,
    ) acquires Position, AccountPositionEventHandle {
        initialize_position_if_necessary(account);
        assert!(exists<Position<AssetToShadow>>(borrower_addr), error::invalid_argument(ENO_POSITION_RESOURCE));

        if (pool_type::is_type_asset<P>()) {
            update_on_borrow<C,ShadowToAsset>(borrower_addr, amount);
            assert!(is_safe<C,ShadowToAsset>(borrower_addr), error::invalid_state(ENO_SAFE_POSITION));
        } else {
            update_on_borrow<C,AssetToShadow>(borrower_addr, amount);
            assert!(is_safe<C,AssetToShadow>(borrower_addr), error::invalid_state(ENO_SAFE_POSITION));
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
    ) acquires Position, AccountPositionEventHandle {
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
    ) acquires Position, AccountPositionEventHandle {
        let result_amount_deposited = vector::empty<Rebalance>();
        let result_amount_withdrawed = vector::empty<Rebalance>();
        let result_amount_borrowed = vector::empty<Rebalance>();
        let result_amount_repaid = vector::empty<Rebalance>();
        
        update_on_borrow<C,ShadowToAsset>(addr, amount);
        if (is_safe<C,ShadowToAsset>(addr)) {
            return (result_amount_deposited, result_amount_withdrawed, result_amount_borrowed, result_amount_repaid)
        };

        // try to rebalance between pools
        let required_shadow = required_shadow(key<C>(), borrowed_asset_share<C>(addr), deposited_shadow_share<C>(addr));
        (result_amount_deposited, result_amount_withdrawed) = optimize_shadow__deposit_and_withdraw(addr, result_amount_deposited);
        if (vector::length<Rebalance>(&result_amount_deposited) != 0 
            || vector::length<Rebalance>(&result_amount_withdrawed) != 0) {
            return (result_amount_deposited, result_amount_withdrawed, result_amount_borrowed, result_amount_repaid)
        };

        // try to borrow and rebalance shadow
        (result_amount_borrowed, result_amount_deposited) = borrow_and_deposit_if_has_capacity(addr, required_shadow);
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
    fun optimize_shadow__deposit_and_withdraw(addr: address, result_amount_deposited: vector<Rebalance>): (vector<Rebalance>, vector<Rebalance>) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        let coins = position_ref.coins;
        let protected_coins = position_ref.protected_coins;
        let result_amount_withdrawed = vector::empty<Rebalance>();

        let (sum_extra_shadow, sum_insufficient_shadow, sum_deposited, sum_borrowed) = sum_extra_and_insufficient_shadow(&coins, &protected_coins, addr);
        if (sum_extra_shadow >= sum_insufficient_shadow) {
            // reallocation
            let i = vector::length<String>(&coins);
            let opt_hf = health_factor(sum_deposited, sum_borrowed);
            while (i > 0) {
                let key = *vector::borrow<String>(&coins, i-1);
                if (is_protected_internal(&protected_coins, key)) {
                    i = i - 1;
                    continue
                };
                let (_, _,deposited,borrowed) = extra_and_insufficient_shadow(key, addr);
                let hf = health_factor(deposited, borrowed);
                if (hf > opt_hf) {
                    // withdraw
                    let opt_deposit = (borrowed * risk_factor::precision() / (risk_factor::precision() - opt_hf)) * risk_factor::precision() / risk_factor::lt_of_shadow();
                    let diff = deposited - opt_deposit;
                    update_position_for_withdraw<ShadowToAsset>(key, addr, diff, false); // TODO: collateral_only
                    vector::push_back<Rebalance>(&mut result_amount_withdrawed, rebalance::create(key, diff));
                } else if (opt_hf > hf) {
                    // deposit
                    let opt_deposit = (borrowed * risk_factor::precision() / (risk_factor::precision() - opt_hf)) * risk_factor::precision() / risk_factor::lt_of_shadow();
                    let diff = opt_deposit - deposited;
                    update_position_for_deposit<ShadowToAsset>(key, addr, diff, false); // TODO: collateral_only
                    vector::push_back<Rebalance>(&mut result_amount_deposited, rebalance::create(key, diff));
                };
                i = i -1;
            }
        };
        (result_amount_deposited, result_amount_withdrawed)
    }

    /// @returns (result_amount_deposited, result_amount_withdrawed)
    fun optimize_shadow__borrow_and_repay(addr: address, result_amount_borrowed: vector<Rebalance>): (vector<Rebalance>, vector<Rebalance>) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        let coins = position_ref.coins;
        let protected_coins = position_ref.protected_coins;
        let result_amount_repaid = vector::empty<Rebalance>();

        let (sum_capacity_shadow,sum_overdebt_shadow,sum_deposited,sum_borrowed) = sum_capacity_and_overdebt_shadow(&coins, &protected_coins, addr);
        if (sum_capacity_shadow >= sum_overdebt_shadow) {
            // reallocation
            let i = vector::length<String>(&coins);
            let opt_hf = health_factor_of(key<WETH>(), sum_deposited, sum_borrowed); // TODO: 
            while (i > 0) {
                let key = *vector::borrow<String>(&coins, i-1);
                if (is_protected_internal(&protected_coins, key)) {
                    i = i - 1;
                    continue
                };
                let (_, _,deposited,borrowed) = capacity_and_overdebt_shadow(key, addr);
                let hf = health_factor_of(key, deposited, borrowed);
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

    fun health_factor(deposited: u64, borrowed: u64): u64 {
        if (deposited == 0) {
            0
        } else {
            let u = (borrowed * risk_factor::precision() / (deposited * risk_factor::lt_of_shadow() / risk_factor::precision()));
            if (risk_factor::precision() < u) {
                0
            } else {
                risk_factor::precision() - u
            }
        }
    }

    fun health_factor_of(key: String, deposited: u64, borrowed: u64): u64 {
        if (deposited == 0) {
            0
        } else {
            let u = (borrowed * risk_factor::precision() / (deposited * risk_factor::lt_of(key) / risk_factor::precision()));
            if (risk_factor::precision() < u) {
                0
            } else {
                risk_factor::precision() - u
            }
        }
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

    fun sum_capacity_and_overdebt_shadow(coins: &vector<String>, protected_coins: &SimpleMap<String,bool>, addr: address): (u64,u64,u64,u64) acquires Position {
        let i = vector::length<String>(coins);
        let sum_capacity_shadow = 0;
        let sum_overdebt_shadow = 0;
        let sum_deposited = 0;
        let sum_borrowed = 0;
        
        while (i > 0) {
            let key = vector::borrow<String>(coins, i-1);
            if (!is_protected_internal(protected_coins, *key)) {
                let (capacity, overdebt, deposited, borrowed) = capacity_and_overdebt_shadow(*key, addr);
                sum_capacity_shadow = sum_capacity_shadow + capacity;
                sum_overdebt_shadow = sum_overdebt_shadow + overdebt;
                sum_deposited = sum_deposited + deposited;
                sum_borrowed = sum_borrowed + borrowed;
            };
            i = i - 1;
        };
        (sum_capacity_shadow, sum_overdebt_shadow, sum_deposited, sum_borrowed)
    }

    /// @returns (result_amount_borrowed, result_amount_deposited)
    fun borrow_and_deposit_if_has_capacity(addr: address, required_shadow: u64): (vector<Rebalance>, vector<Rebalance>) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        let coins = position_ref.coins;
        let protected_coins = position_ref.protected_coins;
        
        let result_amount_borrowed = vector::empty<Rebalance>();
        let result_amount_deposited = vector::empty<Rebalance>();

        let (sum_capacity_shadow,_,_,_) = sum_capacity_and_overdebt_shadow(&coins, &protected_coins, addr);
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
                        update_position_for_deposit<ShadowToAsset>(key, addr, borrow_amount, false); // TODO: collateral_only
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
    public fun repay<C,P>(addr: address, amount: u64,  _key: &OperatorKey): u64 acquires Position, AccountPositionEventHandle {
        repay_internal<C, P>(addr, amount)
    }
    fun repay_internal<C,P>(addr: address, amount: u64): u64 acquires Position, AccountPositionEventHandle {
        let repaid_amount;
        if (pool_type::is_type_asset<P>()) {
            repaid_amount = update_on_repay<C,ShadowToAsset>(addr, amount);
        } else {
            repaid_amount = update_on_repay<C,AssetToShadow>(addr, amount);
        };
        repaid_amount
    }

    /// @return (repay_keys, repay_amounts)
    public fun repay_shadow_with_rebalance(addr: address, amount: u64, _key: &OperatorKey): (vector<String>, vector<u64>, u64) acquires Position, AccountPositionEventHandle {
        repay_shadow_with_rebalance_internal(addr, amount)
    }
    fun repay_shadow_with_rebalance_internal(addr: address, amount: u64): (vector<String>, vector<u64>, u64) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        let coins = position_ref.coins;

        let (sum_repayable_shadow, repayable_position_count) = sum_repayable_shadow(&coins, addr);        
        if (sum_repayable_shadow <= amount) {
            let (keys, amounts) = repay_all(&coins, addr);
            (keys, amounts, 0)
        } else {
            repay_to_even_out(&coins, addr, amount, repayable_position_count)
        }
    }

    fun sum_repayable_shadow(coins: &vector<String>, addr: address): (u64,u64) acquires Position {
        let i = vector::length<String>(coins);
        let sum_repayable_shadow = 0;
        let repayable_position_count = 0;
        while (i > 0) {
            let key = vector::borrow<String>(coins, i-1);
            let borrowed = borrowed_shadow_share_with(*key, addr);
            if (borrowed > 0) {
                sum_repayable_shadow = sum_repayable_shadow + borrowed_shadow_share_with(*key, addr);
                repayable_position_count = repayable_position_count + 1;
            };
            i = i - 1;
        };
        (sum_repayable_shadow, repayable_position_count)
    }

    fun repay_all(coins: &vector<String>, addr: address): (vector<String>, vector<u64>) acquires Position, AccountPositionEventHandle {
        let repay_keys = vector::empty<String>();
        let repay_amounts = vector::empty<u64>();
        let i = vector::length<String>(coins);
        while (i > 0) {
            let key = vector::borrow<String>(coins, i-1);
            let repayable = borrowed_shadow_share_with(*key, addr);
            update_position_for_repay<AssetToShadow>(*key, addr, repayable);
            vector::push_back<String>(&mut repay_keys, *key);
            vector::push_back<u64>(&mut repay_amounts, repayable);
            i = i - 1;
        };
        (repay_keys, repay_amounts)
    }

    fun repay_to_even_out(
        coins: &vector<String>,
        addr: address,
        amount: u64,
        repayable_position_count: u64,
    ): (vector<String>, vector<u64>, u64) acquires Position, AccountPositionEventHandle {
        let paid_keys = vector::empty<String>();
        let paid_amounts = vector::empty<u64>();

        let i = vector::length<String>(coins);
        let each_payment = amount / (repayable_position_count);
        let unpaid = 0;
        while (i > 0) {
            let key = vector::borrow<String>(coins, i-1);
            let borrowed = borrowed_shadow_share_with(*key, addr);
            if (borrowed >= each_payment) {
                update_position_for_repay<AssetToShadow>(*key, addr, each_payment);
                vector::push_back<String>(&mut paid_keys, *key);
                vector::push_back<u64>(&mut paid_amounts, each_payment);
            } else {
                unpaid = unpaid + each_payment;
            };            
            i = i - 1;
        };
        (paid_keys, paid_amounts, unpaid)
    }

    ////////////////////////////////////////////////////
    /// Liquidate
    ////////////////////////////////////////////////////
    public fun liquidate<C,P>(target_addr: address, _key: &OperatorKey): (u64,u64,bool) acquires Position, AccountPositionEventHandle {
        liquidate_internal<C,P>(target_addr)
    }

    fun liquidate_internal<C,P>(target_addr: address): (u64,u64,bool) acquires Position, AccountPositionEventHandle {
        if (pool_type::is_type_asset<P>()) {
            assert!(!is_safe<C,AssetToShadow>(target_addr), error::invalid_state(ENO_SAFE_POSITION));

            let normal_deposited = deposited_asset_share<C>(target_addr);
            let conly_deposited = conly_deposited_asset_share<C>(target_addr);
            assert!(normal_deposited > 0 || conly_deposited > 0, error::invalid_argument(ENO_DEPOSITED));
            let is_collateral_only = conly_deposited > 0;
            let deposited = if (is_collateral_only) conly_deposited else normal_deposited;

            update_on_withdraw<C, AssetToShadow>(target_addr, deposited, is_collateral_only);
            let borrowed = borrowed_shadow_share<C>(target_addr);
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

            let normal_deposited = deposited_shadow_share<C>(target_addr);
            let conly_deposited = conly_deposited_shadow_share<C>(target_addr);
            assert!(normal_deposited > 0 || conly_deposited > 0, error::invalid_argument(ENO_DEPOSITED));
            let is_collateral_only = conly_deposited > 0;
            let deposited = if (is_collateral_only) conly_deposited else normal_deposited;

            update_on_withdraw<C,ShadowToAsset>(target_addr, deposited, is_collateral_only);
            let borrowed = borrowed_asset_share<C>(target_addr);
            update_on_repay<C,ShadowToAsset>(target_addr, borrowed);
            assert!(is_zero_position<C,ShadowToAsset>(target_addr), error::invalid_state(EPOSITION_EXISTED));
            (deposited, borrowed, is_collateral_only)
        }
    }

    ////////////////////////////////////////////////////
    /// Rebalance
    ////////////////////////////////////////////////////
    public fun rebalance_shadow<C1,C2>(addr: address, _key: &OperatorKey): (u64,bool,bool) acquires Position, AccountPositionEventHandle {
        let key1 = key<C1>();
        let key2 = key<C2>();
        rebalance_shadow_internal(addr, key1, key2)
    }

    fun rebalance_shadow_internal(addr: address, key1: String, key2: String): (u64,bool,bool) acquires Position, AccountPositionEventHandle {
        let is_collateral_only_C1 = conly_deposited_shadow_share_with(key1, addr) > 0;
        let is_collateral_only_C2 = conly_deposited_shadow_share_with(key2, addr) > 0;
        
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        assert!(vector::contains<String>(&position_ref.coins, &key1), error::invalid_argument(ENOT_EXISTED));
        assert!(vector::contains<String>(&position_ref.coins, &key2), error::invalid_argument(ENOT_EXISTED));
        assert!(!is_protected_internal(&position_ref.protected_coins, key1), error::invalid_argument(EALREADY_PROTECTED));
        assert!(!is_protected_internal(&position_ref.protected_coins, key2), error::invalid_argument(EALREADY_PROTECTED));

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

    fun extra_and_insufficient_shadow(key: String, addr: address): (u64,u64,u64,u64) acquires Position {
        let extra = 0;
        let insufficient = 0;
        
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key);
        let deposited = deposited_volume<ShadowToAsset>(addr, key);
        let required_deposit = borrowed * risk_factor::precision() / risk_factor::ltv_of_shadow();
        if (deposited < required_deposit) {
            insufficient = insufficient + (required_deposit - deposited);
        } else {
            extra = extra + (deposited - required_deposit);
        };
        (extra, insufficient, deposited, borrowed)
    }

    fun capacity_and_overdebt_shadow(key: String, addr: address): (u64,u64,u64,u64) acquires Position {
        let capacity = 0;
        let overdebt = 0;
        
        let borrowed = borrowed_volume<AssetToShadow>(addr, key);
        let deposited = deposited_volume<AssetToShadow>(addr, key);
        let borrowable = deposited * risk_factor::ltv_of(key) / risk_factor::precision();
        if (borrowable < borrowed) {
            overdebt = overdebt + (borrowed - borrowable);
        } else {
            capacity = capacity + (borrowable - borrowed);
        };
        (capacity, overdebt, deposited, borrowed)
    }

    fun can_rebalance_shadow_between(addr: address, key1: String, key2: String): (bool,u64,u64) acquires Position {
        // TODO
        if (is_the_same(key1, key2)) {
            return (false, 0, 0)
        };

        // extra in key1
        let (extra,_,_,_) = extra_and_insufficient_shadow(key1, addr);
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

    // Rebalance after borrowing additional shadow

    public fun borrow_and_rebalance<C1,C2>(addr: address, is_collateral_only: bool, _key: &OperatorKey): u64 acquires Position, AccountPositionEventHandle {
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
        let borrowable = deposited * risk_factor::ltv_of(key) / risk_factor::precision();
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
        assert!(vector::contains<String>(&pos_ref_asset_to_shadow.coins, &key1), error::invalid_argument(ENOT_EXISTED));
        assert!(vector::contains<String>(&pos_ref_shadow_to_asset.coins, &key2), error::invalid_argument(ENOT_EXISTED));
        assert!(!is_protected_internal(&pos_ref_shadow_to_asset.protected_coins, key1), error::invalid_argument(EALREADY_PROTECTED)); // NOTE: use only Position<ShadowToAsset> to check protected coin
        assert!(!is_protected_internal(&pos_ref_shadow_to_asset.protected_coins, key2), error::invalid_argument(EALREADY_PROTECTED)); // NOTE: use only Position<ShadowToAsset> to check protected coin

        let (is_possible, _, insufficient) = can_borrow_and_rebalance(addr, key1, key2);
        assert!(is_possible, error::invalid_argument(ECANNOT_REBALANCE));
        update_position_for_borrow<AssetToShadow>(key1, addr, insufficient);
        update_position_for_deposit<ShadowToAsset>(key2, addr, insufficient, is_collateral_only);

        insufficient
    }

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

    public fun unable_to_rebalance<C>(account: &signer) acquires Position {
        unable_to_rebalance_internal<C>(account);
    }
    fun unable_to_rebalance_internal<C>(account: &signer) acquires Position {
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
        let key = key<C>();
        let position_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        is_protected_internal(&position_ref.protected_coins, key)
    }
    fun is_protected_internal(protected_coins: &SimpleMap<String,bool>, key: String): bool {
        simple_map::contains_key<String,bool>(protected_coins, &key)
    }

    ////////////////////////////////////////////////////
    /// Switch Collateral
    ////////////////////////////////////////////////////
    public fun switch_collateral<C,P>(addr: address, to_collateral_only: bool,  _key: &OperatorKey): u64 acquires Position, AccountPositionEventHandle {
        switch_collateral_internal<C,P>(addr, to_collateral_only)
    }
    fun switch_collateral_internal<C,P>(addr: address, to_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle {
        let deposited;
        if (pool_type::is_type_asset<P>()) {
            if (to_collateral_only) {
                deposited = deposited_asset_share<C>(addr);
                update_on_withdraw<C,AssetToShadow>(addr, deposited, false);
                update_on_deposit<C,AssetToShadow>(addr, deposited, true);
            } else {
                deposited = conly_deposited_asset_share<C>(addr);
                update_on_withdraw<C,AssetToShadow>(addr, deposited, true);
                update_on_deposit<C,AssetToShadow>(addr, deposited, false);
            }
        } else {
            if (to_collateral_only) {
                deposited = deposited_shadow_share<C>(addr);
                update_on_withdraw<C,ShadowToAsset>(addr, deposited, false);
                update_on_deposit<C,ShadowToAsset>(addr, deposited, true);
            } else {
                deposited = conly_deposited_shadow_share<C>(addr);
                update_on_withdraw<C,ShadowToAsset>(addr, deposited, true);
                update_on_deposit<C,ShadowToAsset>(addr, deposited, false);
            }
        };
        deposited
    }

    public fun deposited_volume<P>(addr: address, key: String): u64 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        deposited_volume_internal<P>(position_ref, key)
    }
    fun deposited_volume_internal<P>(position_ref: &Position<P>, key: String): u64 {
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let balance = simple_map::borrow<String,Balance>(&position_ref.balance, &key);
            let (total_amount, total_share) = total_normal_deposited<P>(key);
            let normal_deposited = if (total_amount == 0 && total_share == 0) (balance.normal_deposited_share as u128) else math128::to_amount((balance.normal_deposited_share as u128), total_amount, total_share);
            let (total_amount, total_share) = total_conly_deposited<P>(key);
            let conly_deposited = if (total_amount == 0 && total_share == 0) (balance.conly_deposited_share as u128) else math128::to_amount((balance.conly_deposited_share as u128), total_amount, total_share);
            price_oracle::volume(&key, ((normal_deposited + conly_deposited) as u64)) // TODO: consider cast
        } else {
            0
        }
    }

    public fun borrowed_volume<P>(addr: address, key: String): u64 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        borrowed_volume_internal<P>(position_ref, key)
    }
    fun borrowed_volume_internal<P>(position_ref: &Position<P>, key: String): u64 {
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let (total_amount, total_share) = total_borrowed<P>(key);
            let borrowed_share = simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed_share;
            let borrowed = if (total_amount == 0 && total_share == 0) (borrowed_share as u128) else math128::to_amount((borrowed_share as u128), total_amount, total_share);
            price_oracle::volume(&key, (borrowed as u64)) // TODO: consider cast
        } else {
            0
        }
    }

    //// internal functions to update position
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
    ): u64 acquires Position, AccountPositionEventHandle {
        let key = key<C>();
        update_position_for_withdraw<P>(key, depositor_addr, amount, is_collateral_only)
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
    ): u64 acquires Position, AccountPositionEventHandle {
        let key = key<C>();
        update_position_for_repay<P>(key, depositor_addr, amount)
    }

    fun update_position_for_deposit<P>(key: String, addr: address, share: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
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

    fun update_position_for_withdraw<P>(key: String, addr: address, share: u64, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle {
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

    fun update_position_for_borrow<P>(key: String, addr: address, share: u64) acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
            balance_ref.borrowed_share = balance_ref.borrowed_share + share;
            emit_update_position_event<P>(addr, key, balance_ref);
        } else {
            new_position<P>(addr, 0, share, false, key);
        };
    }

    fun update_position_for_repay<P>(key: String, addr: address, share: u64): u64 acquires Position, AccountPositionEventHandle {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
        share = if (share == constant::u64_max()) balance_ref.borrowed_share else share;
        assert!(balance_ref.borrowed_share >= share, error::invalid_argument(EOVER_BORROWED_AMOUNT));
        balance_ref.borrowed_share = balance_ref.borrowed_share - share;
        emit_update_position_event<P>(addr, key, balance_ref);
        remove_balance_if_unused<P>(addr, key);
        share
    }

    fun emit_update_position_event<P>(addr: address, key: String, balance_ref: &Balance) acquires AccountPositionEventHandle {
        event::emit_event<UpdatePositionEvent>(
            &mut borrow_global_mut<AccountPositionEventHandle<P>>(addr).update_position_event,
            UpdatePositionEvent {
                key,
                normal_deposited: balance_ref.normal_deposited_share,
                conly_deposited: balance_ref.conly_deposited_share,
                borrowed: balance_ref.borrowed_share,
            },
        );
    }

    fun new_position<P>(addr: address, deposit: u64, borrow: u64, is_collateral_only: bool, key: String) acquires Position, AccountPositionEventHandle {
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
    use leizd_aptos_common::test_coin::{WETH,UNI,USDC};
    #[test_only]
    use leizd::test_initializer;

    // for deposit
    #[test_only]
    fun setup_for_test_to_initialize_coins(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        test_initializer::initialize(owner);
        asset_pool::initialize(owner);
        shadow_pool::initialize(owner);
        asset_pool::init_pool_for_test<WETH>(owner);
        asset_pool::init_pool_for_test<UNI>(owner);
        asset_pool::init_pool_for_test<USDC>(owner);
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
    public fun initialize_position_if_necessary_for_test(account: &signer) {
        initialize_position_if_necessary(account);
    }

    #[test(account=@0x111)]
    public fun test_protect_coin_and_unprotect_coin(account: &signer) acquires Position, AccountPositionEventHandle {
        let key = key<WETH>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initialize_position_if_necessary(account);
        new_position<ShadowToAsset>(account_addr, 10, 0, false, key);
        assert!(!is_protected<WETH>(account_addr), 0);

        unable_to_rebalance_internal<WETH>(account);
        assert!(is_protected<WETH>(account_addr), 0);

        enable_to_rebalance_internal<WETH>(account);
        assert!(!is_protected<WETH>(account_addr), 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_weth(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 800000, false);
        assert!(deposited_asset_share<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 0, 0);

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
        assert!(deposited_asset_share<WETH>(account1_addr) == 800000, 0);
        assert!(deposited_asset_share<WETH>(account2_addr) == 200000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_weth_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 800000, true);
        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 800000, false);
        assert!(deposited_shadow_share<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_shadow_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 800000, true);
        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 800000, 0);
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
        assert!(deposited_asset_share<WETH>(account_addr) == 1, 0);
        assert!(conly_deposited_asset_share<UNI>(account_addr) == 2, 0);
        assert!(deposited_shadow_share<WETH>(account_addr) == 10, 0);
        assert!(conly_deposited_shadow_share<UNI>(account_addr) == 20, 0);

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
        assert!(deposited_asset_share<WETH>(account_addr) == 100000, 0);

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
        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
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

        assert!(deposited_asset_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset_share<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 700000, false);
        withdraw_internal<WETH,Shadow>(account_addr, 600000, false);

        assert!(deposited_shadow_share<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_shadow_for_only_collateral(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 700000, true);
        withdraw_internal<WETH,Shadow>(account_addr, 600000, true);

        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_all(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 700000, true);
        withdraw_internal<WETH,Shadow>(account_addr, constant::u64_max(), true);

        assert!(deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
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
        assert!(deposited_asset_share<WETH>(account_addr) == 99, 0);
        assert!(conly_deposited_asset_share<UNI>(account_addr) == 98, 0);
        assert!(deposited_shadow_share<WETH>(account_addr) == 90, 0);
        assert!(conly_deposited_shadow_share<UNI>(account_addr) == 80, 0);

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
        assert!(deposited_shadow_share<WETH>(account_addr) == 1, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 10, 0);

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
        assert!(lt == risk_factor::precision() * 95 / 100, 0); // 95%

        // execute
        let deposit_amount = 10000;
        let borrow_amount = 8999;
        deposit_internal<WETH,Shadow>(account, account_addr, deposit_amount, false);
        borrow_internal<WETH,Asset>(account, account_addr, borrow_amount);
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
    public entry fun test_borrow_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
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
        deposit_internal<WETH,Asset>(account, account_addr, deposit_amount, false);
        borrow_internal<WETH,Shadow>(account, account_addr, borrow_amount);
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
    public entry fun test_borrow_asset_when_over_borrowable(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 95 / 100, 0); // 95%

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account, account_addr, 10000);
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
        assert!(lt == risk_factor::precision() * 85 / 100, 0); // 85%

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account, account_addr, 8500);
    }

    // borrow shadow with rebalance
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__optimize_shadow(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
        deposit_internal<USDC,Shadow>(account1, account1_addr, 100000, false);
        
        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(deposited_shadow_share<USDC>(account1_addr) == 0, 0);
        assert!(deposited_shadow_share<UNI>(account1_addr) == 100000, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__optimize_shadow2(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
        deposit_internal<USDC,Shadow>(account1, account1_addr, 100000, false);
        borrow_internal<USDC,Asset>(account1, account1_addr, 50000);
        
        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(deposited_shadow_share<USDC>(account1_addr) == 83332, 0); // TODO: 83333?
        assert!(deposited_shadow_share<UNI>(account1_addr) == 16666, 0); // TODO: 16667?
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__optimize_shadow3(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
        deposit_internal<WETH,Shadow>(account1, account1_addr, 50000, false);
        deposit_internal<USDC,Shadow>(account1, account1_addr, 100000, false);
        deposit_internal<UNI,Shadow>(account1, account1_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account1, account1_addr, 10000);
        borrow_internal<USDC,Asset>(account1, account1_addr, 50000);
        
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
    public entry fun test_borrow_asset_with_rebalance__optimize_shadow4(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
        deposit_internal<WETH,Shadow>(account1, account1_addr, 50000, false);
        deposit_internal<USDC,Shadow>(account1, account1_addr, 100000, false);
        deposit_internal<UNI,Shadow>(account1, account1_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account1, account1_addr, 10000);
        borrow_internal<USDC,Asset>(account1, account1_addr, 50000);
        unable_to_rebalance_internal<WETH>(account1);
        
        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 50000, 0);
        assert!(deposited_shadow_share<USDC>(account1_addr) == 91666, 0); // TODO: 91667?
        assert!(deposited_shadow_share<UNI>(account1_addr) == 18332, 0); // TODO: 18333?
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 10000, 0);
        assert!(borrowed_asset_share<USDC>(account1_addr) == 50000, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
    }

    // use std::debug;
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__borrow_and_deposit(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);

        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 11111, 0);
        assert!(deposited_shadow_share<UNI>(account1_addr) == 11110, 0); // TODO: 11111?
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_asset_with_rebalance__borrow_and_deposit2(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
        deposit_internal<USDC,Asset>(account1, account1_addr, 50000, false);

        borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_asset_share<USDC>(account1_addr) == 50000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 7407, 0);
        assert!(borrowed_shadow_share<USDC>(account1_addr) == 3703, 0); // TODO: 3704?
        assert!(deposited_shadow_share<UNI>(account1_addr) == 11110, 0); // TODO: 11111?
        assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);        
    }

        // update_on_borrow<UNI,ShadowToAsset>(account1_addr, 10000);
        // assert!(!is_safe<UNI,ShadowToAsset>(account1_addr), 0);
        // let required_shadow = required_shadow(key<UNI>(), borrowed_asset_share<UNI>(account1_addr), deposited_shadow_share<UNI>(account1_addr));
        // assert!(required_shadow == 11111, 0);

        // let position_ref = borrow_global<Position<ShadowToAsset>>(account1_addr);
        // let coins = position_ref.coins;
        // let protected_coins = position_ref.protected_coins;
        // let (_, _, sum_deposited, sum_borrowed) = sum_extra_and_insufficient_shadow(&coins, &protected_coins, account1_addr);
        // let opt_hf = health_factor(sum_deposited, sum_borrowed);
        // debug::print(&opt_hf);
        
        // let key = *vector::borrow<String>(&coins, 1);
        // let (_, _,deposited,borrowed) = extra_and_insufficient_shadow(key, account1_addr);
        // let hf = health_factor(deposited, borrowed);
        // debug::print(&hf);
        // debug::print(&borrowed);
        // let opt_deposit = borrowed * risk_factor::precision() / ((risk_factor::precision() - opt_hf) * risk_factor::lt_of_shadow() / risk_factor::precision());
        // let diff = opt_deposit - deposited;
        // update_position_for_deposit<ShadowToAsset>(key, account1_addr, diff, false); // TODO: collateral_only
        // debug::print(&opt_deposit);
        // debug::print(&deposited_shadow_share<UNI>(account1_addr));
        // // debug::print(&borrowed);
        // // debug::print(&(borrowed * risk_factor::precision() / 111111111));
        
        // let key = *vector::borrow<String>(&coins, 0);
        // let (_, _,deposited,borrowed) = extra_and_insufficient_shadow(key, account1_addr);
        // let hf = health_factor(deposited, borrowed);
        // debug::print(&hf);
        // debug::print(&borrowed);
        // let opt_deposit = borrowed * risk_factor::precision() / ((risk_factor::precision() - opt_hf) * risk_factor::lt_of_shadow() / risk_factor::precision());
        // debug::print(&opt_deposit);
        // debug::print(&deposited);

        // borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
        // debug::print(&borrowed_shadow_share<WETH>(account1_addr));
        // debug::print(&deposited_shadow_share<USDC>(account1_addr));
        // debug::print(&borrowed_shadow_share<WETH>(account1_addr));
        // assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        // assert!(deposited_shadow_share<USDC>(account1_addr) == 0, 0);
        // assert!(borrowed_shadow_share<WETH>(account1_addr) == 0, 0);
        // assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
        // assert!(deposited_shadow_share<UNI>(account1_addr) == 0, 0);

    // #[test(owner=@leizd,account1=@0x111)]
    // public entry fun test_borrow_asset_with_rebalance(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
    //     setup_for_test_to_initialize_coins(owner);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     let account1_addr = signer::address_of(account1);
    //     account::create_account_for_test(account1_addr);

    //     deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
    //     borrow_asset_with_rebalance<UNI>(account1_addr, 10000);
    //     assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
    //     assert!(borrowed_shadow<WETH>(account1_addr) == 20000, 0);
    //     assert!(deposited_shadow<UNI>(account1_addr) == 20000, 0);
    //     assert!(borrowed_asset<UNI>(account1_addr) == 10000, 0);
    // }
    // use std::debug;
    // #[test(owner=@leizd,account1=@0x111)]
    // public entry fun test_borrow_asset_with_rebalance_two(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
    //     setup_for_test_to_initialize_coins(owner);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     let account1_addr = signer::address_of(account1);
    //     account::create_account_for_test(account1_addr);

    //     deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
    //     deposit_internal<USDC,Asset>(account1, account1_addr,  20000, false);
    //     assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
    //     assert!(deposited_asset<USDC>(account1_addr) == 20000, 0);
    //     required_shadow(key<UNI>(), borrowed_asset<UNI>(account1_addr), deposited_shadow<UNI>(account1_addr));

    //     borrow_asset_with_rebalance<UNI>(account1_addr, 10000);
    //     debug::print(&borrowed_shadow<WETH>(account1_addr));
    //     debug::print(&borrowed_shadow<USDC>(account1_addr));
    //     assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
    //     assert!(deposited_asset<WETH>(account1_addr) == 20000, 0);
    //     // TODO
    //     assert!(deposited_shadow<UNI>(account1_addr) == 20000, 0);
    //     assert!(borrowed_asset<UNI>(account1_addr) == 10000, 0);

    //     assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account1_addr).update_position_event) == 3, 0);
    //     assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 4, 0);
    // }

    // #[test(owner=@leizd,account1=@0x111)]
    // public entry fun test_borrow_asset_with_rebalancing_several_positions(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
    //     setup_for_test_to_initialize_coins(owner);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     let account1_addr = signer::address_of(account1);
    //     account::create_account_for_test(account1_addr);

    //     deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
    //     deposit_internal<USDC,Asset>(account1, account1_addr, 100000, false);
    //     borrow_asset_with_rebalance<UNI>(account1_addr, 10000);
    //     assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
    //     assert!(deposited_asset<USDC>(account1_addr) == 100000, 0);
    //     assert!(borrowed_shadow<WETH>(account1_addr) == 10000, 0);
    //     assert!(borrowed_shadow<USDC>(account1_addr) == 10000, 0);
    //     assert!(deposited_shadow<UNI>(account1_addr) == 20000, 0);
    //     assert!(borrowed_asset<UNI>(account1_addr) == 10000, 0);

    //     // assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 7, 0);
    // }

    // repay
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 1000, false); // for generating Position
        borrow_internal<WETH,Asset>(account, account_addr, 500);
        repay_internal<WETH,Asset>(account_addr, 250);
        assert!(deposited_shadow_share<WETH>(account_addr) == 1000, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 250, 0);

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
        assert!(lt == risk_factor::precision() * 95 / 100, 0); // 95%

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account, account_addr, 8999);
        repay_internal<WETH,Asset>(account_addr, 8999);
        let weth_key = key<WETH>();
        assert!(deposited_shadow_share<WETH>(account_addr) == 10000, 0);
        assert!(deposited_volume<ShadowToAsset>(account_addr, weth_key) == 10000, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_volume<ShadowToAsset>(account_addr, weth_key) == 0, 0);
        //// calculate
        assert!(utilization_of<ShadowToAsset>(borrow_global<Position<ShadowToAsset>>(account_addr), key<WETH>()) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_asset_all(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 95 / 100, 0); // 95%

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account, account_addr, 8999);
        repay_internal<WETH,Asset>(account_addr, constant::u64_max());
        let weth_key = key<WETH>();
        assert!(deposited_shadow_share<WETH>(account_addr) == 10000, 0);
        assert!(deposited_volume<ShadowToAsset>(account_addr, weth_key) == 10000, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 0, 0);
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
        assert!(lt == risk_factor::precision() * 85 / 100, 0); // 85%

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account, account_addr, 6999);
        repay_internal<WETH,Shadow>(account_addr, 6999);
        assert!(deposited_asset_share<WETH>(account_addr) == 10000, 0);
        assert!(deposited_volume<AssetToShadow>(account_addr, weth_key) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(borrowed_volume<AssetToShadow>(account_addr, weth_key) == 0, 0);
        //// calculate
        assert!(utilization_of<AssetToShadow>(borrow_global<Position<AssetToShadow>>(account_addr), weth_key) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 196610)]
    public entry fun test_repay_asset_when_over_borrowed(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account, account_addr, 9999);
        repay_internal<WETH,Asset>(account_addr, 10000);
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
        borrow_internal<WETH,Shadow>(account, account_addr, 6999);
        repay_internal<WETH,Shadow>(account_addr, 7000);
    }

    // repay with rebalance
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_shadow_with_rebalance_evenly(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // 2 positions
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account, account_addr, 6999);
        deposit_internal<UNI,Asset>(account, account_addr, 10000, false);
        borrow_internal<UNI,Shadow>(account, account_addr, 6999);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 6999, 0);
        assert!(borrowed_shadow_share<UNI>(account_addr) == 6999, 0);

        // execute
        repay_shadow_with_rebalance_internal(account_addr, 10000);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 1999, 0);
        assert!(borrowed_shadow_share<UNI>(account_addr) == 1999, 0);
    }
    // repay with rebalance
    // #[test(owner=@leizd,account=@0x111)]
    // public entry fun test_repay_shadow_with_rebalance__left_unpaid(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
    //     setup_for_test_to_initialize_coins(owner);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     let account_addr = signer::address_of(account);
    //     account::create_account_for_test(account_addr);

    //     // 3 positions
    //     deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
    //     borrow_internal<WETH,Shadow>(account, account_addr, 6999);
    //     deposit_internal<UNI,Asset>(account, account_addr, 10000, false);
    //     borrow_internal<UNI,Shadow>(account, account_addr, 1999);
    //     deposit_internal<USDC,Asset>(account, account_addr, 10000, false);
    //     borrow_internal<USDC,Shadow>(account, account_addr, 6999);
    //     assert!(borrowed_shadow<WETH>(account_addr) == 6999, 0);
    //     assert!(borrowed_shadow<UNI>(account_addr) == 1999, 0);
    //     assert!(borrowed_shadow<USDC>(account_addr) == 6999, 0);

    //     // execute
    //     let (_,_,unpaid) = repay_shadow_with_rebalance(account_addr, 10000);
    //     assert!(borrowed_shadow<WETH>(account_addr) == 3666, 0); // 6999 - 3333
    //     assert!(borrowed_shadow<UNI>(account_addr) == 1999, 0);
    //     assert!(borrowed_shadow<USDC>(account_addr) == 3666, 0); // 6999 - 3333
    //     assert!(unpaid == 3333, 0);
    // }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_shadow_with_rebalance_all(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account, account_addr, 6999);
        deposit_internal<UNI,Asset>(account, account_addr, 10000, false);
        borrow_internal<UNI,Shadow>(account, account_addr, 6999);

        repay_shadow_with_rebalance_internal(account_addr, 14000);
        assert!(deposited_asset_share<WETH>(account_addr) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(deposited_asset_share<UNI>(account_addr) == 10000, 0);
        assert!(borrowed_shadow_share<UNI>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_repay_shadow_with_rebalance_without_protected_coins(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account, account_addr, 6999);
        deposit_internal<UNI,Shadow>(account, account_addr, 10000, false);
        borrow_internal<UNI,Asset>(account, account_addr, 6999);
        deposit_internal<USDC,Asset>(account, account_addr, 10000, false);
        borrow_internal<USDC,Shadow>(account, account_addr, 6999);
        unable_to_rebalance_internal<UNI>(account);

        repay_shadow_with_rebalance_internal(account_addr, 6000);
        assert!(deposited_asset_share<WETH>(account_addr) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account_addr) == 3999, 0);
        assert!(deposited_shadow_share<UNI>(account_addr) == 10000, 0);
        assert!(borrowed_asset_share<UNI>(account_addr) == 6999, 0);
        assert!(deposited_asset_share<USDC>(account_addr) == 10000, 0);
        assert!(borrowed_shadow_share<USDC>(account_addr) == 3999, 0);
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
    public entry fun test_liquidate_asset_conly(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 100, true);
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
    public entry fun test_liquidate_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
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
    public entry fun test_liquidate_shadow_conly(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, true);
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
    public entry fun test_liquidate_two_shadow_position(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, true);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 190);
        deposit_internal<UNI,Shadow>(account, account_addr, 80, false);
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
    public entry fun test_liquidate_asset_and_shadow(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 100, true);
        borrow_unsafe_for_test<WETH,Shadow>(account_addr, 190);
        deposit_internal<WETH,Shadow>(account, account_addr, 80, false);
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
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_liquidate_shadow_if_rebalance_should_be_done(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 190);
        deposit_internal<UNI,Shadow>(account, account_addr, 100, false);
        assert!(deposited_shadow_share<WETH>(account_addr) == 100, 0);
        assert!(deposited_shadow_share<UNI>(account_addr) == 100, 0);
        assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<UNI>(account_addr) == 0, 0);
        assert!(borrowed_asset_share<WETH>(account_addr) == 190, 0);
        assert!(borrowed_asset_share<UNI>(account_addr) == 0, 0);

        let (deposited, borrowed, is_collateral_only) = liquidate_internal<WETH,Shadow>(account_addr);
        assert!(deposited == 0, 0);
        assert!(borrowed == 0, 0);
        assert!(!is_collateral_only, 0);
        assert!(deposited_shadow_share<WETH>(account_addr) == 200, 0);
        // TODO: logic
        // assert!(deposited_shadow_share<UNI>(account_addr) == 10, 0);
        // assert!(conly_deposited_shadow_share<WETH>(account_addr) == 0, 0);
        // assert!(conly_deposited_shadow_share<UNI>(account_addr) == 0, 0);
        // assert!(borrowed_asset_share<WETH>(account_addr) == 190, 0);
        // assert!(borrowed_asset_share<UNI>(account_addr) == 0, 0);
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
        initialize_position_if_necessary(account);
        new_position<AssetToShadow>(account_addr, 0, 0, false, coin_key);

        // execute
        borrow_unsafe_for_test<UNI, Shadow>(account_addr, 10001);
        repay_internal<UNI,Shadow>(account_addr, 10000);
        let pos_ref1 = borrow_global<Position<AssetToShadow>>(account_addr);
        assert!(vector::contains<String>(&pos_ref1.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos_ref1.balance, &coin_key), 0);

        repay_internal<UNI,Shadow>(account_addr, 1);
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
        initialize_position_if_necessary(account);
        new_position<ShadowToAsset>(account_addr, 0, 0, false, coin_key);

        // execute
        borrow_unsafe_for_test<WETH, Asset>(account_addr, 10001);
        repay_internal<WETH,Asset>(account_addr, 10000);
        let pos1_ref = borrow_global<Position<ShadowToAsset>>(account_addr);
        assert!(vector::contains<String>(&pos1_ref.coins, &coin_key), 0);
        assert!(simple_map::contains_key<String,Balance>(&pos1_ref.balance, &coin_key), 0);

        repay_internal<WETH,Asset>(account_addr, 1);
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
        borrow_internal<WETH,Asset>(account, account_addr, 5000);
        repay_internal<WETH,Asset>(account_addr, 5000);
        borrow_internal<WETH,Asset>(account, account_addr, 2000);
        borrow_internal<WETH,Asset>(account, account_addr, 3000);
        repay_internal<WETH,Asset>(account_addr, 1000);
        repay_internal<WETH,Asset>(account_addr, 4000);

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
        borrow_internal<WETH,Asset>(account1, account1_addr, 50000);
        deposit_internal<UNI,Shadow>(account1, account1_addr, 100000, false);
        borrow_internal<UNI,Asset>(account1, account1_addr, 90000);
        borrow_unsafe_for_test<UNI,Asset>(account1_addr, 20000);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow_share<UNI>(account1_addr) == 100000, 0);
        assert!(borrowed_asset_share<WETH>(account1_addr) == 50000, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 110000, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 5, 0);

        // execute rebalance
        let (insufficient, is_collateral_only_C1, is_collateral_only_C2) = rebalance_shadow_internal(account1_addr, key<WETH>(), key<UNI>());
        assert!(insufficient == 15789, 0);
        assert!(is_collateral_only_C1 == false, 0);
        assert!(is_collateral_only_C2 == false, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 84211, 0);
        assert!(deposited_shadow_share<UNI>(account1_addr) == 115789, 0);
        assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 7, 0);

        // not execute rebalance
        rebalance_shadow_internal(account1_addr, key<WETH>(), key<UNI>()); // TODO: check - should be revert (?) when not necessary to rebalance
    }
    // #[test(owner=@leizd, account1=@0x111, account2=@0x222)]
    // public entry fun test_rebalance_shadow_with_patterns_collateral_only_or_borrowable(owner: &signer, account1: &signer, account2: &signer) acquires Position, AccountPositionEventHandle {
    //     setup_for_test_to_initialize_coins(owner);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

    //     // collateral only & borrowable
    //     let account1_addr = signer::address_of(account1);
    //     account::create_account_for_test(account1_addr);
    //     deposit_internal<WETH, Shadow>(account1, account1_addr, 1000, true);
    //     deposit_internal<UNI, Shadow>(account1, account1_addr, 1200, false);
    //     borrow_unsafe_for_test<UNI, Asset>(account1_addr, 1200);
    //     let (insufficient, is_collateral_only_C1, is_collateral_only_C2) = rebalance_shadow_internal(account1_addr, key<WETH>(), key<UNI>());
    //     assert!(insufficient == 263, 0);
    //     assert!(is_collateral_only_C1, 0);
    //     assert!(!is_collateral_only_C2, 0);
    //     assert!(conly_deposited_shadow_share<WETH>(account1_addr) == 737, 0);
    //     assert!(deposited_shadow_share<UNI>(account1_addr) == 1263, 0);

    //     // borrowable & borrowable
    //     let account2_addr = signer::address_of(account2);
    //     account::create_account_for_test(account2_addr);
    //     deposit_internal<WETH, Shadow>(account2, account2_addr, 2000, false);
    //     borrow_internal<WETH, Asset>(account2, account2_addr, 1800);
    //     deposit_internal<UNI, Shadow>(account2, account2_addr, 1000, false);
    //     borrow_unsafe_for_test<UNI, Asset>(account2_addr, 1200);
    //     let (insufficient, is_collateral_only_C1, is_collateral_only_C2) = rebalance_shadow_internal(account2_addr, key<WETH>(), key<UNI>());
    //     assert!(insufficient == 200, 0);
    //     assert!(!is_collateral_only_C1, 0);
    //     assert!(!is_collateral_only_C2, 0);
    //     assert!(deposited_shadow_share<WETH>(account2_addr) == 1800, 0);
    //     assert!(deposited_shadow_share<UNI>(account2_addr) == 1200, 0);
    // }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65546)]
    fun test_rebalance_shadow_with_no_need_to_rebalance(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH, Shadow>(account, account_addr, 1, false);
        deposit_internal<UNI, Shadow>(account, account_addr, 1, false);
        rebalance_shadow_internal(account_addr, key<WETH>(), key<UNI>());
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_rebalance_shadow_if_no_position_of_key1_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<UNI,Shadow>(account, account_addr, 100, false);
        rebalance_shadow_internal(account_addr, key<WETH>(), key<UNI>());
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_rebalance_shadow_if_no_position_of_key2_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        rebalance_shadow_internal(account_addr, key<WETH>(), key<UNI>());
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65540)]
    fun test_rebalance_shadow_if_protect_key1_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        deposit_internal<UNI,Shadow>(account, account_addr, 100, false);
        unable_to_rebalance_internal<WETH>(account);
        rebalance_shadow_internal(account_addr, key<WETH>(), key<UNI>());
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65540)]
    fun test_rebalance_shadow_if_protect_key2_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        deposit_internal<UNI,Shadow>(account, account_addr, 100, false);
        unable_to_rebalance_internal<UNI>(account);
        rebalance_shadow_internal(account_addr, key<WETH>(), key<UNI>());
    }
    #[test(owner=@leizd,account1=@0x111)]
    public entry fun test_borrow_and_rebalance(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
        borrow_internal<WETH,Shadow>(account1, account1_addr, 30000); //  LTV:30% - MAX:50%
        deposit_internal<UNI,Shadow>(account1, account1_addr, 100000, false);
        borrow_internal<UNI,Asset>(account1, account1_addr, 90000); // LTV:90% - MAX:90%
        borrow_unsafe_for_test<UNI,Asset>(account1_addr, 20000);
        // TODO: fix logic
        // assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        // assert!(borrowed_shadow_share<WETH>(account1_addr) == 30000, 0);
        // assert!(deposited_shadow_share<UNI>(account1_addr) == 100000, 0);
        // assert!(borrowed_asset_share<UNI>(account1_addr) == 110000, 0);

        // borrow_and_rebalance_internal(account1_addr, key<WETH>(), key<UNI>(), false);
        // assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
        // assert!(borrowed_shadow_share<WETH>(account1_addr) == 40000, 0);
        // assert!(deposited_shadow_share<UNI>(account1_addr) == 110000, 0);

        // assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<AssetToShadow>>(account1_addr).update_position_event) == 3, 0);
        // assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 4, 0);
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
        assert!(deposited_asset_share<WETH>(account1_addr) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(deposited_shadow_share<UNI>(account1_addr) == 10000, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 15000, 0);

        borrow_and_rebalance_internal(account1_addr, key<WETH>(), key<UNI>(), false);
        assert!(deposited_asset_share<WETH>(account1_addr) == 10000, 0);
        assert!(borrowed_shadow_share<WETH>(account1_addr) == 5789, 0);
        assert!(deposited_shadow_share<UNI>(account1_addr) == 15789, 0);
        assert!(borrowed_asset_share<UNI>(account1_addr) == 15000, 0);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_borrow_and_rebalance_if_no_position_of_key1_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 2000, false);
        borrow_internal<WETH,Shadow>(account, account_addr, 1000);
        borrow_and_rebalance_internal(account_addr, key<WETH>(), key<UNI>(), false);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65539)]
    fun test_borrow_and_rebalance_if_no_position_of_key2_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<UNI,Shadow>(account, account_addr, 1000, false);
        borrow_unsafe_for_test<UNI,Asset>(account_addr, 1500);
        borrow_and_rebalance_internal(account_addr, key<WETH>(), key<UNI>(), false);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65540)]
    fun test_borrow_and_rebalance_if_protect_key1_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 2000, false);
        borrow_internal<WETH,Shadow>(account, account_addr, 1000);
        deposit_internal<UNI,Shadow>(account, account_addr, 1000, false);
        borrow_unsafe_for_test<UNI,Asset>(account_addr, 1500);
        unable_to_rebalance_internal<WETH>(account);
        borrow_and_rebalance_internal(account_addr, key<WETH>(), key<UNI>(), false);
    }
    #[test(owner = @leizd, account = @0x111)]
    #[expected_failure(abort_code = 65540)]
    fun test_borrow_and_rebalance_if_protect_key2_coin(owner: &signer, account: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 2000, false);
        borrow_internal<WETH,Shadow>(account, account_addr, 1000);
        deposit_internal<UNI,Shadow>(account, account_addr, 1000, false);
        borrow_unsafe_for_test<UNI,Asset>(account_addr, 1500);
        unable_to_rebalance_internal<UNI>(account);
        borrow_and_rebalance_internal(account_addr, key<WETH>(), key<UNI>(), false);
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
        assert!(insufficient == 263, 0);
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
        assert!(insufficient == 1631, 0);
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
    // #[test(owner=@leizd,account1=@0x111)]
    // public entry fun test_borrow_asset_with_rebalance(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
    //     setup_for_test_to_initialize_coins(owner);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     let account1_addr = signer::address_of(account1);
    //     account::create_account_for_test(account1_addr);

    //     deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false); // 100,000*70%=70,000
    //     borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
    //     assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
    //     assert!(borrowed_shadow_share<WETH>(account1_addr) == 20000, 0);
    //     assert!(deposited_shadow_share<UNI>(account1_addr) == 20000, 0);
    //     assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);

    //     // assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 7, 0);
    // }

    // borrow asset with rebalance
    // #[test(owner=@leizd,account1=@0x111)]
    // public entry fun test_borrow_asset_with_rebalancing_several_positions(owner: &signer, account1: &signer) acquires Position, AccountPositionEventHandle {
    //     setup_for_test_to_initialize_coins(owner);
    //     test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
    //     let account1_addr = signer::address_of(account1);
    //     account::create_account_for_test(account1_addr);

    //     deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
    //     deposit_internal<USDC,Asset>(account1, account1_addr, 100000, false);
    //     borrow_asset_with_rebalance_internal<UNI>(account1_addr, 10000);
    //     assert!(deposited_asset_share<WETH>(account1_addr) == 100000, 0);
    //     assert!(deposited_asset_share<USDC>(account1_addr) == 100000, 0);
    //     assert!(deposited_shadow_share<UNI>(account1_addr) == 11111, 0);
    //     assert!(borrowed_asset_share<UNI>(account1_addr) == 10000, 0);
    //     assert!(borrowed_shadow_share<WETH>(account1_addr) == 0, 0);
    //     assert!(borrowed_shadow_share<USDC>(account1_addr) == 14285, 0);

    //     // assert!(event::counter<UpdatePositionEvent>(&borrow_global<AccountPositionEventHandle<ShadowToAsset>>(account1_addr).update_position_event) == 7, 0);
    // }

    // switch collateral
    #[test(account1=@0x111)]
    public entry fun test_switch_collateral_with_asset(account1: &signer) acquires Position, AccountPositionEventHandle {
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        deposit_internal<WETH,Asset>(account1, account1_addr, 10000, false);
        assert!(deposited_asset_share<WETH>(account1_addr) == 10000, 0);
        assert!(conly_deposited_asset_share<WETH>(account1_addr) == 0, 0);

        let deposited = switch_collateral_internal<WETH,Asset>(account1_addr, true);
        assert!(deposited == 10000, 0);
        assert!(deposited_asset_share<WETH>(account1_addr) == 0, 0);
        assert!(conly_deposited_asset_share<WETH>(account1_addr) == 10000, 0);

        deposit_internal<WETH,Asset>(account1, account1_addr, 30000, true);
        let deposited = switch_collateral_internal<WETH,Asset>(account1_addr, false);
        assert!(deposited == 40000, 0);
        assert!(deposited_asset_share<WETH>(account1_addr) == 40000, 0);
        assert!(conly_deposited_asset_share<WETH>(account1_addr) == 0, 0);
    }
    #[test(account1=@0x111)]
    public entry fun test_switch_collateral_with_shadow(account1: &signer) acquires Position, AccountPositionEventHandle {
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        deposit_internal<WETH,Shadow>(account1, account1_addr, 10000, true);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account1_addr) == 10000, 0);

        let deposited = switch_collateral_internal<WETH,Shadow>(account1_addr, false);
        assert!(deposited == 10000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 10000, 0);
        assert!(conly_deposited_shadow_share<WETH>(account1_addr) == 0, 0);

        deposit_internal<WETH,Shadow>(account1, account1_addr, 30000, false);
        let deposited = switch_collateral_internal<WETH,Shadow>(account1_addr, true);
        assert!(deposited == 40000, 0);
        assert!(deposited_shadow_share<WETH>(account1_addr) == 0, 0);
        assert!(conly_deposited_shadow_share<WETH>(account1_addr) == 40000, 0);
    }
}
