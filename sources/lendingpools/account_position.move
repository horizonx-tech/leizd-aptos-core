module leizd::account_position {

    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_framework::type_info;
    use leizd::pool_type;
    use leizd::position_type::{AssetToShadow,ShadowToAsset};

    friend leizd::market;

    struct Account has key {
        addr: address,
        rebalance_on: bool,
        types: vector<String>, // e.g. 0x1::module_name::WBTC
    }


    // TODO: merge with Account
    struct Position<phantom P> has key {
        deposited: simple_map::SimpleMap<String,u64>,
        borrowed: simple_map::SimpleMap<String,u64>,
    }

    // TODO: event

    public(friend) fun initialize_if_necessary(account: &signer) {
        if (!exists<Account>(signer::address_of(account))) {
            move_to(account, Account {
                addr: signer::address_of(account),
                rebalance_on: true,
                types: vector::empty<String>(),
            });
            move_to(account, Position<AssetToShadow> {
                deposited: simple_map::create<String,u64>(),
                borrowed: simple_map::create<String,u64>(),
            });
            move_to(account, Position<ShadowToAsset> {
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
        }
    }

    fun update_position<C,P>(
        account_ref: &mut Account,
        amount: u64,
        is_deposit: bool,
        is_increase: bool,
    ) acquires Position {
        let key = generate_key<C,P>();
        let position = borrow_global_mut<Position<P>>(account_ref.addr);

        if (vector::contains<String>(&account_ref.types, &key)) {
            if (is_deposit && is_increase) {
                // Deposit 
                let deposited = simple_map::borrow_mut<String,u64>(&mut position.deposited, &key);
                *deposited = *deposited + amount;
            } else if (is_deposit && !is_increase) {
                // Withdraw
                let deposited = simple_map::borrow_mut<String,u64>(&mut position.deposited, &key);
                *deposited = *deposited - amount;
                // FIXME: consider both deposited and borrowed & remove key in vector & position in map
            } else if (!is_deposit && is_increase) {
                // Borrow
                let borrowed = simple_map::borrow_mut<String,u64>(&mut position.borrowed, &key);
                *borrowed = *borrowed + amount;
            } else {
                // Repay
                let borrowed = simple_map::borrow_mut<String,u64>(&mut position.borrowed, &key);
                *borrowed = *borrowed - amount;
                // FIXME: consider both deposited and borrowed & remove key in vector & position in map
            }
        } else {
            new_position<P>(account_ref, amount, is_deposit, key);
        };
    }

    fun new_position<P>(account_ref: &mut Account, amount: u64, is_deposit: bool, key: String) acquires Position {
        assert!(is_deposit, 0); // FIXME: should be deleted
        vector::push_back<String>(&mut account_ref.types, key);
        let position = borrow_global_mut<Position<P>>(account_ref.addr);

        // TODO: should be key -> Balance?
        simple_map::add<String,u64>(&mut position.deposited, key, amount);
        simple_map::add<String,u64>(&mut position.borrowed, key, 0);
    }

    fun generate_key<C,P>(): String {
        let coin_type = type_info::type_name<C>();
        // let pool_type = type_info::type_name<P>();
        // string::append(&mut coin_type, pool_type);
        coin_type
    }
}