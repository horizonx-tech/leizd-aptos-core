module leizd::account_position {

    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_framework::type_info;
    use leizd::pool_type;
    use leizd::position_type::{AssetToShadow,ShadowToAsset};
    use leizd::price_oracle;
    use leizd::repository;

    friend leizd::market;

    struct Account has key {
        addr: address,
        rebalance_on: bool,
        // types: vector<String>, // e.g. 0x1::module_name::WBTC
    }


    // TODO: merge with Account?
    /// P: The position type - AssetToShadow or ShadowToAsset.
    struct Position<phantom P> has key {
        types: vector<String>, // e.g. 0x1::module_name::WBTC
        deposited: simple_map::SimpleMap<String,u64>,
        borrowed: simple_map::SimpleMap<String,u64>,
    }

    // TODO: event

    public(friend) fun initialize_if_necessary(account: &signer) {
        if (!exists<Account>(signer::address_of(account))) {
            move_to(account, Account {
                addr: signer::address_of(account),
                rebalance_on: true,
            });
            move_to(account, Position<AssetToShadow> {
                types: vector::empty<String>(),
                deposited: simple_map::create<String,u64>(),
                borrowed: simple_map::create<String,u64>(),
            });
            move_to(account, Position<ShadowToAsset> {
                types: vector::empty<String>(),
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

    // public(friend) fun recovery_if_possible(addr: address) acquires Account, Position {
        
    // }

    fun classify_positions<P>(addr: address): (vector<String>,vector<String>) acquires Position {
        let position_ref = borrow_global<Position<P>>(addr);
        let position_length = vector::length<String>(&position_ref.types);
        let i = 0;

        let safe = vector::empty<String>();
        let unsafe = vector::empty<String>();

        while (i < position_length) {
            let target = vector::borrow<String>(&position_ref.types, i);
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

        if (vector::contains<String>(&position_ref.types, &key)) {
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
        vector::push_back<String>(&mut position_ref.types, key);

        // TODO: should be key -> Balance?
        simple_map::add<String,u64>(&mut position_ref.deposited, key, amount);
        simple_map::add<String,u64>(&mut position_ref.borrowed, key, 0);
    }

    fun is_safe<P>(position_ref: &Position<P>, key: String): bool {
        utilization_of<P>(position_ref, key) < repository::lt_of(key)
    }

    fun utilization_of<P>(position_ref: &Position<P>, key: String): u64 {
        if (vector::contains<String>(&position_ref.types, &key)) {
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