module leizd::account_position {

    use std::error;
    use std::signer;
    use std::vector;
    use std::string::{String};
    use aptos_std::event;
    use aptos_std::simple_map;
    use aptos_framework::type_info;
    use leizd::pool_type;
    use leizd::position_type::{Self,AssetToShadow,ShadowToAsset};
    use leizd::price_oracle;
    use leizd::risk_factor;

    friend leizd::money_market;

    const ENO_SAFE_POSITION: u64 = 0;
    // const ENO_UNSAFE_POSITION: u64 = 1;
    // const ENOT_ENOUGH_SHADOW: u64 = 2;
    const ENOT_EXISTED: u64 = 3;
    const EALREADY_PROTECTED: u64 = 4;
    const EOVER_DEPOSITED_AMOUNT: u64 = 5;
    const EOVER_BORROWED_AMOUNT: u64 = 6;

    /// P: The position type - AssetToShadow or ShadowToAsset.
    struct Position<phantom P> has key {
        coins: vector<String>, // e.g. 0x1::module_name::WBTC
        protected_coins: simple_map::SimpleMap<String,bool>, // e.g. 0x1::module_name::WBTC - true
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

    public(friend) fun deposit<C,P>(account: &signer, depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        deposit_internal<C,P>(account, depositor_addr, amount, is_collateral_only);
    }

    fun deposit_internal<C,P>(account: &signer, depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        initialize_if_necessary(account);
        assert!(exists<Position<AssetToShadow>>(depositor_addr), 0);

        if (pool_type::is_type_asset<P>()) {
            update_position<C,AssetToShadow>(depositor_addr, amount, true, true, is_collateral_only);
        } else {
            update_position<C,ShadowToAsset>(depositor_addr, amount, true, true, is_collateral_only);
        };
    }

    public(friend) fun withdraw<C,P>(depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        withdraw_internal<C,P>(depositor_addr, amount, is_collateral_only);
    }

    fun withdraw_internal<C,P>(depositor_addr: address, amount: u64, is_collateral_only: bool) acquires Position, AccountPositionEventHandle {
        if (pool_type::is_type_asset<P>()) {
            update_position<C,AssetToShadow>(depositor_addr, amount, true, false, is_collateral_only);
            assert!(is_safe<C,AssetToShadow>(depositor_addr), error::invalid_state(ENO_SAFE_POSITION));
        } else {
            update_position<C,ShadowToAsset>(depositor_addr, amount, true, false, is_collateral_only);
            assert!(is_safe<C,ShadowToAsset>(depositor_addr), error::invalid_state(ENO_SAFE_POSITION));
        };
    }

    public(friend) fun borrow<C,P>(addr: address, amount: u64) acquires Position, AccountPositionEventHandle {
        borrow_internal<C,P>(addr, amount);
    }

    fun borrow_internal<C,P>(borrower_addr: address, amount: u64) acquires Position, AccountPositionEventHandle {
        if (pool_type::is_type_asset<P>()) {
            update_position<C,ShadowToAsset>(borrower_addr, amount, false, true, false);
            assert!(is_safe<C,ShadowToAsset>(borrower_addr), error::invalid_state(ENO_SAFE_POSITION));
        } else {
            update_position<C,AssetToShadow>(borrower_addr, amount, false, true, false);
            assert!(is_safe<C,AssetToShadow>(borrower_addr), error::invalid_state(ENO_SAFE_POSITION));
        };
    }

    public(friend) fun repay<C,P>(addr: address, amount: u64) acquires Position, AccountPositionEventHandle {
        if (pool_type::is_type_asset<P>()) {
            update_position<C,ShadowToAsset>(addr, amount, false, false, false);
        } else {
            update_position<C,AssetToShadow>(addr, amount, false, false, false);
        };
    }

    public(friend) fun rebalance_shadow<C1,C2>(addr: address, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle {
        rebalance_shadow_internal<C1,C2>(addr, is_collateral_only)
    }

    fun rebalance_shadow_internal<C1,C2>(addr: address, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle {
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

    public(friend) fun borrow_and_rebalance<C1,C2>(addr: address, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle {
        borrow_and_rebalance_internal<C1,C2>(addr, is_collateral_only)
    }

    fun borrow_and_rebalance_internal<C1,C2>(addr: address, is_collateral_only: bool): u64 acquires Position, AccountPositionEventHandle {
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
    ) acquires Position, AccountPositionEventHandle {
        let key = generate_key<C>();
        let position_ref = borrow_global_mut<Position<P>>(addr);

        if (vector::contains<String>(&position_ref.coins, &key)) {
            if (is_deposit && is_increase) {
                // Deposit 
                let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
                balance_ref.deposited = balance_ref.deposited + amount;
                if (is_collateral_only) {
                    balance_ref.conly_deposited = balance_ref.conly_deposited + amount;
                };
                emit_update_position_event<P>(addr, key, balance_ref);
            } else if (is_deposit && !is_increase) {
                // Withdraw
                let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
                assert!(balance_ref.deposited >= amount, error::invalid_argument(EOVER_DEPOSITED_AMOUNT));
                balance_ref.deposited = balance_ref.deposited - amount;
                if (is_collateral_only) {
                    balance_ref.conly_deposited = balance_ref.conly_deposited - amount;
                };
                emit_update_position_event<P>(addr, key, balance_ref);
                remove_balance_if_unused<P>(addr, key);
            } else if (!is_deposit && is_increase) {
                // Borrow
                let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
                balance_ref.borrowed = balance_ref.borrowed + amount;
                emit_update_position_event<P>(addr, key, balance_ref);
            } else {
                // Repay
                let balance_ref = simple_map::borrow_mut<String,Balance>(&mut position_ref.balance, &key);
                assert!(balance_ref.borrowed >= amount, error::invalid_argument(EOVER_BORROWED_AMOUNT));
                balance_ref.borrowed = balance_ref.borrowed - amount;
                emit_update_position_event<P>(addr, key, balance_ref);
                remove_balance_if_unused<P>(addr, key);
            }
        } else {
            new_position<P>(addr, amount, is_deposit, is_collateral_only, key);
        };
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

    fun new_position<P>(addr: address, amount: u64, is_deposit: bool, is_collateral_only: bool, key: String) acquires Position, AccountPositionEventHandle {
        assert!(is_deposit, 0);
        let position_ref = borrow_global_mut<Position<P>>(addr);
        vector::push_back<String>(&mut position_ref.coins, key);

        let conly_amount = if (is_collateral_only) amount else 0;
        simple_map::add<String,Balance>(&mut position_ref.balance, key, Balance {
            deposited: amount,
            conly_deposited: conly_amount,
            borrowed: 0,
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

    // #[test_only]
    // use aptos_framework::debug;
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
    fun borrow_unsafe_for_test<C,P>(borrower_addr: address, amount: u64) acquires Position, AccountPositionEventHandle {
        if (pool_type::is_type_asset<P>()) {
            update_position<C,ShadowToAsset>(borrower_addr, amount, false, true, false);
        } else {
            update_position<C,AssetToShadow>(borrower_addr, amount, false, true, false);
        };
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 800000, false);
        assert!(deposited_asset<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_by_two(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        deposit_internal<WETH,Asset>(account1, account1_addr, 800000, false);
        deposit_internal<WETH,Asset>(account2, account2_addr, 200000, false);
        assert!(deposited_asset<WETH>(account1_addr) == 800000, 0);
        assert!(deposited_asset<WETH>(account2_addr) == 200000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 800000, true);
        assert!(deposited_asset<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 800000, false);
        assert!(deposited_shadow<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 800000, true);
        assert!(deposited_shadow<WETH>(account_addr) == 800000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 800000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_with_all_patterns(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

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
    public entry fun test_withdraw_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 700000, false);
        withdraw_internal<WETH,Asset>(account_addr, 600000, false);
        assert!(deposited_asset<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_same_as_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 30, false);
        withdraw_internal<WETH,Asset>(account_addr, 30, false);
        assert!(deposited_asset<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 30, false);
        withdraw_internal<WETH,Asset>(account_addr, 31, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Asset>(account, account_addr, 700000, true);
        withdraw_internal<WETH,Asset>(account_addr, 600000, true);

        assert!(deposited_asset<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_asset<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 700000, false);
        withdraw_internal<WETH,Shadow>(account_addr, 600000, false);

        assert!(deposited_shadow<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 700000, true);
        withdraw_internal<WETH,Shadow>(account_addr, 600000, true);

        assert!(deposited_shadow<WETH>(account_addr) == 100000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 100000, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_all_patterns(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

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

    // for borrow
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_unsafe(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 1, false); // for generating Position
        borrow_unsafe_for_test<WETH,Asset>(account_addr, 10);
        assert!(deposited_shadow<WETH>(account_addr) == 1, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 10, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_asset(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
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
        let weth_key = generate_key<WETH>();
        assert!(deposited_shadow<WETH>(account_addr) == deposit_amount, 0);
        assert!(deposited_volume<ShadowToAsset>(account_addr, weth_key) == deposit_amount, 0);
        assert!(borrowed_asset<WETH>(account_addr) == borrow_amount, 0);
        assert!(borrowed_volume<ShadowToAsset>(account_addr, weth_key) == borrow_amount, 0);
        //// calcurate
        let utilization = utilization_of<ShadowToAsset>(borrow_global<Position<ShadowToAsset>>(account_addr), generate_key<WETH>());
        assert!(lt - utilization == (10000 - borrow_amount) * risk_factor::precision() / deposit_amount, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let weth_key = generate_key<WETH>();
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
        //// calcurate
        let utilization = utilization_of<AssetToShadow>(borrow_global<Position<AssetToShadow>>(account_addr), weth_key);
        assert!(lt - utilization == (7000 - borrow_amount) * risk_factor::precision() / deposit_amount, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196608)]
    public entry fun test_borrow_asset_when_over_borrowable(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 100 / 100, 0); // 100%

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account_addr, 10000);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196608)]
    public entry fun test_borrow_shadow_when_over_borrowable(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let weth_key = generate_key<WETH>();
        let lt = risk_factor::lt_of(weth_key);
        assert!(lt == risk_factor::precision() * 70 / 100, 0); // 70%

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account_addr, 7000);
    }

    // repay
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_repay(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        deposit_internal<WETH,Shadow>(account, account_addr, 1000, false); // for generating Position
        borrow_internal<WETH,Asset>(account_addr, 500);
        repay<WETH,Asset>(account_addr, 250);
        assert!(deposited_shadow<WETH>(account_addr) == 1000, 0);
        assert!(conly_deposited_shadow<WETH>(account_addr) == 0, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 250, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_repay_asset(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let lt = risk_factor::lt_of_shadow();
        assert!(lt == risk_factor::precision() * 100 / 100, 0); // 100%

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account_addr, 9999);
        repay<WETH,Asset>(account_addr, 9999);
        let weth_key = generate_key<WETH>();
        assert!(deposited_shadow<WETH>(account_addr) == 10000, 0);
        assert!(deposited_volume<ShadowToAsset>(account_addr, weth_key) == 10000, 0);
        assert!(borrowed_asset<WETH>(account_addr) == 0, 0);
        assert!(borrowed_volume<ShadowToAsset>(account_addr, weth_key) == 0, 0);
        //// calcurate
        assert!(utilization_of<ShadowToAsset>(borrow_global<Position<ShadowToAsset>>(account_addr), generate_key<WETH>()) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_repay_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // check prerequisite
        let weth_key = generate_key<WETH>();
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
        //// calcurate
        assert!(utilization_of<AssetToShadow>(borrow_global<Position<AssetToShadow>>(account_addr), weth_key) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_repay_asset_when_over_borrowed(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Shadow>(account, account_addr, 10000, false);
        borrow_internal<WETH,Asset>(account_addr, 9999);
        repay<WETH,Asset>(account_addr, 10000);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_repay_shadow_when_over_borrowed(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        borrow_internal<WETH,Shadow>(account_addr, 6999);
        repay<WETH,Shadow>(account_addr, 7000);
    }

    // mixture
    //// check existence of resources
    ////// withdraw all -> re-deposit (borrowable / asset)
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_check_existence_of_position_when_withdraw_asset(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let coin_key = generate_key<WETH>();
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
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_check_existence_of_position_when_withdraw_shadow_collateral_only(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let coin_key = generate_key<UNI>();
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
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_check_existence_of_position_when_repay_asset(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let coin_key = generate_key<UNI>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // prepares (temp)
        initialize_if_necessary(account);
        new_position<AssetToShadow>(account_addr, 0, true, false, coin_key);

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
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_check_existence_of_position_when_repay_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let coin_key = generate_key<WETH>();
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // prepares (temp)
        initialize_if_necessary(account);
        new_position<ShadowToAsset>(account_addr, 0, true, false, coin_key);

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
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_and_withdraw_more_than_once_sequentially(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        // execute
        deposit_internal<WETH,Asset>(account, account_addr, 10000, false);
        withdraw_internal<WETH,Asset>(account_addr, 10000, false);
        deposit_internal<WETH,Asset>(account, account_addr, 2000, false);
        deposit_internal<WETH,Asset>(account, account_addr, 3000, false);
        withdraw_internal<WETH,Asset>(account_addr, 1000, false);
        withdraw_internal<WETH,Asset>(account_addr, 4000, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_and_repay_more_than_once_sequentially(owner: &signer, account: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
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
    }

    // rebalance shadow
    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_rebalance_shadow(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
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

        rebalance_shadow_internal<WETH,UNI>(account1_addr, false);
        assert!(deposited_shadow<WETH>(account1_addr) == 90000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 110000, 0);
    }
    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_and_rebalance(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Position, AccountPositionEventHandle {
        setup_for_test_to_initialize_coins(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);
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

        borrow_and_rebalance_internal<WETH,UNI>(account1_addr, false);
        assert!(deposited_asset<WETH>(account1_addr) == 100000, 0);
        assert!(borrowed_shadow<WETH>(account1_addr) == 60000, 0);
        assert!(deposited_shadow<UNI>(account1_addr) == 110000, 0);
    }
}