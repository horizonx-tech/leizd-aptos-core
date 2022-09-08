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

    /// P: The position type - AssetToShadow or ShadowToAsset.
    struct Position<phantom P> has key {
        coins: vector<String>, // e.g. 0x1::module_name::WBTC
        // TODO: protected_coins
        deposited: simple_map::SimpleMap<String,u64>,
        conly_deposited: simple_map::SimpleMap<String,u64>,
        borrowed: simple_map::SimpleMap<String,u64>,
    }

    public fun deposited_asset<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        if (simple_map::contains_key<String,u64>(&position_ref.deposited, &key)) {
            *simple_map::borrow<String,u64>(&position_ref.deposited, &key)
        } else {
            0
        }
    }

    public fun conly_deposited_asset<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
         if (simple_map::contains_key<String,u64>(&position_ref.conly_deposited, &key)) {
            *simple_map::borrow<String,u64>(&position_ref.conly_deposited, &key)
        } else {
            0
        }
    }

    public fun borrowed_asset<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        *simple_map::borrow<String,u64>(&position_ref.borrowed, &key)
    }


    public fun deposited_shadow<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,u64>(&position_ref.deposited, &key)) {
            *simple_map::borrow<String,u64>(&position_ref.deposited, &key)
        } else {
            0
        }
    }

    public fun conly_deposited_shadow<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,u64>(&position_ref.conly_deposited, &key)) {
            *simple_map::borrow<String,u64>(&position_ref.conly_deposited, &key)
        } else {
            0
        }
    }

    public fun borrowed_shadow<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        *simple_map::borrow<String,u64>(&position_ref.borrowed, &key)
    }

    // TODO: event

    fun initialize_if_necessary(account: &signer) {
        if (!exists<Position<AssetToShadow>>(signer::address_of(account))) {
            move_to(account, Position<AssetToShadow> {
                coins: vector::empty<String>(),
                deposited: simple_map::create<String,u64>(),
                conly_deposited: simple_map::create<String,u64>(),
                borrowed: simple_map::create<String,u64>(),
            });
            move_to(account, Position<ShadowToAsset> {
                coins: vector::empty<String>(),
                deposited: simple_map::create<String,u64>(),
                conly_deposited: simple_map::create<String,u64>(),
                borrowed: simple_map::create<String,u64>(),
            });
        }
    }

    public(friend) fun deposit<C,P>(account: &signer, amount: u64, is_collateral_only: bool) acquires Position {
        deposit_internal<C,P>(account, amount, is_collateral_only);
    }

    fun deposit_internal<C,P>(account: &signer, amount: u64, is_collateral_only: bool) acquires Position {
        initialize_if_necessary(account);
        let addr = signer::address_of(account);
        if (pool_type::is_type_asset<P>()) {
            update_position<C,AssetToShadow>(addr, amount, true, true, is_collateral_only);
        } else {
            update_position<C,ShadowToAsset>(addr, amount, true, true, is_collateral_only);
        };
    }

    public(friend) fun withdraw<C,P>(addr: address, amount: u64, is_collateral_only: bool) acquires Position {
        withdraw_internal<C,P>(addr, amount, is_collateral_only);
    }

    fun withdraw_internal<C,P>(addr: address, amount: u64, is_collateral_only: bool) acquires Position {
        if (pool_type::is_type_asset<P>()) {
            update_position<C,AssetToShadow>(addr, amount, true, false, is_collateral_only);
        } else {
            update_position<C,ShadowToAsset>(addr, amount, true, false, is_collateral_only);
        };
    }

    public(friend) fun borrow<C,P>(addr: address, amount: u64) acquires Position {
        borrow_internal<C,P>(addr, amount);
    }

    fun borrow_internal<C,P>(addr: address, amount: u64) acquires Position {
        if (pool_type::is_type_asset<P>()) {
            update_position<C,ShadowToAsset>(addr, amount, false, true, false);
        } else {
            update_position<C,AssetToShadow>(addr, amount, false, true, false);
        };
    }

    public(friend) fun repay<C,P>(addr: address, amount: u64) acquires Position {
        if (pool_type::is_type_asset<P>()) {
            update_position<C,ShadowToAsset>(addr, amount, false, false, false);
        } else {
            update_position<C,AssetToShadow>(addr, amount, false, false, false);
        };
    }

    public(friend) fun rebalance_shadow<C1,C2>(addr: address, is_collateral_only: bool): u64 acquires Position {
        rebalance_shadow_internal<C1,C2>(addr, is_collateral_only)
    }

    fun rebalance_shadow_internal<C1,C2>(addr: address, is_collateral_only: bool): u64 acquires Position {
        // assert!(extra >= insufficient, 0);
        let key1 = generate_key<C1>();
        let key2 = generate_key<C2>();

        // extra in key1
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key1);
        let deposited = deposited_volume<ShadowToAsset>(addr, key1);
        let required_deposit = borrowed * repository::precision() / repository::lt_of_shadow();
        let extra = deposited - required_deposit;

        // insufficient in key2
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key2);
        let deposited = deposited_volume<ShadowToAsset>(addr, key2);
        let required_deposit = borrowed * repository::precision() / repository::lt_of_shadow();
        let insufficient = required_deposit - deposited;

        assert!(extra >= insufficient, 0);
        update_position<C1,ShadowToAsset>(addr, insufficient, true, false, is_collateral_only);
        update_position<C2,ShadowToAsset>(addr, insufficient, true, true, is_collateral_only);

        insufficient
    }

    public(friend) fun borrow_and_rebalance<C1,C2>(addr: address, is_collateral_only: bool): u64 acquires Position {
        borrow_and_rebalance_internal<C1,C2>(addr, is_collateral_only)
    }

    fun borrow_and_rebalance_internal<C1,C2>(addr: address, is_collateral_only: bool): u64 acquires Position {
        let key1 = generate_key<C1>();
        let key2 = generate_key<C2>();

        // extra in key1
        let borrowed = borrowed_volume<AssetToShadow>(addr, key1);
        let deposited = deposited_volume<AssetToShadow>(addr, key1);
        let borrowable = deposited * repository::lt<C1>() / repository::precision();
        let extra_borrow = borrowable - borrowed;

        // insufficient in key2
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key2);
        let deposited = deposited_volume<ShadowToAsset>(addr, key2);
        let required_deposit = borrowed * repository::precision() / repository::lt_of_shadow();
        let insufficient = required_deposit - deposited;

        assert!(extra_borrow >= insufficient, 0);
        update_position<C1,AssetToShadow>(addr, insufficient, false, true, is_collateral_only);
        update_position<C2,ShadowToAsset>(addr, insufficient, true, true, is_collateral_only);

        insufficient
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
        addr: address,
        amount: u64,
        is_deposit: bool,
        is_increase: bool,
        is_collateral_only: bool,
    ) acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global_mut<Position<P>>(addr);

        if (vector::contains<String>(&position_ref.coins, &key)) {
            if (is_deposit && is_increase) {
                // Deposit 
                let deposited = simple_map::borrow_mut<String,u64>(&mut position_ref.deposited, &key);
                *deposited = *deposited + amount;
                if (is_collateral_only) {
                    let conly_deposited = simple_map::borrow_mut<String,u64>(&mut position_ref.conly_deposited, &key);
                    *conly_deposited = *conly_deposited + amount;
                }
            } else if (is_deposit && !is_increase) {
                // Withdraw
                let deposited = simple_map::borrow_mut<String,u64>(&mut position_ref.deposited, &key);
                *deposited = *deposited - amount;
                if (is_collateral_only) {
                    let conly_deposited = simple_map::borrow_mut<String,u64>(&mut position_ref.conly_deposited, &key);
                    *conly_deposited = *conly_deposited - amount;
                }
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
            new_position<P>(addr, amount, is_deposit, is_collateral_only, key);
        };
    }

    fun new_position<P>(addr: address, amount: u64, is_deposit: bool, is_collateral_only: bool, key: String) acquires Position {
        // assert!(is_deposit, 0); // FIXME: should be deleted
        is_deposit;
        let position_ref = borrow_global_mut<Position<P>>(addr);
        vector::push_back<String>(&mut position_ref.coins, key);

        let conly_amount = if (is_collateral_only) amount else 0;
        // TODO: should be key -> Balance?
        simple_map::add<String,u64>(&mut position_ref.deposited, key, amount);
        simple_map::add<String,u64>(&mut position_ref.conly_deposited, key, conly_amount);
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

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::test_coin::{Self,WETH,UNI};
    #[test_only]
    use leizd::initializer;
    #[test_only]
    use leizd::pool_type::{Asset,Shadow};
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use leizd::usdz;

    // for deposit
    #[test_only]
    fun setup_for_test_to_initialize_coins(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initializer::initialize(owner);
        test_coin::init_weth(owner);
        repository::new_asset<WETH>(owner);
        repository::new_asset<UNI>(owner);
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_internal<WETH,Asset>(account, 800000, false);
        assert!(deposited_asset<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_by_two(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);
        initializer::register<WETH>(account1);
        initializer::register<WETH>(account2);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        managed_coin::mint<WETH>(owner, account2_addr, 1000000);

        deposit_internal<WETH,Asset>(account1, 800000, false);
        deposit_internal<WETH,Asset>(account2, 200000, false);
        assert!(deposited_asset<WETH>(account1_addr) == 800000, 0);
        assert!(deposited_asset<WETH>(account2_addr) == 200000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_internal<WETH,Asset>(account, 800000, true);
        assert!(deposited_asset<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        initializer::register<USDZ>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        usdz::mint_for_test(account_addr, 1000000);

        deposit_internal<WETH,Shadow>(account, 800000, false);
        assert!(deposited_asset<WETH>(account_addr) == 0, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 0, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        initializer::register<USDZ>(account);

        usdz::mint_for_test(account_addr, 1000000);

        deposit_internal<WETH,Shadow>(account, 800000, true);
        assert!(deposited_shadow<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 800000, 0);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_internal<WETH,Asset>(account, 700000, false);
        withdraw_internal<WETH,Asset>(account_addr, 600000, false);
        assert!(deposited_asset<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_same_as_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit_internal<WETH,Asset>(account, 30, false);
        withdraw_internal<WETH,Asset>(account_addr, 30, false);
        assert!(deposited_asset<WETH>(account_addr) == 0, 0);
    }

    // rebalance shadow
    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_rebalance_shadow(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        initializer::register<WETH>(account1);
        initializer::register<UNI>(account1);
        initializer::register<USDZ>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        usdz::mint_for_test(account1_addr, 1000000);

        deposit_internal<WETH,Shadow>(account1, 100000, false);
        borrow_internal<WETH,Asset>(account1_addr, 50000);
        deposit_internal<UNI,Shadow>(account1, 100000, false);
        borrow_internal<UNI,Asset>(account1_addr, 110000);
        assert!(deposited_shadow<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 100000, 0);

        rebalance_shadow_internal<WETH,UNI>(account1_addr, false);
        assert!(deposited_shadow<WETH>(account1_addr) == 90000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 110000, 0);
    }
    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_and_rebalance(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        initializer::register<WETH>(account1);
        initializer::register<UNI>(account1);
        initializer::register<USDZ>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        usdz::mint_for_test(account1_addr, 1000000);

        deposit_internal<WETH,Asset>(account1, 100000, false);
        borrow_internal<WETH,Shadow>(account1_addr, 50000);
        deposit_internal<UNI,Shadow>(account1, 100000, false);
        borrow_internal<UNI,Asset>(account1_addr, 110000);
        assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 50000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 100000, 0);
        assert!(borrowed_asset<UNI>(account1_addr) == 110000, 0);

        borrow_and_rebalance_internal<WETH,UNI>(account1_addr, false);
        assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 60000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 110000, 0);
    }
}