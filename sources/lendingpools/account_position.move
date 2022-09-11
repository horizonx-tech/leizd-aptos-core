module leizd::account_position {

    use std::error;
    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_framework::type_info;
    use leizd::pool_type;
    use leizd::position_type::{Self,AssetToShadow,ShadowToAsset};
    use leizd::price_oracle;
    use leizd::risk_factor;

    friend leizd::money_market;

    const ENO_SAFE_POSITION: u64 = 0;
    const ENO_UNSAFE_POSITION: u64 = 1;
    const ENOT_ENOUGH_SHADOW: u64 = 2;
    const ENOT_EXISTED: u64 = 3;
    const EALREADY_PROTECTED: u64 = 4;
    const EINSUFFICIENT_AMOUNT: u64 = 5;

    /// P: The position type - AssetToShadow or ShadowToAsset.
    struct Position<phantom P> has key {
        coins: vector<String>, // e.g. 0x1::module_name::WBTC
        protected_coins: simple_map::SimpleMap<String,bool>, // e.g. 0x1::module_name::WBTC - true
        balance: simple_map::SimpleMap<String,Balance>,
    }

    struct Balance has store {
        deposited: u64,
        conly_deposited: u64,
        borrowed: u64,
    }

    public fun deposited_asset<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).deposited
        } else {
            0
        }
    }

    public fun conly_deposited_asset<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).conly_deposited
        } else {
            0
        }
    }

    public fun borrowed_asset<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed
        } else {
            0
        }
    }


    public fun deposited_shadow<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).deposited
        } else {
            0
        }
    }

    public fun conly_deposited_shadow<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).conly_deposited
        } else {
            0
        }
    }

    public fun borrowed_shadow<C>(addr: address): u64 acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<AssetToShadow>>(addr);
        if (simple_map::contains_key<String,Balance>(&position_ref.balance, &key)) {
            simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed
        } else {
            0
        }
    }

    // TODO: event

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
        }
    }

    public(friend) fun protect_coin<C>(account: &signer) acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global_mut<Position<AssetToShadow>>(signer::address_of(account));
        assert!(vector::contains<String>(&position_ref.coins, &key), ENOT_EXISTED);
        assert!(!simple_map::contains_key<String,bool>(&position_ref.protected_coins, &key), EALREADY_PROTECTED);

        simple_map::add<String,bool>(&mut position_ref.protected_coins, key, true);
    }

    public(friend) fun unprotect_coin<C>(account: &signer) acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global_mut<Position<AssetToShadow>>(signer::address_of(account));
        assert!(vector::contains<String>(&position_ref.coins, &key), ENOT_EXISTED);
        assert!(simple_map::contains_key<String,bool>(&position_ref.protected_coins, &key), EALREADY_PROTECTED);

        simple_map::remove<String,bool>(&mut position_ref.protected_coins, &key);
    }

    public(friend) fun deposit<C,P>(account: &signer, depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position {
        deposit_internal<C,P>(account, depositor_addr, amount, is_collateral_only);
    }

    fun deposit_internal<C,P>(account: &signer, depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position {
        initialize_if_necessary(account);
        assert!(exists<Position<AssetToShadow>>(depositor_addr), 0);

        if (pool_type::is_type_asset<P>()) {
            update_position<C,AssetToShadow>(depositor_addr, amount, true, true, is_collateral_only);
        } else {
            update_position<C,ShadowToAsset>(depositor_addr, amount, true, true, is_collateral_only);
        };
    }

    public(friend) fun withdraw<C,P>(depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position {
        withdraw_internal<C,P>(depositor_addr, amount, is_collateral_only);
    }

    fun withdraw_internal<C,P>(depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position {
        if (pool_type::is_type_asset<P>()) {
            update_position<C,AssetToShadow>(depositor_addr, amount, true, false, is_collateral_only);
            assert!(is_safe<C,AssetToShadow>(depositor_addr), 0);
        } else {
            update_position<C,ShadowToAsset>(depositor_addr, amount, true, false, is_collateral_only);
            assert!(is_safe<C,ShadowToAsset>(depositor_addr), 0);
        };
    }

    public(friend) fun borrow<C,P>(addr: address, amount: u64) acquires Position {
        borrow_internal<C,P>(addr, amount);
    }

    fun borrow_internal<C,P>(borrower_addr: address, amount: u64) acquires Position {
        if (pool_type::is_type_asset<P>()) {
            update_position<C,ShadowToAsset>(borrower_addr, amount, false, true, false);
            assert!(is_safe<C,ShadowToAsset>(borrower_addr), 0);
        } else {
            update_position<C,AssetToShadow>(borrower_addr, amount, false, true, false);
            assert!(is_safe<C,AssetToShadow>(borrower_addr), 0);
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
        let key1 = generate_key<C1>();
        let key2 = generate_key<C2>();

        let position_ref = borrow_global<Position<ShadowToAsset>>(addr);
        assert!(vector::contains<String>(&position_ref.coins, &key1), ENOT_EXISTED);
        assert!(vector::contains<String>(&position_ref.coins, &key2), ENOT_EXISTED);
        assert!(!simple_map::contains_key<String,bool>(&position_ref.protected_coins, &key1), EALREADY_PROTECTED);
        assert!(!simple_map::contains_key<String,bool>(&position_ref.protected_coins, &key2), EALREADY_PROTECTED);

        // extra in key1
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key1);
        let deposited = deposited_volume<ShadowToAsset>(addr, key1);
        let required_deposit = borrowed * risk_factor::precision() / risk_factor::lt_of_shadow();
        let extra = deposited - required_deposit;

        // insufficient in key2
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key2);
        let deposited = deposited_volume<ShadowToAsset>(addr, key2);
        let required_deposit = borrowed * risk_factor::precision() / risk_factor::lt_of_shadow();
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

        let position1_ref = borrow_global<Position<AssetToShadow>>(addr);
        let position2_ref = borrow_global<Position<ShadowToAsset>>(addr);
        assert!(vector::contains<String>(&position1_ref.coins, &key1), ENOT_EXISTED);
        assert!(vector::contains<String>(&position2_ref.coins, &key2), ENOT_EXISTED);
        assert!(!simple_map::contains_key<String,bool>(&position1_ref.protected_coins, &key1), EALREADY_PROTECTED);
        assert!(!simple_map::contains_key<String,bool>(&position2_ref.protected_coins, &key2), EALREADY_PROTECTED);

        // extra in key1
        let borrowed = borrowed_volume<AssetToShadow>(addr, key1);
        let deposited = deposited_volume<AssetToShadow>(addr, key1);
        let borrowable = deposited * risk_factor::lt<C1>() / risk_factor::precision();
        let extra_borrow = borrowable - borrowed;

        // insufficient in key2
        let borrowed = borrowed_volume<ShadowToAsset>(addr, key2);
        let deposited = deposited_volume<ShadowToAsset>(addr, key2);
        let required_deposit = borrowed * risk_factor::precision() / risk_factor::lt_of_shadow();
        let insufficient = required_deposit - deposited;

        assert!(extra_borrow >= insufficient, 0);
        update_position<C1,AssetToShadow>(addr, insufficient, false, true, is_collateral_only);
        update_position<C2,ShadowToAsset>(addr, insufficient, true, true, is_collateral_only);

        insufficient
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
                let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
                balance_ref.deposited = balance_ref.deposited + amount;
                if (is_collateral_only) {
                    let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
                    balance_ref.conly_deposited = balance_ref.conly_deposited + amount;
                }
            } else if (is_deposit && !is_increase) {
                // Withdraw
                let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
                assert!(balance_ref.deposited >= amount, error::invalid_argument(EINSUFFICIENT_AMOUNT));
                balance_ref.deposited = balance_ref.deposited - amount;
                if (balance_ref.deposited == 0) {
                    let (_, i) = vector::index_of<String>(&position_ref.coins, &key);
                    vector::remove<String>(&mut position_ref.coins, i);
                };
                if (is_collateral_only) {
                    let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
                    balance_ref.conly_deposited = balance_ref.conly_deposited - amount;
                    if (balance_ref.conly_deposited == 0) {
                        let (_, i) = vector::index_of<String>(&position_ref.coins, &key);
                        vector::remove<String>(&mut position_ref.coins, i);
                    };
                }
            } else if (!is_deposit && is_increase) {
                // Borrow
                let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
                balance_ref.borrowed = balance_ref.borrowed + amount;
            } else {
                // Repay
                let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
                balance_ref.borrowed = balance_ref.borrowed - amount;
                if (balance_ref.borrowed == 0) {
                    let (_, i) = vector::index_of<String>(&position_ref.coins, &key);
                    vector::remove<String>(&mut position_ref.coins, i);
                };
            }
        } else {
            new_position<P>(addr, amount, is_deposit, is_collateral_only, key);
        };
    }

    fun new_position<P>(addr: address, amount: u64, is_deposit: bool, is_collateral_only: bool, key: String) acquires Position {
        assert!(is_deposit, 0);
        let position_ref = borrow_global_mut<Position<P>>(addr);
        vector::push_back<String>(&mut position_ref.coins, key);

        let conly_amount = if (is_collateral_only) amount else 0;
        simple_map::add<String,Balance>(&mut position_ref.balance, key, Balance {
            deposited: amount,
            conly_deposited: conly_amount,
            borrowed: 0,
        });
    }

    fun is_safe<C,P>(addr: address): bool acquires Position {
        let key = generate_key<C>();
        let position_ref = borrow_global<Position<P>>(addr);
        if (position_type::is_asset_to_shadow<P>()) {
            utilization_of<P>(position_ref, key) < risk_factor::lt_of(key)
        } else {
            utilization_of<P>(position_ref, key) < risk_factor::lt_of_shadow()
        }
    }

    fun utilization_of<P>(position_ref: &Position<P>, key: String): u64 {
        if (vector::contains<String>(&position_ref.coins, &key)) {
            let deposited = simple_map::borrow<String,Balance>(&position_ref.balance, &key).deposited;
            if (deposited == 0) { 
                return 0 
            };
            let borrowed = simple_map::borrow<String,Balance>(&position_ref.balance, &key).borrowed;
            price_oracle::volume(&key, borrowed) * risk_factor::precision() / price_oracle::volume(&key, deposited)
        } else {
            0
        }
    }

    fun generate_key<C>(): String {
        let coin_type = type_info::type_name<C>();
        coin_type
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use leizd::initializer;
    #[test_only]
    use leizd::pool_type::{Asset,Shadow};
    #[test_only]
    use leizd::test_coin::{WETH,UNI};

    // for deposit
    #[test_only]
    fun setup_for_test_to_initialize_coins(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(signer::address_of(owner));
        initializer::initialize(owner);
        risk_factor::new_asset<WETH>(owner);
        risk_factor::new_asset<UNI>(owner);
    }
    #[test_only]
    fun borrow_unsafe_for_test<C,P>(borrower_addr: address, amount: u64) acquires Position {
        if (pool_type::is_type_asset<P>()) {
            update_position<C,ShadowToAsset>(borrower_addr, amount, false, true, false);
        } else {
            update_position<C,AssetToShadow>(borrower_addr, amount, false, true, false);
        };
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        deposit_internal<WETH,Asset>(account, account_addr, 800000, false);
        assert!(deposited_asset<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_by_two(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        deposit_internal<WETH,Asset>(account1, account1_addr, 800000, false);
        deposit_internal<WETH,Asset>(account2, account2_addr, 200000, false);
        assert!(deposited_asset<WETH>(account1_addr) == 800000, 0);
        assert!(deposited_asset<WETH>(account2_addr) == 200000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        deposit_internal<WETH,Asset>(account, account_addr, 800000, true);
        assert!(deposited_asset<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        deposit_internal<WETH,Shadow>(account, account_addr, 800000, false);
        assert!(deposited_shadow<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        deposit_internal<WETH,Shadow>(account, account_addr, 800000, true);
        assert!(deposited_shadow<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_with_all_patterns(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        deposit_internal<WETH,Asset>(account, account_addr, 1, false);
        deposit_internal<WETH,Asset>(account, account_addr, 2, true);
        deposit_internal<WETH,Shadow>(account, account_addr, 10, false);
        deposit_internal<WETH,Shadow>(account, account_addr, 20, true);
        assert!(deposited_asset<WETH>(account_addr) == 3, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 2, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 30, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 20, 0);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        deposit_internal<WETH,Asset>(account, account_addr, 700000, false);
        withdraw_internal<WETH,Asset>(account_addr, 600000, false);
        assert!(deposited_asset<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_same_as_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        deposit_internal<WETH,Asset>(account, account_addr, 30, false);
        withdraw_internal<WETH,Asset>(account_addr, 30, false);
        assert!(deposited_asset<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        deposit_internal<WETH,Asset>(account, account_addr, 30, false);
        withdraw_internal<WETH,Asset>(account_addr, 31, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_all_patterns(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        deposit_internal<WETH,Asset>(account, account_addr, 100, false);
        deposit_internal<WETH,Asset>(account, account_addr, 100, true);
        deposit_internal<WETH,Shadow>(account, account_addr, 100, false);
        deposit_internal<WETH,Shadow>(account, account_addr, 100, true);
        withdraw_internal<WETH,Asset>(account_addr, 1, false);
        withdraw_internal<WETH,Asset>(account_addr, 2, true);
        withdraw_internal<WETH,Shadow>(account_addr, 10, false);
        withdraw_internal<WETH,Shadow>(account_addr, 20, true);
        assert!(deposited_asset<WETH>(account_addr) == 197, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 98, 0);
        assert!(deposited_shadow<WETH>(account_addr) == 170, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 80, 0);
    }

    // rebalance shadow
    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_rebalance_shadow(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);

        deposit_internal<WETH,Shadow>(account1, account1_addr, 100000, false);
        borrow_internal<WETH,Asset>(account1_addr, 50000);
        deposit_internal<UNI,Shadow>(account1, account1_addr, 100000, false);
        borrow_internal<UNI,Asset>(account1_addr, 90000);
        borrow_unsafe_for_test<UNI,Asset>(account1_addr, 20000);
        assert!(deposited_shadow<WETH>(account1_addr) == 100000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 100000, 0);
        assert!(borrowed_asset<WETH>(account1_addr) == 50000, 0);
        assert!(borrowed_asset<UNI>(account1_addr) == 110000, 0);

        rebalance_shadow_internal<WETH,UNI>(account1_addr, false);
        assert!(deposited_shadow<WETH>(account1_addr) == 90000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 110000, 0);
    }
    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_and_rebalance(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account1_addr = signer::address_of(account1);

        deposit_internal<WETH,Asset>(account1, account1_addr, 100000, false);
        borrow_internal<WETH,Shadow>(account1_addr, 50000);
        deposit_internal<UNI,Shadow>(account1, account1_addr, 100000, false);
        borrow_internal<UNI,Asset>(account1_addr, 90000);
        borrow_unsafe_for_test<UNI,Asset>(account1_addr, 20000);
        assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 50000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 100000, 0);
        assert!(borrowed_asset<UNI>(account1_addr) == 110000, 0);

        borrow_and_rebalance_internal<WETH,UNI>(account1_addr, false);
        assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 60000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 110000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);

        deposit_internal<WETH,Asset>(account, account_addr, 700000, true);
        withdraw_internal<WETH,Asset>(account_addr, 600000, true);

        assert!(deposited_asset<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);

        deposit_internal<WETH,Shadow>(account, account_addr, 700000, false);
        withdraw_internal<WETH,Shadow>(account_addr, 600000, false);

        assert!(deposited_shadow<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);

        deposit_internal<WETH,Shadow>(account, account_addr, 700000, true);
        withdraw_internal<WETH,Shadow>(account_addr, 600000, true);

        assert!(deposited_shadow<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 100000, 0);
    }
}