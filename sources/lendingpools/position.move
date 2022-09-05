// Health Factor Controller
module leizd::position {

    use std::signer;
    use std::vector;
    use std::string;
    use aptos_std::simple_map;
    use aptos_framework::type_info;
    use leizd::pool_type::{Asset,Shadow};
    use leizd::repository;
    use leizd::price_oracle;
    
    friend leizd::pool;

    struct Account has key {
        addr: address,
        rebalance_on: bool,
        types: vector<string::String>, // e.g. 0x1::module_name::WBTC
    }

    struct Position<phantom P> has key {
        balance: simple_map::SimpleMap<string::String,Balance<P>>,
    }

    struct Balance<phantom P> has store {
        deposited: u64,
        borrowed: u64,
    }

    // Called by leizd::pool

    public(friend) fun initialize_if_necessary(account: &signer) {
        if (!exists<Account>(signer::address_of(account))) {
            move_to(account, Account {
                addr: signer::address_of(account),
                rebalance_on: true,
                types: vector::empty<string::String>(),
            });
            move_to(account, Position<Asset> {
                balance: simple_map::create<string::String,Balance<Asset>>(),
            });
            move_to(account, Position<Shadow> {
                balance: simple_map::create<string::String,Balance<Shadow>>(),
            });
        }
    }

    public(friend) fun take_deposit_position<C,P>(addr: address, amount: u64) acquires Account, Position {
        let account_ref = borrow_global_mut<Account>(addr);
        update_position<C,P>(account_ref, amount, true, true);
    }

    public(friend) fun cancel_deposit_position<C,P>(addr: address, amount: u64) acquires Account, Position {
        let account_ref = borrow_global_mut<Account>(addr);
        update_position<C,P>(account_ref, amount, true, false);
    }

    public(friend) fun take_borrow_position<C,P>(addr: address, amount: u64) acquires Account, Position {
        let account_ref = borrow_global_mut<Account>(addr);
        update_position<C,P>(account_ref, amount, false, true);
    }

    public(friend) fun cancel_borrow_position<C,P>(addr: address, amount: u64) acquires Account, Position {
        let account_ref = borrow_global_mut<Account>(addr);
        update_position<C,P>(account_ref, amount, false, false);
    }

    fun should_rebalance(addr: address):bool acquires Account, Position {
        let (safe,unsafe) = separate_positions(addr);
        let safe_length = vector::length<string::String>(&safe);
        let unsafe_length = vector::length<string::String>(&unsafe);
        return safe_length != 0 && unsafe_length != 0
    }

    /// Return true if one of the positions could be rebalanced.
    fun rebalance_if_possible(addr: address):bool acquires Account, Position {
        let (safe,unsafe) = separate_positions(addr);
        let safe_length = vector::length<string::String>(&safe);
        let unsafe_length = vector::length<string::String>(&unsafe);
        // return if there is enough position to rebalance
        if (safe_length == 0 || unsafe_length == 0) { return false };

        let account_ref = borrow_global<Account>(addr);

        // insufficient volume
        let insufficient_deposited_keys = vector::empty<string::String>();
        let insufficient_deposited_values = vector::empty<u64>();
        let insufficient_deposited_sum = 0;
        let i = 0;
        while (i < unsafe_length) {
            let target_type = vector::borrow<string::String>(&unsafe, i);
            let target_borrowed = borrowed_volume(account_ref, *target_type);
            let required_deposited = target_borrowed * repository::precision() / repository::lt_of(*target_type);
            let current_deposit = deposited_volume(account_ref, *target_type);
            let diff = required_deposited - current_deposit;
            vector::push_back<string::String>(&mut insufficient_deposited_keys, *target_type);
            vector::push_back<u64>(&mut insufficient_deposited_values, diff);
            insufficient_deposited_sum = insufficient_deposited_sum + diff;
            i = i + 1;
        };

        // extra volume
        let extra_deposited_keys = vector::empty<string::String>();
        let extra_deposited_values = vector::empty<u64>();
        let extra_deposited_sum = 0;
        let i = 0;
        while (i < safe_length) {
            let target_type = vector::borrow<string::String>(&safe, i);
            let target_borrowed = borrowed_volume(account_ref, *target_type);
            let required_deposited = target_borrowed * repository::precision() / repository::lt_of(*target_type);
            let current_deposit = deposited_volume(account_ref, *target_type);
            let diff = current_deposit - required_deposited;
            vector::push_back<string::String>(&mut extra_deposited_keys, *target_type);
            vector::push_back<u64>(&mut extra_deposited_values, diff);
            extra_deposited_sum = extra_deposited_sum + diff;
            i = i + 1;
        };

        // insufficient overall
        if (insufficient_deposited_sum >= extra_deposited_sum) {
            return false
        };

        // // rebalance
        // let asset_position_ref = borrow_global_mut<Position<Asset>>(account_ref.addr);
        // // let shadow_position_ref = borrow_global_mut<Position<Shadow>>(account_ref.addr);
        // let extra_index = vector::length<string::String>(&extra_deposited_keys); 
        // let insufficient_key = vector::pop_back<string::String>(&mut insufficient_deposited_keys);
        // while (extra_index != 0) {
        //     let extra_key = vector::borrow<string::String>(&mut extra_deposited_keys, extra_index);
        //     let extra_asset_balance = simple_map::borrow_mut<string::String,Balance<Asset>>(&mut asset_position_ref.balance, extra_key);

        //     // let insufficient_asset = simple_map::borrow_mut<string::String,Balance<Asset>>(&mut asset_position_ref.balance, &insufficient_key);
        //     // if (insufficient_asset.deposited != 0)
        //     // let extra_shadow_balance = simple_map::borrow_mut<string::String,Balance<Shadow>>(&mut shadow_position_ref.balance, extra_key);
            
        //     // let insufficient_shadow_balance = simple_map::borrow<string::String,Balance<Shadow>>(&mut shadow_position_ref.balance, insufficient_key);
        //     i = i - 1;
        // };

        // while (insufficient_deposited_sum != 0) {
            // find extra position from shadow
                // find insufficient position from shadow
                // find insufficient position from asset
            // find extra position from asset
                // find insufficient position from shadow
                // find insufficient position from asset

            // find extra position from shadow
  


        // while (insufficient_deposited_sum != 0) {
        //     let insufficient_key = vector::borrow<string::String>(&insufficient_deposited_key, i-1);
        //     let insufficient_value = vector::pop_back<u64>(&mut insufficient_deposited_value);

        //     let extra_key = vector::borrow<string::String>(&insufficient_deposited_key, i-1);
        //     let extra_value = vector::pop_back<u64>(&mut extra_deposited_value);

        //     if (extra_value >= insufficient_deposited_sum) {
        //         // rebalance from extra_value to insufficient_value
        //         // TODO: find insufficient shadow
        //         // TODO: find insufficient asset
        //         // done
        //         return true
        //     };

        //     if (extra_value >= insufficient_value) {
        //         // rebalance from extra_value to insufficient_value
        //         let required_value = insufficient_value;
        //         // 1. shadow
        //         let insufficient_shadow_balance = simple_map::borrow<string::String,Balance<Shadow>>(&mut shadow_position_ref.balance, insufficient_key);
        //         // let extra_shadow_balance = simple_map::borrow<string::String,Balance<Shadow>>(balance_ref, extra_key);
        //         let shadow_deposited_value = price_oracle::volume(extra_key, insufficient_shadow_balance.deposited);
        //         if (shadow_deposited_value >= required_value) {
        //             // enough with the shadow
        //             let required_amount = price_oracle::amount(insufficient_key, required_value);
        //             add_balance<Shadow>(shadow_position_ref, *insufficient_key, required_amount);
        //             sub_balance<Shadow>(shadow_position_ref, *extra_key, required_amount);
        //             // TODO: change the balance on pool
        //             return true
        //         } else {
        //             // not enough only with the shadow
        //             // table::upsert<string::String,Balance<Shadow>>(&shadow_position_ref.balance, *insufficient_key, 0);
        //             // TODO: change the balance on pool
        //         }
        //         // 2. asset
        //         // TODO: change the balance on pool
        //     } else {
        //         // TODO: rebalance with all extra_value
        //         i = i - 1;
        //     };
        // };
        true
    }

    fun add_balance<P>(position_ref: &mut Position<P>, name: string::String, required_value: u64) {
        let required_amount = price_oracle::amount(&name, required_value);
        let balance = simple_map::borrow_mut<string::String,Balance<P>>(&mut position_ref.balance, &name);
        balance.deposited = balance.deposited + required_amount;
    }

    fun sub_balance<P>(position_ref: &mut Position<P>, name: string::String, required_value: u64) {
        let required_amount = price_oracle::amount(&name, required_value);
        let balance = simple_map::borrow_mut<string::String,Balance<P>>(&mut position_ref.balance, &name);
        balance.deposited = balance.deposited + required_amount;
    }

    fun safe_positions(account_addr: address): vector<string::String> acquires Account, Position {
        let account_ref = borrow_global<Account>(account_addr);
        let position_length = vector::length<string::String>(&account_ref.types);
        let i = 0;
        let safe = vector::empty<string::String>();

        while (i < position_length) {
            let target = vector::borrow<string::String>(&account_ref.types, i);
            if (is_safe(account_ref, *target)) {
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

    fun separate_positions(addr: address): (vector<string::String>,vector<string::String>) acquires Account, Position {
        let account_ref = borrow_global<Account>(addr);
        let position_length = vector::length<string::String>(&account_ref.types);
        let i = 0;

        let safe = vector::empty<string::String>();
        let unsafe = vector::empty<string::String>();
        while (i < position_length) {
            let target = vector::borrow<string::String>(&account_ref.types, i);
            if (is_safe(account_ref, *target)) {
                vector::push_back<string::String>(&mut safe, *target);
            } else {
                vector::push_back<string::String>(&mut unsafe, *target);
            };
            i = i + 1;
        };
        (safe,unsafe)
    }

    fun utilization_of(account_ref: &Account, name: string::String): u64 acquires  Position {
        if (vector::contains<string::String>(&account_ref.types, &name)) {
            let asset_position_ref = borrow_global<Position<Asset>>(account_ref.addr);
            let shadow_position_ref = borrow_global<Position<Shadow>>(account_ref.addr);
            let asset_balance = simple_map::borrow<string::String,Balance<Asset>>(&asset_position_ref.balance, &name);
            let shadow_balance = simple_map::borrow<string::String,Balance<Shadow>>(&shadow_position_ref.balance, &name);
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

    fun deposited_volume(account_ref: &Account, name: string::String): u64 acquires  Position {
        if (vector::contains<string::String>(&account_ref.types, &name)) {
            let asset_position_ref = borrow_global<Position<Asset>>(account_ref.addr);
            let shadow_position_ref = borrow_global<Position<Shadow>>(account_ref.addr);
            let asset_balance = simple_map::borrow<string::String,Balance<Asset>>(&asset_position_ref.balance, &name);
            let shadow_balance = simple_map::borrow<string::String,Balance<Shadow>>(&shadow_position_ref.balance, &name);
            (price_oracle::volume(&name, asset_balance.deposited) + price_oracle::volume(&name, shadow_balance.deposited)) 
        } else {
            0
        }
    }

    fun borrowed_volume(account_ref: &Account, name: string::String): u64 acquires  Position {
        if (vector::contains<string::String>(&account_ref.types, &name)) {
            let asset_position_ref = borrow_global<Position<Asset>>(account_ref.addr);
            let shadow_position_ref = borrow_global<Position<Shadow>>(account_ref.addr);
            let asset_balance = simple_map::borrow<string::String,Balance<Asset>>(&asset_position_ref.balance, &name);
            let shadow_balance = simple_map::borrow<string::String,Balance<Shadow>>(&shadow_position_ref.balance, &name);
            (price_oracle::volume(&name, asset_balance.borrowed) + price_oracle::volume(&name, shadow_balance.borrowed)) 
        } else {
            0
        }
    }

    fun is_safe(account_ref: &Account, name: string::String): bool acquires Position {
        utilization_of(account_ref, name) < repository::lt_of(name)
    }

    fun update_position<C,P>(
        account_ref: &mut Account,
        amount: u64,
        is_deposit: bool,
        is_increase: bool
    ) acquires Position {
        let name = type_info::type_name<C>();
        let position = borrow_global_mut<Position<P>>(account_ref.addr);
        if (vector::contains<string::String>(&account_ref.types, &name)) {
            let balance = simple_map::borrow_mut<string::String,Balance<P>>(&mut position.balance, &name);
            if (is_deposit && is_increase) {
                balance.deposited = balance.deposited + amount;
            } else if (is_deposit && !is_increase) {
                balance.deposited = balance.deposited - amount;
                if (balance.deposited == 0) {
                    // FIXME: consider both deposited and borrowed & remove key in vector & position in map
                    let (_, index) = vector::index_of<string::String>(&account_ref.types, &name);
                    vector::remove<string::String>(&mut account_ref.types, index);
                }
            } else if (!is_deposit && is_increase) {
                balance.borrowed = balance.borrowed + amount;
            } else {
                balance.borrowed = balance.borrowed - amount;
                if (balance.borrowed == 0) {
                    // FIXME: consider both deposited and borrowed & remove key in vector & position in map
                    let (_, index) = vector::index_of<string::String>(&account_ref.types, &name);
                    vector::remove<string::String>(&mut account_ref.types, index);
                }
            }
        } else {
            new_position<P>(account_ref, amount, is_deposit, name);
        };
    }

    fun new_position<P>(account_ref: &mut Account, amount: u64, is_deposit: bool, name: string::String) acquires Position {
        vector::push_back<string::String>(&mut account_ref.types, name);
        let position = borrow_global_mut<Position<P>>(account_ref.addr);
        if (is_deposit) {
            simple_map::add<string::String,Balance<P>>(&mut position.balance, name, Balance { deposited: amount, borrowed: 0 });
            if (is_type_shadow<P>()) {
                let asset_position = borrow_global_mut<Position<Asset>>(account_ref.addr);
                simple_map::add<string::String,Balance<Asset>>(&mut asset_position.balance, name, Balance { deposited: 0, borrowed: 0 });
            } else {
                let shadow_position = borrow_global_mut<Position<Shadow>>(account_ref.addr);
                simple_map::add<string::String,Balance<Shadow>>(&mut shadow_position.balance, name, Balance { deposited: 0, borrowed: 0 });
            };
        } else {
            simple_map::add<string::String,Balance<P>>(&mut position.balance, name, Balance { deposited: 0, borrowed: amount });
            if (is_type_shadow<P>()) {
                let asset_position = borrow_global_mut<Position<Asset>>(account_ref.addr);
                simple_map::add<string::String,Balance<Asset>>(&mut asset_position.balance, name, Balance { deposited: 0, borrowed: 0 });
            } else {
                let shadow_position = borrow_global_mut<Position<Shadow>>(account_ref.addr);
                simple_map::add<string::String,Balance<Shadow>>(&mut shadow_position.balance, name, Balance { deposited: 0, borrowed: 0 });
            };
        };
    }

    fun is_type_shadow<P>():bool {
        comparator::is_equal(
            &comparator::compare(
                &type_info::type_name<P>(),
                &string::utf8(b"0x123456789abcdef::pool_type::Shadow"),
            )
        )
    }

    use aptos_framework::comparator;

    #[test_only]
    use leizd::test_coin::{Self,WETH,UNI};
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use leizd::usdz::{USDZ};
    #[test_only]
    use leizd::test_initializer;

    #[test]
    public entry fun test_is_shadow() {
        assert!(is_type_shadow<Shadow>(), 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_take_deposit_asset_position(owner: &signer, account1: &signer) acquires Account, Position {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        test_initializer::register<WETH>(account1);
        test_coin::init_weth(owner);

        initialize_if_necessary(account1);
        let account_ref = borrow_global_mut<Account>(account1_addr);
        update_position<WETH,Asset>(account_ref, 10000, true, true);

        let account_ref = borrow_global<Account>(account1_addr);
        assert!(account_ref.addr == account1_addr, 0);
        assert!(vector::contains<string::String>(&account_ref.types, &type_info::type_name<WETH>()), 0);
        assert!(vector::length<string::String>(&account_ref.types) == 1, 0);
        let position_ref = borrow_global_mut<Position<Asset>>(account1_addr);
        let balance = simple_map::borrow_mut<string::String,Balance<Asset>>(&mut position_ref.balance, &type_info::type_name<WETH>());
        assert!(balance.deposited == 10000, 0);
        assert!(balance.borrowed == 0, 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_take_borrow_positions(owner: &signer, account1: &signer) acquires Account, Position {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        test_initializer::register<WETH>(account1);
        test_initializer::register<UNI>(account1);
        test_initializer::register<USDZ>(account1);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        price_oracle::initialize_oracle_for_test(owner);

        initialize_if_necessary(account1);
        let account1_ref = borrow_global_mut<Account>(account1_addr);
        update_position<WETH,Asset>(account1_ref, 10000, true, true); // deposit WETH
        update_position<WETH,Shadow>(account1_ref, 8000, false, true); // borrow USDZ
        update_position<UNI,Shadow>(account1_ref, 8000, true, true); // deposit USDZ
        update_position<UNI,Asset>(account1_ref, 4000, false, true); // borrow UNI

        assert!(vector::contains<string::String>(&account1_ref.types, &type_info::type_name<WETH>()), 0);
        assert!(vector::contains<string::String>(&account1_ref.types, &type_info::type_name<UNI>()), 0);
        assert!(vector::length<string::String>(&account1_ref.types) == 2, 0);
        let asset_ref = borrow_global<Position<Asset>>(account1_addr);
        let shadow_ref = borrow_global<Position<Shadow>>(account1_addr);
        let weth_asset = simple_map::borrow<string::String,Balance<Asset>>(&asset_ref.balance, &type_info::type_name<WETH>());
        let weth_shadow = simple_map::borrow<string::String,Balance<Shadow>>(&shadow_ref.balance, &type_info::type_name<WETH>());
        assert!(weth_asset.deposited == 10000, 0);
        assert!(weth_shadow.borrowed == 8000, 0);
        let uni_asset = simple_map::borrow<string::String,Balance<Asset>>(&asset_ref.balance, &type_info::type_name<UNI>());
        let uni_shadow = simple_map::borrow<string::String,Balance<Shadow>>(&shadow_ref.balance, &type_info::type_name<UNI>());
        assert!(uni_shadow.deposited == 8000, 0);
        assert!(uni_asset.borrowed == 4000, 0);

        // if WETH = $1 && UNI = $1
        assert!(utilization_of(account1_ref, type_info::type_name<WETH>()) == 800000000, 0);
        assert!(utilization_of(account1_ref, type_info::type_name<UNI>()) == 500000000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_cancel_positions(owner: &signer, account1: &signer) acquires Account, Position {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        test_initializer::register<WETH>(account1);
        test_initializer::register<UNI>(account1);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        price_oracle::initialize_oracle_for_test(owner);

        initialize_if_necessary(account1);
        let account1_ref = borrow_global_mut<Account>(account1_addr);
        update_position<WETH,Asset>(account1_ref, 10000, true, true); // deposit WETH
        update_position<WETH,Shadow>(account1_ref, 8000, false, true); // borrow USDZ
        update_position<UNI,Shadow>(account1_ref, 8000, true, true); // deposit USDZ
        update_position<UNI,Asset>(account1_ref, 4000, false, true); // borrow UNI
        update_position<UNI,Asset>(account1_ref, 2000, false, false); // repay UNI
        update_position<WETH,Asset>(account1_ref, 400, true, false); // withdraw WETH

        assert!(vector::contains<string::String>(&account1_ref.types, &type_info::type_name<WETH>()), 0);
        assert!(vector::contains<string::String>(&account1_ref.types, &type_info::type_name<UNI>()), 0);
        assert!(vector::length<string::String>(&account1_ref.types) == 2, 0);
        let asset_ref = borrow_global<Position<Asset>>(account1_addr);
        let shadow_ref = borrow_global<Position<Shadow>>(account1_addr);
        let weth_asset = simple_map::borrow<string::String,Balance<Asset>>(&asset_ref.balance, &type_info::type_name<WETH>());
        let weth_shadow = simple_map::borrow<string::String,Balance<Shadow>>(&shadow_ref.balance, &type_info::type_name<WETH>());
        assert!(weth_asset.deposited == 9600, 0);
        assert!(weth_shadow.borrowed == 8000, 0);
        let uni_asset = simple_map::borrow<string::String,Balance<Asset>>(&asset_ref.balance, &type_info::type_name<UNI>());
        let uni_shadow = simple_map::borrow<string::String,Balance<Shadow>>(&shadow_ref.balance, &type_info::type_name<UNI>());
        assert!(uni_shadow.deposited == 8000, 0);
        assert!(uni_asset.borrowed == 2000, 0);

        // if WETH = $1 && UNI = $1
        assert!(utilization_of(account1_ref, type_info::type_name<WETH>()) == 833333333, 0);
        assert!(utilization_of(account1_ref, type_info::type_name<UNI>()) == 250000000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_close_positions(owner: &signer, account1: &signer) acquires Account, Position {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        test_initializer::register<WETH>(account1);
        test_initializer::register<UNI>(account1);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        price_oracle::initialize_oracle_for_test(owner);

        initialize_if_necessary(account1);
        take_deposit_position<WETH,Asset>(account1_addr, 100);
        assert!(vector::contains<string::String>(
            &borrow_global<Account>(account1_addr).types,
            &type_info::type_name<WETH>(),
        ), 0);
        cancel_deposit_position<WETH,Asset>(account1_addr, 100);
        assert!(!vector::contains<string::String>(
            &borrow_global<Account>(account1_addr).types,
            &type_info::type_name<WETH>(),
        ), 0);
        assert!(simple_map::contains_key<string::String,Balance<Asset>>(
            &borrow_global<Position<Asset>>(account1_addr).balance,
            &type_info::type_name<WETH>(),
        ), 0);

        take_borrow_position<UNI,Asset>(account1_addr, 200);
        assert!(vector::contains<string::String>(
            &borrow_global<Account>(account1_addr).types,
            &type_info::type_name<UNI>(),
        ), 0);
        cancel_borrow_position<UNI,Asset>(account1_addr, 200);
        assert!(!vector::contains<string::String>(
            &borrow_global<Account>(account1_addr).types,
            &type_info::type_name<UNI>(),
        ), 0);
        assert!(simple_map::contains_key<string::String,Balance<Asset>>(
            &borrow_global<Position<Asset>>(account1_addr).balance,
            &type_info::type_name<UNI>(),
        ), 0);
        take_deposit_position<UNI,Asset>(account1_addr, 200); // TODO: fail because removed key in vector but remain position (duplicated keys in map)
        // cancel_deposit_position<UNI,Asset>(account1_addr, 200);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_rebalance(owner: &signer, account1: &signer) acquires Account, Position {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        test_initializer::register<WETH>(account1);
        test_initializer::register<UNI>(account1);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        repository::initialize(owner);
        price_oracle::initialize_oracle_for_test(owner);

        initialize_if_necessary(account1);
        let account1_ref = borrow_global_mut<Account>(account1_addr);

        repository::update_config<WETH>(owner, 80*repository::precision()/100, 90*repository::precision()/100);
        repository::update_config<UNI>(owner, 70*repository::precision()/100, 80*repository::precision()/100);

        // ETH: 80% (MAX: 90%)
        update_position<WETH,Asset>(account1_ref, 10000, true, true); // deposit WETH
        update_position<WETH,Shadow>(account1_ref, 8000, false, true); // borrow USDZ
        assert!(utilization_of(account1_ref, type_info::type_name<WETH>()) == 800000000, 0);

        // UNI: 85% (MAX: 80%)
        update_position<UNI,Shadow>(account1_ref, 8000, true, true); // deposit USDZ
        update_position<UNI,Asset>(account1_ref, 6800, false, true); // borrow UNI
        assert!(utilization_of(account1_ref, type_info::type_name<UNI>()) == 850000000, 0);

        // Safe: ETH / Unsafe: UNI
        let safe_pos = safe_positions(account1_addr);
        let unsafe_pos = unsafe_positions(account1_addr);
        assert!(vector::length<string::String>(&safe_pos) == 1, 0);
        assert!(vector::contains<string::String>(&safe_pos, &type_info::type_name<WETH>()), 0);
        assert!(vector::length<string::String>(&unsafe_pos) == 1, 0);
        assert!(vector::contains<string::String>(&unsafe_pos, &type_info::type_name<UNI>()), 0);
        assert!(should_rebalance(account1_addr), 0);

        // 5% UNI (Insufficient $400) <- 10% ETH (Extra $1000)
        assert!(rebalance_if_possible(account1_addr), 0);
        // TODO assert UNI-Shadow 8500
        // TODO assert WETH-Asset ?
    }
}