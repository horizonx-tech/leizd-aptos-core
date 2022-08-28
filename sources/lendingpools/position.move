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
    
    friend leizd::pool;

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

    public entry fun initialize(account: &signer) {
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

    public(friend) fun take_deposit_position<C,P>(addr: address, amount: u64) acquires Account, Position {
        let account_ref = borrow_global_mut<Account>(addr);
        update_position<C,P>(account_ref, amount, true, true);
    }

    // public(friend) fun cancel_deposit_position<C,P>(addr: address, amount: u64) acquires Account, Position {
    //     let account_ref = borrow_global_mut<Account>(addr);
    //     update_position<C,P>(account_ref, amount, true, false);
    // }

    public(friend) fun take_borrow_position<C,P>(addr: address, amount: u64) acquires Account, Position {
        let account_ref = borrow_global_mut<Account>(addr);
        update_position<C,P>(account_ref, amount, false, true);
    }

    // public(friend) fun cancel_borrow_position<C,P>(addr: address, amount: u64) acquires Account, Position {
    //     let account_ref = borrow_global_mut<Account>(addr);
    //     update_position<C,P>(account_ref, amount, false, false);
    // }

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

    fun update_position<C,P>(
        account_ref: &mut Account,
        amount: u64,
        is_deposit: bool,
        is_increase: bool
    ) acquires Position {
        let name = type_info::type_name<C>();
        let position = borrow_global_mut<Position<P>>(account_ref.addr);
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
            new_position<P>(account_ref, amount, is_deposit, name);
        };
    }

    fun new_position<P>(account_ref: &mut Account, amount: u64, is_deposit: bool, name: string::String) acquires Position {
        vector::push_back<string::String>(&mut account_ref.types, name);
        let position = borrow_global_mut<Position<P>>(account_ref.addr);
        if (is_deposit) {
            table::add<string::String,Balance<P>>(&mut position.balance, name, Balance { deposited: amount, borrowed: 0 });
            if (is_type_shadow<P>()) {
                let asset_position = borrow_global_mut<Position<Asset>>(account_ref.addr);
                table::add<string::String,Balance<Asset>>(&mut asset_position.balance, name, Balance { deposited: 0, borrowed: 0 });
            } else {
                let shadow_position = borrow_global_mut<Position<Shadow>>(account_ref.addr);
                table::add<string::String,Balance<Shadow>>(&mut shadow_position.balance, name, Balance { deposited: 0, borrowed: 0 });
            };
        } else {
            table::add<string::String,Balance<P>>(&mut position.balance, name, Balance { deposited: 0, borrowed: amount });
            if (is_type_shadow<P>()) {
                let asset_position = borrow_global_mut<Position<Asset>>(account_ref.addr);
                table::add<string::String,Balance<Asset>>(&mut asset_position.balance, name, Balance { deposited: 0, borrowed: 0 });
            } else {
                let shadow_position = borrow_global_mut<Position<Shadow>>(account_ref.addr);
                table::add<string::String,Balance<Shadow>>(&mut shadow_position.balance, name, Balance { deposited: 0, borrowed: 0 });
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
    use leizd::test_common::{Self,WETH,UNI};
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use leizd::initializer;
    #[test_only]
    use leizd::usdz::{USDZ};

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
        initializer::register<WETH>(account1);
        test_common::init_weth(owner);

        initialize(account1);
        let account_ref = borrow_global_mut<Account>(account1_addr);
        update_position<WETH,Asset>(account_ref, 10000, true, true);

        let account_ref = borrow_global<Account>(account1_addr);
        assert!(account_ref.addr == account1_addr, 0);
        assert!(vector::contains<string::String>(&account_ref.types, &type_info::type_name<WETH>()), 0);
        assert!(vector::length<string::String>(&account_ref.types) == 1, 0);
        let position_ref = borrow_global_mut<Position<Asset>>(account1_addr);
        let balance = table::borrow_mut<string::String,Balance<Asset>>(&mut position_ref.balance, type_info::type_name<WETH>());
        assert!(balance.deposited == 10000, 0);
        assert!(balance.borrowed == 0, 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_take_borrow_asset_position(owner: &signer, account1: &signer) acquires Account, Position {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        initializer::register<WETH>(account1);
        initializer::register<UNI>(account1);
        initializer::register<USDZ>(account1);
        test_common::init_weth(owner);
        test_common::init_uni(owner);

        initialize(account1);
        let account_ref = borrow_global_mut<Account>(account1_addr);
        update_position<WETH,Asset>(account_ref, 10000, true, true); // deposit WETH
        update_position<WETH,Shadow>(account_ref, 8000, false, true); // borrow USDZ
        update_position<UNI,Shadow>(account_ref, 8000, true, true); // deposit USDZ
        update_position<UNI,Asset>(account_ref, 4000, false, true); // borrow UNI

        let account1_ref = borrow_global<Account>(account1_addr);
        assert!(vector::contains<string::String>(&account1_ref.types, &type_info::type_name<WETH>()), 0);
        assert!(vector::contains<string::String>(&account1_ref.types, &type_info::type_name<UNI>()), 0);
        assert!(vector::length<string::String>(&account1_ref.types) == 2, 0);
        let asset_ref = borrow_global<Position<Asset>>(account1_addr);
        let shadow_ref = borrow_global<Position<Shadow>>(account1_addr);
        let weth_asset = table::borrow<string::String,Balance<Asset>>(&asset_ref.balance, type_info::type_name<WETH>());
        let weth_shadow = table::borrow<string::String,Balance<Shadow>>(&shadow_ref.balance, type_info::type_name<WETH>());
        assert!(weth_asset.deposited == 10000, 0);
        assert!(weth_shadow.borrowed == 8000, 0);
        
        let uni_asset = table::borrow<string::String,Balance<Asset>>(&asset_ref.balance, type_info::type_name<UNI>());
        let uni_shadow = table::borrow<string::String,Balance<Shadow>>(&shadow_ref.balance, type_info::type_name<UNI>());
        assert!(uni_shadow.deposited == 8000, 0);
        assert!(uni_asset.borrowed == 4000, 0);

        // if WETH = $1 && UNI = $1
        assert!(user_ltv(account1_ref, type_info::type_name<WETH>()) == 800000000, 0);
        assert!(user_ltv(account1_ref, type_info::type_name<UNI>()) == 500000000, 0);
    }

    // #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    // public entry fun test_take_borrow_asset_position(owner: &signer, account1: &signer) acquires Account, Position {
    //     let owner_addr = signer::address_of(owner);
    //     let account1_addr = signer::address_of(account1);
    //     account::create_account_for_test(owner_addr);
    //     account::create_account_for_test(account1_addr);
    //     initializer::register<WETH>(account1);
    //     initializer::register<UNI>(account1);
    //     test_common::init_weth(owner);
    //     test_common::init_uni(owner);

    //     initialize(account1);
    //     let account_ref = borrow_global_mut<Account>(account1_addr);
    //     update_position<WETH,Asset>(account_ref, 10000, true, true); // deposit WETH
    //     update_position<UNI,Asset>(account_ref, 5000, false, true); // borrow UNI

    //     let account_ref = borrow_global<Account>(account1_addr);
    //     assert!(vector::contains<string::String>(&account_ref.types, &type_info::type_name<WETH>()), 0);
    //     assert!(vector::contains<string::String>(&account_ref.types, &type_info::type_name<UNI>()), 0);
    //     assert!(vector::length<string::String>(&account_ref.types) == 2, 0);
    //     let position_ref = borrow_global_mut<Position<Asset>>(account1_addr);
    //     let weth_balance = table::borrow_mut<string::String,Balance<Asset>>(&mut position_ref.balance, type_info::type_name<WETH>());
    //     assert!(weth_balance.deposited == 10000, 0);
    //     assert!(weth_balance.borrowed == 0, 0);
    //     let uni_balance = table::borrow_mut<string::String,Balance<Asset>>(&mut position_ref.balance, type_info::type_name<UNI>());
    //     assert!(uni_balance.deposited == 0, 0);
    //     assert!(uni_balance.borrowed == 5000, 0);
    // }
}