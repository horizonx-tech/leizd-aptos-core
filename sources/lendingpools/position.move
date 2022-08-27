// Health Factor Controller
module leizd::position {

    use std::signer;
    use std::vector;
    use std::string;
    use aptos_framework::table;
    use aptos_framework::type_info;
    use leizd::pool_type::{Asset,Shadow};
    use leizd::repository;
    use leizd::price_oracle;

    struct Account has key {
        addr: address,
        rebalance_on: bool,
        types: vector<string::String>, // e.g. 0x1::module_name::WBTC
    }

    struct Position<phantom P> has key {
        balance: table::Table<string::String,Balance<P>>,
    }

    struct Balance<phantom P> has store {
        deposited: u64,
        borrowed: u64,
    }

    public entry fun open(account: &signer) {
        move_to(account, Account {
            addr: signer::address_of(account),
            rebalance_on: true,
            types: vector::empty<string::String>(),
        });
        move_to(account, Position<Asset> {
            balance: table::new<string::String,Balance<Asset>>(),
        });
        move_to(account, Position<Shadow> {
            balance: table::new<string::String,Balance<Shadow>>(),
        });
    }

    public fun take_deposit_position<C,P>(account: &signer, amount: u64) acquires Account, Position {
        update_position<C,P>(account, amount, true, true);
    }

    public fun cancel_deposit_position<C,P>(account: &signer, amount: u64) acquires Account, Position {
        update_position<C,P>(account, amount, true, false);
    }

    public fun take_borrow_position<C,P>(account: &signer, amount: u64) acquires Account, Position {
        update_position<C,P>(account, amount, false, true);
    }

    public fun cancel_borrow_position<C,P>(account: &signer, amount: u64) acquires Account, Position {
        update_position<C,P>(account, amount, false, false);
    }

    // fun rebalance(account_addr: address) acquires Position {

    // }

    // fun rebalance_between(account_addr: address, name_from: string::String, name_to: string::String) acquires Account, Position {
    //     let account_ref = borrow_global<Account>(account_addr);
    //     assert!(!is_safe(account_ref, name_to), 0);

    //     let lacked_amount = 
    // }

    fun safe_positions(account_addr: address): vector<string::String> acquires Account, Position {
        let account_ref = borrow_global<Account>(account_addr);
        let position_length = vector::length<string::String>(&account_ref.types);
        let i = 0;
        let safe = vector::empty<string::String>();

        while (i < position_length) {
            let target = vector::borrow<string::String>(&account_ref.types, i);
            if (!is_safe(account_ref, *target)) {
                vector::push_back<string::String>(&mut safe, *target);
            };
            i = i + 1;
        };
        safe
    }

    fun unsafe_positions(account_addr: address): vector<string::String> acquires Account, Position {
        let account_ref = borrow_global<Account>(account_addr);
        let position_length = vector::length<string::String>(&account_ref.types);
        let i = 0;
        let unsafe = vector::empty<string::String>();

        while (i < position_length) {
            let target = vector::borrow<string::String>(&account_ref.types, i);
            if (!is_safe(account_ref, *target)) {
                vector::push_back<string::String>(&mut unsafe, *target);
            };
            i = i + 1;
        };
        unsafe
    }

    fun user_ltv(account_ref: &Account, name: string::String): u64 acquires  Position {
        if (vector::contains<string::String>(&account_ref.types, &name)) {
            let asset_position_ref = borrow_global<Position<Asset>>(account_ref.addr);
            let shadow_position_ref = borrow_global<Position<Shadow>>(account_ref.addr);
            let asset_balance = table::borrow<string::String,Balance<Asset>>(&asset_position_ref.balance, name);
            let shadow_balance = table::borrow<string::String,Balance<Shadow>>(&shadow_position_ref.balance, name);
            let user_ltv = 
                (price_oracle::volume(&name, asset_balance.borrowed) 
                    + price_oracle::volume(&name, shadow_balance.borrowed)) 
                * repository::precision() 
                / (price_oracle::volume(&name, asset_balance.deposited)
                    + price_oracle::volume(&name, shadow_balance.deposited));
            user_ltv
        } else {
            0
        }
    }

    fun is_safe(account_ref: &Account, name: string::String): bool acquires Position {
        user_ltv(account_ref, name) > repository::lt_of(name)
    }

    fun update_position<C,P>(account: &signer, amount: u64, is_deposit: bool, is_increase: bool) acquires Account, Position {
        let account_addr = signer::address_of(account);
        let account_ref = borrow_global_mut<Account>(account_addr);

        let position = borrow_global_mut<Position<P>>(account_addr);
        let name = type_info::type_name<C>();
        if (vector::contains<string::String>(&account_ref.types, &name)) {
            let balance = table::borrow_mut<string::String,Balance<P>>(&mut position.balance, name);
            if (is_deposit && is_increase) {
                balance.deposited = balance.deposited + amount;
            } else if (is_deposit && !is_increase) {
                balance.deposited = balance.deposited - amount;
                if (balance.deposited == 0) {
                    let (_, index) = vector::index_of<string::String>(&account_ref.types, &name);
                    vector::remove<string::String>(&mut account_ref.types, index);
                }
            } else if (!is_deposit && is_increase) {
                balance.borrowed = balance.borrowed + amount;
            } else {
                balance.borrowed = balance.borrowed - amount;
                if (balance.borrowed == 0) {
                    let (_, index) = vector::index_of<string::String>(&account_ref.types, &name);
                    vector::remove<string::String>(&mut account_ref.types, index);
                }
            }
        } else {
            vector::push_back<string::String>(&mut account_ref.types, name);
            if (is_deposit) {
                table::add<string::String,Balance<P>>(&mut position.balance, name, Balance { deposited: amount, borrowed: 0 });
            } else {
                table::add<string::String,Balance<P>>(&mut position.balance, name, Balance { deposited: 0, borrowed: amount });
            }
        }
    }
}