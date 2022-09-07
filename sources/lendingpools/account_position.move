module leizd::account_position {

    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_framework::type_info;
    use leizd::pool_type;
    use leizd::position_type::{Self,AssetToShadow,ShadowToAsset};
    use leizd::price_oracle;
    use leizd::repository;
    use leizd::usdz::{USDZ};

    friend leizd::money_market;

    const ENO_SAFE_POSITION: u64 = 0;
    const ENO_UNSAFE_POSITION: u64 = 1;
    const ENOT_ENOUGH_SHADOW: u64 = 2;

    struct Account has key {
        addr: address,
        rebalance_on: bool,
    }

    // TODO: merge with Account?
    /// P: The position type - AssetToShadow or ShadowToAsset.
    struct Position<phantom P> has key {
        coins: vector<String>, // e.g. 0x1::module_name::WBTC
        deposited: simple_map::SimpleMap<String,u64>,
        borrowed: simple_map::SimpleMap<String,u64>,
    }

    struct ChangedPosition<phantom P> {
        addr: address,
        is_deposit: bool, // deposit or borrow
        is_increase: bool, // withdraw or repay
        amount: u64,
    }

    // TODO: event

    public(friend) fun initialize_if_necessary(account: &signer) {
        if (!exists<Account>(signer::address_of(account))) {
            move_to(account, Account {
                addr: signer::address_of(account),
                rebalance_on: true,
            });
            move_to(account, Position<AssetToShadow> {
                coins: vector::empty<String>(),
                deposited: simple_map::create<String,u64>(),
                borrowed: simple_map::create<String,u64>(),
            });
            move_to(account, Position<ShadowToAsset> {
                coins: vector::empty<String>(),
                deposited: simple_map::create<String,u64>(),
                borrowed: simple_map::create<String,u64>(),
            });
        }
    }

    public(friend) fun deposit<C,P>(addr: address, amount: u64) acquires Account, Position {
        let account_ref = borrow_global_mut<Account>(addr);
        if (pool_type::is_type_asset<P>()) {
            update_position<C,AssetToShadow>(account_ref, amount, true, true);
        } else {
            update_position<C,ShadowToAsset>(account_ref, amount, true, true);
        };
    }

    public(friend) fun withdraw<C,P>(addr: address, amount: u64) acquires Account, Position {
        let account_ref = borrow_global_mut<Account>(addr);
        if (pool_type::is_type_asset<P>()) {
            update_position<C,AssetToShadow>(account_ref, amount, true, false);
        } else {
            update_position<C,ShadowToAsset>(account_ref, amount, true, false);
        };
    }

    public(friend) fun borrow<C,P>(addr: address, amount: u64) acquires Account, Position {
        let account_ref = borrow_global_mut<Account>(addr);
        if (pool_type::is_type_asset<P>()) {
            update_position<C,AssetToShadow>(account_ref, amount, false, true);
        } else {
            update_position<C,ShadowToAsset>(account_ref, amount, false, true);
        };
    }

    public(friend) fun repay<C,P>(addr: address, amount: u64) acquires Account, Position {
        let account_ref = borrow_global_mut<Account>(addr);
        if (pool_type::is_type_asset<P>()) {
            update_position<C,AssetToShadow>(account_ref, amount, false, false);
        } else {
            update_position<C,ShadowToAsset>(account_ref, amount, false, false);
        };
    }

    public(friend) fun recovery_shadow(addr: address): vector<ChangedPosition<ShadowToAsset>> acquires Position {
        // let (safe_a2s_keys, unsafe_a2s_keys) = classify_positions<AssetToShadow>(addr);
        let (safe_s2a_keys, unsafe_s2a_keys) = classify_positions<ShadowToAsset>(addr);
        assert!(vector::length<String>(&unsafe_s2a_keys) != 0, ENO_UNSAFE_POSITION);
        assert!(vector::length<String>(&safe_s2a_keys) != 0, ENO_SAFE_POSITION);
        
        // recovery by left shadows
        let results = vector::empty<ChangedPosition<ShadowToAsset>>();

        // // insufficient shadow
        // let length_unsafe_s2a_keys = vector::length<String>(&unsafe_s2a_keys);
        // // let insufficient_shadow_keys = vector::empty<String>();
        // let insufficient_shadow_amounts = vector::empty<u64>();
        // let insufficient_shadow_volume_sum = 0;
        // let i = 0;
        // while (i < length_unsafe_s2a_keys) {
        //     let coin_i = vector::borrow<String>(&unsafe_s2a_keys, i);
        //     let borrowed_i = borrowed_volume<ShadowToAsset>(addr, *coin_i);

        //     i = i + 1;
        // };
        

        // // extra shadow        
        // let length_safe_s2a_keys = vector::length<String>(&safe_s2a_keys);
        // // let extra_shadow_keys = vector::empty<String>();
        // let extra_shadow_amounts = vector::empty<u64>();
        // let extra_shadow_volume_sum = 0;
        // let i = 0;
        // while (i < length_safe_s2a_keys) {
        //     let coin_i = vector::borrow<String>(&safe_s2a_keys, i);
        //     let borrowed_i = borrowed_volume<ShadowToAsset>(addr, *coin_i);
        //     let deposited_i = deposited_volume<ShadowToAsset>(addr, *coin_i);
        //     let required_deposit = borrowed_i * repository::precision() / repository::lt_of_shadow();
        //     let extra = deposited_i - required_deposit;
        //     // vector::push_back<String>(&mut extra_shadow_keys, *coin_i);
        //     vector::push_back<u64>(&mut extra_shadow_amounts, extra);
        //     extra_shadow_volume_sum = extra_shadow_volume_sum + extra;
        //     i = i + 1;
        // };

        // let i = 0;
        // while (i < length_unsafe_s2a_keys) {
        //     let insufficient_key = vector::borrow<String>(&unsafe_s2a_keys, i);
        //     let insufficient_amount = vector::borrow<u64>(&insufficient_shadow_amounts, i);
        //     let j = 0;
        //     while (j < length_safe_s2a_keys) {
        //         let extra_key = vector::borrow<String>(&safe_s2a_keys, j);
        //         let extra_amount = vector::borrow<u64>(&extra_shadow_amounts, j);
        //         if (*extra_amount > *insufficient_amount) {
        //             let transfer_amount = *insufficient_amount;
        //             // withdraw
        //             vector::push_back<ChangedPosition<ShadowToAsset>>(&mut results, ChangedPosition<ShadowToAsset> {
        //                 addr: addr,
        //                 is_deposit: true,
        //                 is_increase: false,
        //                 amount: transfer_amount
        //             });
        //             // deposit
        //             vector::push_back<ChangedPosition<ShadowToAsset>>(&mut results, ChangedPosition<ShadowToAsset> {
        //                 addr: addr,
        //                 is_deposit: true,
        //                 is_increase: false,
        //                 amount: transfer_amount
        //             });
        //             // TODO
        //         } else {
        //             let transfer_amount = extra_amount;
        //             // TODO
        //         };

        //         j = j + 1;
        //     };
        //     i = i + 1;
        // };
        results
    }

    fun deposited_volume<P>(addr: address, key: String): u64 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let deposited = simple_map::borrow<String,u64>(&position_ref.deposited, &key);
            price_oracle::volume(&key, *deposited)
        } else {
            0
        }
    }

    fun borrowed_volume<P>(addr: address, key: String): u64 acquires Position {
        let position_ref = borrow_global_mut<Position<P>>(addr);
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let borrowed = simple_map::borrow<String,u64>(&position_ref.borrowed, &key);
            price_oracle::volume(&key, *borrowed)
        } else {
            0
        }
    }

    fun classify_positions<P>(addr: address): (vector<String>,vector<String>) acquires Position {
        let position_ref = borrow_global<Position<P>>(addr);
        let position_length = vector::length<String>(&position_ref.coins);
        let i = 0;

        let safe = vector::empty<String>();
        let unsafe = vector::empty<String>();

        while (i < position_length) {
            let target = vector::borrow<String>(&position_ref.coins, i);
            if (is_safe<P>(position_ref, *target)) {
                vector::push_back<String>(&mut safe, *target);
            } else {
                vector::push_back<String>(&mut unsafe, *target);
            };
        };
        (safe,unsafe)
    }

    fun update_position<C,P>(
        account_ref: &mut Account,
        amount: u64,
        is_deposit: bool,
        is_increase: bool,
    ) acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global_mut<Position<P>>(account_ref.addr);

        if (vector::contains<String>(&position_ref.coins, &key)) {
            if (is_deposit && is_increase) {
                // Deposit 
                let deposited = simple_map::borrow_mut<String,u64>(&mut position_ref.deposited, &key);
                *deposited = *deposited + amount;
            } else if (is_deposit && !is_increase) {
                // Withdraw
                let deposited = simple_map::borrow_mut<String,u64>(&mut position_ref.deposited, &key);
                *deposited = *deposited - amount;
                // FIXME: consider both deposited and borrowed & remove key in vector & position in map
            } else if (!is_deposit && is_increase) {
                // Borrow
                let borrowed = simple_map::borrow_mut<String,u64>(&mut position_ref.borrowed, &key);
                *borrowed = *borrowed + amount;
            } else {
                // Repay
                let borrowed = simple_map::borrow_mut<String,u64>(&mut position_ref.borrowed, &key);
                *borrowed = *borrowed - amount;
                // FIXME: consider both deposited and borrowed & remove key in vector & position in map
            }
        } else {
            new_position<P>(account_ref.addr, amount, is_deposit, key);
        };
    }

    fun new_position<P>(addr: address, amount: u64, is_deposit: bool, key: String) acquires Position {
        assert!(is_deposit, 0); // FIXME: should be deleted
        let position_ref = borrow_global_mut<Position<P>>(addr);
        vector::push_back<String>(&mut position_ref.coins, key);

        // TODO: should be key -> Balance?
        simple_map::add<String,u64>(&mut position_ref.deposited, key, amount);
        simple_map::add<String,u64>(&mut position_ref.borrowed, key, 0);
    }

    fun is_safe<P>(position_ref: &Position<P>, key: String): bool {
        if (position_type::is_asset_to_shadow<P>()) {
            utilization_of<P>(position_ref, key) < repository::lt_of(key)
        } else {
            utilization_of<P>(position_ref, key) < repository::lt_of(type_info::type_name<USDZ>())
        }
    }

    fun utilization_of<P>(position_ref: &Position<P>, key: String): u64 {
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let deposited = simple_map::borrow<String,u64>(&position_ref.deposited, &key);
            let borrowed = simple_map::borrow<String,u64>(&position_ref.borrowed, &key);
            price_oracle::volume(&key, *borrowed) / price_oracle::volume(&key, *deposited)
        } else {
            0
        }
    }

    fun generate_key<C>(): String {
        let coin_type = type_info::type_name<C>();
        coin_type
    }
}