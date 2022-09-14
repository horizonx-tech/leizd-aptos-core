module leizd::shadow_pool {

    use std::error;
    use std::signer;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_std::event;
    use aptos_framework::coin;
    use aptos_framework::type_info;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use leizd::usdz::{USDZ};
    use leizd::permission;
    use leizd::constant;
    use leizd::treasury;
    use leizd::stability_pool;
    use leizd::risk_factor;
    use leizd::pool_status;
    use leizd::interest_rate;


    friend leizd::money_market;

    const E_NOT_AVAILABLE_STATUS: u64 = 4;
    const E_AMOUNT_ARG_IS_ZERO: u64 = 5;
    const E_EXCEED_BORRAWABLE_AMOUNT: u64 = 6;

    struct Pool has key {
        shadow: coin::Coin<USDZ>
    }

    struct Storage has key {
        total_deposited: u128, // borrowable + collateral only
        total_conly_deposited: u128, // collateral only
        total_borrowed: u128,
        deposited: simple_map::SimpleMap<String,u64>, // borrowable + collateral only
        conly_deposited: simple_map::SimpleMap<String,u64>, // collateral only
        borrowed: simple_map::SimpleMap<String,u64>,
        last_updated: u64,
        protocol_fees: u64,
    }

    // Events
    struct DepositEvent has store, drop {
        caller: address,
        depositor: address,
        amount: u64,
        is_collateral_only: bool,
        is_shadow: bool,
    }

    struct WithdrawEvent has store, drop {
        caller: address,
        depositor: address,
        receiver: address,
        amount: u64,
        is_collateral_only: bool,
        is_shadow: bool,
    }
    
    struct BorrowEvent has store, drop {
        caller: address,
        borrower: address,
        receiver: address,
        amount: u64,
        is_shadow: bool,
    }
    
    struct RepayEvent has store, drop {
        caller: address,
        repayer: address,
        amount: u64,
        is_shadow: bool,
    }
    
    struct LiquidateEvent has store, drop {
        caller: address,
        target: address,
        is_shadow: bool,
    }
    
    struct PoolEventHandle has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
        liquidate_event: event::EventHandle<LiquidateEvent>,
    }

    public fun init_pool(owner: &signer) {
        init_pool_internal(owner);
    }

    fun init_pool_internal(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, Pool {
            shadow: coin::zero<USDZ>(),
        });
        move_to(owner, default_storage());
        move_to(owner, PoolEventHandle {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
            liquidate_event: account::new_event_handle<LiquidateEvent>(owner),
        })
    }

    public(friend) fun deposit_for<C>(
        account: &signer,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool
    ) acquires Pool, Storage, PoolEventHandle {
        deposit_for_internal<C>(account, depositor_addr, amount, is_collateral_only);
    }

    fun deposit_for_internal<C>(
        account: &signer,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::is_available<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_address);
        let pool_ref = borrow_global_mut<Pool>(owner_address);

        accrue_interest<C>(storage_ref);

        let key = generate_coin_key<C>();
        coin::merge(&mut pool_ref.shadow, coin::withdraw<USDZ>(account, amount));

        storage_ref.total_deposited = storage_ref.total_deposited + (amount as u128);
        if (simple_map::contains_key<String,u64>(&storage_ref.deposited, &key)) {
            let deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.deposited, &key);
            *deposited = *deposited + amount;
        } else {
            simple_map::add<String,u64>(&mut storage_ref.deposited, key, amount);
        };

        if (is_collateral_only) {
            storage_ref.total_conly_deposited = storage_ref.total_conly_deposited + (amount as u128);
            if (simple_map::contains_key<String,u64>(&storage_ref.conly_deposited, &key)) {
                let conly_deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.conly_deposited, &key);
                *conly_deposited = *conly_deposited + amount;
            } else {
                simple_map::add<String,u64>(&mut storage_ref.conly_deposited, key, amount);
            }
        };
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).deposit_event,
            DepositEvent {
                caller: signer::address_of(account),
                depositor: depositor_addr,
                amount,
                is_collateral_only,
                is_shadow: false,
            },
        );
    }

    public(friend) fun rebalance_shadow<C1,C2>(amount: u64, is_collateral_only: bool) acquires Storage {
        let key1 = generate_coin_key<C1>();
        let key2 = generate_coin_key<C2>();
        let storage_ref = borrow_global_mut<Storage>(permission::owner_address());
        assert!(simple_map::contains_key<String,u64>(&storage_ref.deposited, &key1), 0);
        assert!(simple_map::contains_key<String,u64>(&storage_ref.deposited, &key2), 0);

        let deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.deposited, &key1);
        *deposited = *deposited - amount;
        let deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.deposited, &key2);
        *deposited = *deposited + amount;

        if (is_collateral_only) {
            let conly_deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.conly_deposited, &key1);
            *conly_deposited = *conly_deposited - amount;
            let conly_deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.conly_deposited, &key2);
            *conly_deposited = *conly_deposited + amount;
        };

        // TODO: event
    }

    public(friend) fun borrow_and_rebalance<C1,C2>(amount: u64, is_collateral_only: bool) acquires Storage {
        let key1 = generate_coin_key<C1>();
        let key2 = generate_coin_key<C2>();
        let storage_ref = borrow_global_mut<Storage>(permission::owner_address());
        assert!(simple_map::contains_key<String,u64>(&storage_ref.borrowed, &key1), 0);
        assert!(simple_map::contains_key<String,u64>(&storage_ref.deposited, &key2), 0);

        let borrowed = simple_map::borrow_mut<String,u64>(&mut storage_ref.borrowed, &key1);
        *borrowed = *borrowed + amount;
        let deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.deposited, &key2);
        *deposited = *deposited + amount;

        if (is_collateral_only) {
            let conly_deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.conly_deposited, &key2);
            *conly_deposited = *conly_deposited + amount;
        };

        // TODO: event
    }

    public(friend) fun withdraw_for<C>(
        depositor_addr: address,
        reciever_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64
    ): u64 acquires Pool, Storage, PoolEventHandle {
        withdraw_for_internal<C>(
            depositor_addr,
            reciever_addr,
            amount,
            is_collateral_only,
            liquidation_fee
        )
    }

    fun withdraw_for_internal<C>(
        depositor_addr: address,
        reciever_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64
    ): u64 acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::is_available<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool>(owner_address);
        let storage_ref = borrow_global_mut<Storage>(owner_address);

        accrue_interest<C>(storage_ref);
        collect_shadow_fee<C>(pool_ref, liquidation_fee);

        let amount_to_transfer = amount - liquidation_fee;
        coin::deposit<USDZ>(reciever_addr, coin::extract(&mut pool_ref.shadow, amount_to_transfer));
        let withdrawn_amount;
        if (amount == constant::u64_max()) {
            if (is_collateral_only) {
                withdrawn_amount = storage_ref.total_conly_deposited;
            } else {
                withdrawn_amount = storage_ref.total_deposited;
            };
        } else {
            withdrawn_amount = (amount as u128);
        };

        storage_ref.total_deposited = storage_ref.total_deposited - (withdrawn_amount as u128);
        let key = generate_coin_key<C>();
        assert!(simple_map::contains_key<String,u64>(&storage_ref.deposited, &key), 0);
        let deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.deposited, &key);
        *deposited = *deposited - amount;

        if (is_collateral_only) {
            storage_ref.total_conly_deposited = storage_ref.total_conly_deposited - (withdrawn_amount as u128);
            assert!(simple_map::contains_key<String,u64>(&storage_ref.conly_deposited, &key),0);
            let conly_deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.conly_deposited, &key);
            *conly_deposited = *conly_deposited - amount;
        };

        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).withdraw_event,
            WithdrawEvent {
                caller: depositor_addr,
                depositor: depositor_addr,
                receiver: reciever_addr,
                amount,
                is_collateral_only,
                is_shadow: false
            },
        );
        (withdrawn_amount as u64)
    }

    public(friend) fun borrow_for<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::is_available<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool>(owner_address);
        let storage_ref = borrow_global_mut<Storage>(owner_address);

        accrue_interest<C>(storage_ref);

        let fee = calculate_entry_fee(amount);
        collect_shadow_fee<C>(pool_ref, fee);

        let key = generate_coin_key<C>();
        let remains = if (deposited_internal(key, storage_ref) > borrowed_internal(key, storage_ref)) deposited_internal(key, storage_ref) - borrowed_internal(key, storage_ref) else 0;
        if (amount > remains) {
            // use stability pool
            let insufficiencies = amount - remains;
            assert!(stability_pool::left() >= (insufficiencies as u128), error::invalid_argument(E_EXCEED_BORRAWABLE_AMOUNT)); // check the staiblity left
            borrow_from_stability_pool<C>(receiver_addr, insufficiencies);
            fee = fee + stability_pool::stability_fee_amount(insufficiencies);
            if (remains > 0) {
                // borrow from shadow_pool too if remains > 0
                let deposited = coin::extract_all(&mut pool_ref.shadow);
                coin::deposit<USDZ>(receiver_addr, deposited);
            }
        } else {
            let deposited = coin::extract(&mut pool_ref.shadow, amount);
            coin::deposit<USDZ>(receiver_addr, deposited);
        };
        let key = generate_coin_key<C>();
        storage_ref.total_borrowed = storage_ref.total_borrowed + (amount as u128) + (fee as u128);
        if (simple_map::contains_key<String,u64>(&storage_ref.borrowed, &key)) {
            let borrowed = simple_map::borrow_mut<String,u64>(&mut storage_ref.borrowed, &key);
            *borrowed = *borrowed + amount;
        } else {
            simple_map::add<String,u64>(&mut storage_ref.borrowed, key, amount);
        };
        
        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).borrow_event,
            BorrowEvent {
                caller: borrower_addr,
                borrower: borrower_addr,
                receiver: receiver_addr,
                amount,
                is_shadow: false
            },
        );
    }

    public(friend) fun repay<C>(
        account: &signer,
        amount: u64
    ): u64 acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::is_available<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_address);
        let pool_ref = borrow_global_mut<Pool>(owner_address);

        accrue_interest<C>(storage_ref);

        // at first, repay to stability_pool
        let repayed_to_stability_pool = repay_to_stability_pool<C>(account, amount);
        let to_shadow_pool = amount - repayed_to_stability_pool;
        if (to_shadow_pool > 0) {
            let withdrawn = coin::withdraw<USDZ>(account, to_shadow_pool);
            coin::merge(&mut pool_ref.shadow, withdrawn);
        };
        storage_ref.total_borrowed = storage_ref.total_borrowed - (amount as u128);
        let borrowed = simple_map::borrow_mut<String,u64>(&mut storage_ref.borrowed, &generate_coin_key<C>());
        *borrowed = *borrowed - amount;

        let account_addr = signer::address_of(account);
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).repay_event,
            RepayEvent {
                caller: account_addr,
                repayer: account_addr,
                amount,
                is_shadow: false
            },
        );
        amount
    }

    fun default_storage(): Storage {
        Storage {
            total_deposited: 0,
            total_conly_deposited: 0,
            total_borrowed: 0,
            deposited: simple_map::create<String,u64>(),
            conly_deposited: simple_map::create<String,u64>(),
            borrowed: simple_map::create<String,u64>(),
            last_updated: 0,
            protocol_fees: 0,
        }
    }

    /// Borrow the shadow from the stability pool
    /// use when shadow in this pool become insufficient.
    fun borrow_from_stability_pool<C>(receiver_addr: address, amount: u64) {
        let borrowed = stability_pool::borrow<C>(receiver_addr, amount);
        coin::deposit(receiver_addr, borrowed);
    }

    /// Repays the shadow to the stability pool
    /// use when shadow has already borrowed from this pool.
    /// @return repaid amount
    fun repay_to_stability_pool<C>(account: &signer, amount: u64): u64 {
        let borrowed = stability_pool::total_borrowed<C>();
        if (borrowed == 0) {
            return 0
        } else if (borrowed >= (amount as u128)) {
            stability_pool::repay<C>(account, amount);
            return amount
        } else {
            stability_pool::repay<C>(account, (borrowed as u64));
            return (borrowed as u64)
        }
    }

    /// This function is called on every user action.
    fun accrue_interest<C>(storage_ref: &mut Storage) {
        let now = timestamp::now_microseconds();

        // This is the first time
        if (storage_ref.last_updated == 0) {
            storage_ref.last_updated = now;
            return
        };

        if (storage_ref.last_updated == now) {
            return
        };

        let protocol_share_fee = risk_factor::share_fee();
        let rcomp = interest_rate::update_interest_rate<C>(
            storage_ref.total_deposited,
            storage_ref.total_borrowed,
            storage_ref.last_updated,
            now,
        );
        let accrued_interest = storage_ref.total_borrowed * rcomp / interest_rate::precision();
        let protocol_share = accrued_interest * (protocol_share_fee as u128) / interest_rate::precision();
        let new_protocol_fees = storage_ref.protocol_fees + (protocol_share as u64);

        let depositors_share = accrued_interest - protocol_share;
        storage_ref.total_borrowed = storage_ref.total_borrowed + accrued_interest;
        storage_ref.total_deposited = storage_ref.total_deposited + depositors_share;
        storage_ref.protocol_fees = new_protocol_fees;
        storage_ref.last_updated = now;
    }

    fun collect_shadow_fee<C>(pool_ref: &mut Pool, liquidation_fee: u64) {
        let fee_extracted = coin::extract(&mut pool_ref.shadow, liquidation_fee);
        treasury::collect_shadow_fee<C>(fee_extracted);
    }

    fun calculate_entry_fee(value: u64): u64 {
        value * risk_factor::entry_fee() / risk_factor::precision() // TODO: rounded up
    }

    public entry fun total_deposited(): u128 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).total_deposited
    }

    public entry fun liquidity(): u128 acquires Storage {
        let storage_ref = borrow_global<Storage>(permission::owner_address());
        storage_ref.total_deposited - storage_ref.total_conly_deposited
    }

    public entry fun total_conly_deposited(): u128 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).total_conly_deposited
    }

    public entry fun total_borrowed(): u128 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).total_borrowed
    }

    public entry fun deposited<C>(): u64 acquires Storage {
        let storage = borrow_global<Storage>(permission::owner_address());
        deposited_internal(generate_coin_key<C>(), storage)
    }
    fun deposited_internal(key: String, storage: &Storage): u64 {
        let deposited = storage.deposited;
        if (simple_map::contains_key<String,u64>(&deposited, &key)) {
            *simple_map::borrow<String,u64>(&deposited, &key)
        } else {
            0
        }
    }

    public entry fun conly_deposited<C>(): u64 acquires Storage {
        let key = generate_coin_key<C>();
        let conly_deposited = borrow_global<Storage>(permission::owner_address()).conly_deposited;
        if (simple_map::contains_key<String,u64>(&conly_deposited, &key)) {
            *simple_map::borrow<String,u64>(&conly_deposited, &key)
        } else {
            0
        }
    }

    public entry fun borrowed<C>(): u64 acquires Storage {
        let storage = borrow_global<Storage>(permission::owner_address());
        borrowed_internal(generate_coin_key<C>(), storage)
    }
    fun borrowed_internal(key: String, storage: &Storage): u64 {
        let borrowed = storage.borrowed;
        if (simple_map::contains_key<String,u64>(&borrowed, &key)) {
            *simple_map::borrow<String,u64>(&borrowed, &key)
        } else {
            0
        }
    }

    fun generate_coin_key<C>(): String {
        let coin_type = type_info::type_name<C>();
        coin_type
    }

    // #[test_only]
    // use aptos_std::debug;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::test_coin::{Self,WETH,UNI};
    #[test_only]
    use leizd::usdz;
    #[test_only]
    use leizd::initializer;
    #[test_only]
    use leizd::system_administrator;
    #[test_only]
    use leizd::asset_pool;
    #[test_only]
    use leizd::price_oracle;
    #[test_only]
    fun setup_for_test_to_initialize_coins_and_pools(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initializer::initialize(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        init_pool_internal(owner);
        asset_pool::init_pool<WETH>(owner);
        asset_pool::init_pool<UNI>(owner);
    }

    // for deposit
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<USDZ>(account);

        usdz::mint_for_test(account_addr, 1000000);
        assert!(coin::balance<USDZ>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH>(account, account_addr, 800000, false);
        assert!(coin::balance<USDZ>(account_addr) == 200000, 0);
        assert!(total_deposited() == 800000, 0);
        assert!(deposited<WETH>() == 800000, 0);
        assert!(liquidity() == 800000, 0);
        // TODO: liquidity for one asset
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<WETH>() == 0, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<DepositEvent>(&event_handle.deposit_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_with_same_as_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 100, false);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(total_deposited() == 100, 0);
        assert!(deposited<WETH>() == 100, 0);
        assert!(liquidity() == 100, 0);
        // TODO: liquidity for one asset
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<WETH>() == 0, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_deposit_with_more_than_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 101, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_more_than_once_sequentially_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<WETH>(account, account_addr, 10, false);
        timestamp::update_global_time_for_test((initial_sec + 90) * 1000 * 1000); // + 90 sec
        deposit_for_internal<WETH>(account, account_addr, 20, false);
        timestamp::update_global_time_for_test((initial_sec + 180) * 1000 * 1000); // + 90 sec
        deposit_for_internal<WETH>(account, account_addr, 30, false);
        assert!(coin::balance<USDZ>(account_addr) == 40, 0);
        assert!(total_deposited() == 60, 0);
        assert!(deposited<WETH>() == 60, 0);
        assert!(liquidity() == 60, 0);
        // TODO: liquidity for one asset
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<WETH>() == 0, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<WETH>(account);
        initializer::register<USDZ>(account);

        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 800000, true);
        assert!(coin::balance<USDZ>(account_addr) == 200000, 0);
        assert!(total_deposited() == 800000, 0);
        assert!(deposited<WETH>() == 800000, 0);
        assert!(liquidity() == 0, 0);
        // TODO: liquidity for one asset
        assert!(total_conly_deposited() == 800000, 0);
        assert!(conly_deposited<WETH>() == 800000, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 700000, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 600000, false, 0);

        assert!(coin::balance<USDZ>(account_addr) == 900000, 0);
        assert!(total_deposited() == 100000, 0);
        assert!(deposited<WETH>() == 100000, 0);
        assert!(liquidity() == 100000, 0);
        // TODO: liquidity for one asset
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<WETH>() == 0, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_same_as_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 100, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 100, false, 0);

        assert!(coin::balance<USDZ>(account_addr) == 100, 0);
        assert!(total_deposited() == 0, 0);
        assert!(deposited<WETH>() == 0, 0);
        assert!(liquidity() == 0, 0);
        // TODO: liquidity for one asset
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<WETH>() == 0, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 100, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 101, false, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_more_than_once_sequentially_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<WETH>(account, account_addr, 100, false);
        timestamp::update_global_time_for_test((initial_sec + 330) * 1000 * 1000); // + 5.5 min
        withdraw_for_internal<WETH>(account_addr, account_addr, 10, false, 0);
        timestamp::update_global_time_for_test((initial_sec + 660) * 1000 * 1000); // + 5.5 min
        withdraw_for_internal<WETH>(account_addr, account_addr, 20, false, 0);
        timestamp::update_global_time_for_test((initial_sec + 990) * 1000 * 1000); // + 5.5 min
        withdraw_for_internal<WETH>(account_addr, account_addr, 30, false, 0);

        assert!(coin::balance<USDZ>(account_addr) == 60, 0);
        assert!(total_deposited() == 40, 0);
        assert!(deposited<WETH>() == 40, 0);
        assert!(liquidity() == 40, 0);
        // TODO: liquidity for one asset
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<WETH>() == 0, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 700000, true);
        withdraw_for_internal<WETH>(account_addr, account_addr, 600000, true, 0);

        assert!(coin::balance<USDZ>(account_addr) == 900000, 0);
        assert!(total_deposited() == 100000, 0);
        assert!(deposited<WETH>() == 100000, 0);
        assert!(liquidity() == 0, 0);
        // TODO: liquidity for one asset
        assert!(total_conly_deposited() == 100000, 0);
        assert!(conly_deposited<WETH>() == 100000, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
    }

    // for borrow
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1000000);

        // deposit
        deposit_for_internal<UNI>(depositor, depositor_addr, 800000, false);

        // borrow
        borrow_for<UNI>(borrower_addr, borrower_addr, 100000);
        assert!(coin::balance<USDZ>(borrower_addr) == 100000, 0);
        assert!(total_deposited() == 800000, 0);
        assert!(deposited<UNI>() == 800000, 0);
        assert!(liquidity() == 800000, 0);
        // TODO: liquidity for one asset
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<UNI>() == 0, 0);
        assert!(total_borrowed() == 100500, 0);
        assert!(borrowed<UNI>() == 100000, 0); // TODO: confirm

        // check about fee
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(treasury::balance_of_shadow<UNI>() == 500, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<BorrowEvent>(&event_handle.borrow_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_with_same_as_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1005);

        // deposit
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);

        // borrow
        borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(coin::balance<USDZ>(borrower_addr) == 1000, 0);
        assert!(total_deposited() == 1005, 0);
        assert!(deposited<UNI>() == 1005, 0);
        assert!(liquidity() == 1005, 0);
        // TODO: liquidity for one asset
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<UNI>() == 0, 0);
        assert!(total_borrowed() == 1005, 0);
        assert!(borrowed<UNI>() == 1000, 0); // TODO: confirm

        // check about fee
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(treasury::balance_of_shadow<UNI>() == 5, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_borrow_with_more_than_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1005);

        // deposit
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);

        // borrow
        borrow_for<UNI>(borrower_addr, borrower_addr, 1001); // NOTE: consider fee
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 100);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        // borrow UNI
        borrow_for<UNI>(borrower_addr, borrower_addr, 10);
        assert!(coin::balance<USDZ>(borrower_addr) == 10, 0);
        borrow_for<UNI>(borrower_addr, borrower_addr, 20);
        assert!(coin::balance<USDZ>(borrower_addr) == 30, 0);
        borrow_for<UNI>(borrower_addr, borrower_addr, 30);
        assert!(coin::balance<USDZ>(borrower_addr) == 60, 0);
        borrow_for<UNI>(borrower_addr, borrower_addr, 40);
        assert!(coin::balance<USDZ>(borrower_addr) == 100, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 100);

        let initial_sec = 1648738800; // 20220401T00:00:00
        // deposit UNI
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        // borrow UNI
        timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 10);
        assert!(coin::balance<USDZ>(borrower_addr) == 10, 0);
        timestamp::update_global_time_for_test((initial_sec + 500) * 1000 * 1000); // + 250 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 20);
        assert!(coin::balance<USDZ>(borrower_addr) == 30, 0);
        timestamp::update_global_time_for_test((initial_sec + 750) * 1000 * 1000); // + 250 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 30);
        assert!(coin::balance<USDZ>(borrower_addr) == 60, 0);
        timestamp::update_global_time_for_test((initial_sec + 1000) * 1000 * 1000); // + 250 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 40);
        assert!(coin::balance<USDZ>(borrower_addr) == 100, 0);
    }

    // for repay
    #[test_only]
    fun pool_shadow_value(addr: address): u64 acquires Pool {
        coin::value(&borrow_global<Pool>(addr).shadow)
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        usdz::mint_for_test(depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        assert!(pool_shadow_value(owner_address) == 1005, 0);
        assert!(borrowed<UNI>() == 0, 0);
        borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(pool_shadow_value(owner_address) == 0, 0);
        assert!(borrowed<UNI>() == 1000, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 1000, 0);
        let repaid_amount = repay<UNI>(borrower, 900);
        assert!(repaid_amount == 900, 0);
        assert!(pool_shadow_value(owner_address) == 900, 0);
        assert!(borrowed<UNI>() == 100, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 100, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_with_same_as_total_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        usdz::mint_for_test(depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
        let repaid_amount = repay<UNI>(borrower, 1000);
        assert!(repaid_amount == 1000, 0);
        assert!(pool_shadow_value(owner_address) == 1000, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_repay_with_more_than_total_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        usdz::mint_for_test(depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        borrow_for<UNI>(borrower_addr, borrower_addr, 250);
        repay<UNI>(borrower, 251);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        usdz::mint_for_test(depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        assert!(pool_shadow_value(owner_address) == 1005, 0);
        borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(pool_shadow_value(owner_address) == 0, 0);
        let repaid_amount = repay<UNI>(borrower, 100);
        assert!(repaid_amount == 100, 0);
        assert!(pool_shadow_value(owner_address) == 100, 0);
        assert!(borrowed<UNI>() == 900, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 900, 0);
        let repaid_amount = repay<UNI>(borrower, 200);
        assert!(repaid_amount == 200, 0);
        assert!(pool_shadow_value(owner_address) == 300, 0);
        assert!(borrowed<UNI>() == 700, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 700, 0);
        let repaid_amount = repay<UNI>(borrower, 300);
        assert!(repaid_amount == 300, 0);
        assert!(pool_shadow_value(owner_address) == 600, 0);
        assert!(borrowed<UNI>() == 400, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 400, 0);
        let repaid_amount = repay<UNI>(borrower, 400);
        assert!(repaid_amount == 400, 0);
        assert!(pool_shadow_value(owner_address) == 1000, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 4, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        usdz::mint_for_test(depositor_addr, 1005);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        assert!(pool_shadow_value(owner_address) == 1005, 0);
        timestamp::update_global_time_for_test((initial_sec + 80) * 1000 * 1000); // + 80 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(pool_shadow_value(owner_address) == 0, 0);

        timestamp::update_global_time_for_test((initial_sec + 160) * 1000 * 1000); // + 80 sec
        let repaid_amount = repay<UNI>(borrower, 100);
        assert!(repaid_amount == 100, 0);
        assert!(pool_shadow_value(owner_address) == 100, 0);
        assert!(borrowed<UNI>() == 900, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 900, 0);
        timestamp::update_global_time_for_test((initial_sec + 240) * 1000 * 1000); // + 80 sec
        let repaid_amount = repay<UNI>(borrower, 200);
        assert!(repaid_amount == 200, 0);
        assert!(pool_shadow_value(owner_address) == 300, 0);
        assert!(borrowed<UNI>() == 700, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 700, 0);
        timestamp::update_global_time_for_test((initial_sec + 320) * 1000 * 1000); // + 80 sec
        let repaid_amount = repay<UNI>(borrower, 300);
        assert!(repaid_amount == 300, 0);
        assert!(pool_shadow_value(owner_address) == 600, 0);
        assert!(borrowed<UNI>() == 400, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 400, 0);
        timestamp::update_global_time_for_test((initial_sec + 400) * 1000 * 1000); // + 80 sec
        let repaid_amount = repay<UNI>(borrower, 400);
        assert!(repaid_amount == 400, 0);
        assert!(pool_shadow_value(owner_address) == 1000, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 4, 0);
    }

    // for with stability_pool
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_from_stability_pool(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1000);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 500);
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        assert!(pool_shadow_value(owner_addr) == 100, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 500, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
        //// from only shadow_pool
        borrow_for<UNI>(borrower_addr, borrower_addr, 50);
        assert!(pool_shadow_value(owner_addr) == 50, 0);
        assert!(borrowed<UNI>() == 50, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 500, 0);
        assert!(usdz::balance_of(borrower_addr) == 50, 0);
        //// from both
        borrow_for<UNI>(borrower_addr, borrower_addr, 100);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == 150, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 50, 0);
        assert!(stability_pool::left() == 450, 0);
        assert!(usdz::balance_of(borrower_addr) == 150, 0);
        //// from only stability_pool
        borrow_for<UNI>(borrower_addr, borrower_addr, 150);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == 300, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 200, 0);
        assert!(stability_pool::left() == 300, 0);
        assert!(usdz::balance_of(borrower_addr) == 300, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_with_stability_pool_to_borrow_with_cannot_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1000);

        // execute
        stability_pool::deposit(depositor, 15);
        deposit_for_internal<UNI>(depositor, depositor_addr, 25, false);

        borrow_for<UNI>(borrower_addr, borrower_addr, 41);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_from_stability_pool_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1000);

        // execute
        let initial_sec = 1648738800; // 20220401T00:00:00
        //// prepares
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        stability_pool::deposit(depositor, 500);
        timestamp::update_global_time_for_test((initial_sec + 24) * 1000 * 1000); // + 24 sec
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        assert!(pool_shadow_value(owner_addr) == 100, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 500, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
        //// from only shadow_pool
        timestamp::update_global_time_for_test((initial_sec + 48) * 1000 * 1000); // + 24 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 50);
        assert!(pool_shadow_value(owner_addr) == 50, 0);
        assert!(borrowed<UNI>() == 50, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 500, 0);
        assert!(usdz::balance_of(borrower_addr) == 50, 0);
        //// from both
        timestamp::update_global_time_for_test((initial_sec + 72) * 1000 * 1000); // + 24 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 100);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == 150, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 50, 0);
        assert!(stability_pool::left() == 450, 0);
        assert!(usdz::balance_of(borrower_addr) == 150, 0);
        //// from only stability_pool
        timestamp::update_global_time_for_test((initial_sec + 96) * 1000 * 1000); // + 24 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 150);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == 300, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 200, 0);
        assert!(stability_pool::left() == 300, 0);
        assert!(usdz::balance_of(borrower_addr) == 300, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_to_stability_pool(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1000);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 500);
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        borrow_for<UNI>(borrower_addr, borrower_addr, 150);
        borrow_for<UNI>(borrower_addr, borrower_addr, 150); // TODO: for not to consider fee
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == 300, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 200, 0);
        assert!(stability_pool::left() == 300, 0);
        assert!(usdz::balance_of(borrower_addr) == 300, 0);
        //// from only stability_pool
        repay<UNI>(borrower, 180);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == 120, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 20, 0);
        assert!(stability_pool::left() == 480, 0);
        assert!(usdz::balance_of(borrower_addr) == 120, 0);
        //// from both
        repay<UNI>(borrower, 100);
        assert!(pool_shadow_value(owner_addr) == 80, 0);
        assert!(borrowed<UNI>() == 20, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 500, 0);
        assert!(usdz::balance_of(borrower_addr) == 20, 0);
        //// from only shadow_pool
        repay<UNI>(borrower, 20);
        assert!(pool_shadow_value(owner_addr) == 100, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 500, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_to_stability_pool_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1000);

        // execute
        let initial_sec = 1648738800; // 20220401T00:00:00
        //// prepares
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        stability_pool::deposit(depositor, 500);
        timestamp::update_global_time_for_test((initial_sec + 11) * 1000 * 1000); // + 11 sec
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        timestamp::update_global_time_for_test((initial_sec + 22) * 1000 * 1000); // + 11 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 150);
        timestamp::update_global_time_for_test((initial_sec + 33) * 1000 * 1000); // + 11 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 150); // TODO: for not to consider fee
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == 300, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 200, 0);
        assert!(stability_pool::left() == 300, 0);
        assert!(usdz::balance_of(borrower_addr) == 300, 0);
        //// from only stability_pool
        timestamp::update_global_time_for_test((initial_sec + 44) * 1000 * 1000); // + 11 sec
        repay<UNI>(borrower, 180);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == 120, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 20, 0);
        assert!(stability_pool::left() == 480, 0);
        assert!(usdz::balance_of(borrower_addr) == 120, 0);
        //// from both
        timestamp::update_global_time_for_test((initial_sec + 55) * 1000 * 1000); // + 11 sec
        repay<UNI>(borrower, 100);
        assert!(pool_shadow_value(owner_addr) == 80, 0);
        assert!(borrowed<UNI>() == 20, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 500, 0);
        assert!(usdz::balance_of(borrower_addr) == 20, 0);
        //// from only shadow_pool
        timestamp::update_global_time_for_test((initial_sec + 66) * 1000 * 1000); // + 11 sec
        repay<UNI>(borrower, 20);
        assert!(pool_shadow_value(owner_addr) == 100, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 500, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_open_position_more_than_once(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 1000);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 500);
        //// 1st
        borrow_for<UNI>(borrower_addr, borrower_addr, 25);
        repay<UNI>(borrower, 25);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        //// 2nd
        borrow_for<UNI>(borrower_addr, borrower_addr, 50);
        borrow_for<UNI>(borrower_addr, borrower_addr, 75);
        repay<UNI>(borrower, 110);
        repay<UNI>(borrower, 15);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        //// 3rd
        borrow_for<UNI>(borrower_addr, borrower_addr, 15);
        repay<UNI>(borrower, 10);
        borrow_for<UNI>(borrower_addr, borrower_addr, 30);
        repay<UNI>(borrower, 25);
        borrow_for<UNI>(borrower_addr, borrower_addr, 45);
        repay<UNI>(borrower, 40);
        repay<UNI>(borrower, 15);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        //// still open position
        borrow_for<UNI>(borrower_addr, borrower_addr, 50); // TODO: fail if pattern that fee > 0 (amount > ?)
        assert!(stability_pool::total_borrowed<UNI>() == 50, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower1=@0x222,borrower2=@0x333,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_open_multi_position(owner: &signer, depositor: &signer, borrower1: &signer, borrower2: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower1_addr = signer::address_of(borrower1);
        let borrower2_addr = signer::address_of(borrower2);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower1_addr);
        account::create_account_for_test(borrower2_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower1);
        managed_coin::register<USDZ>(borrower2);
        usdz::mint_for_test(depositor_addr, 1000);

        // execute
        stability_pool::deposit(depositor, 100);
        deposit_for_internal<WETH>(depositor, depositor_addr, 25, false);
        //// borrow
        borrow_for<WETH>(borrower1_addr, borrower1_addr, 30);
        borrow_for<WETH>(borrower2_addr, borrower2_addr, 20);
        borrow_for<UNI>(borrower2_addr, borrower2_addr, 40);
        assert!(stability_pool::left() == 35, 0);
        assert!(stability_pool::total_borrowed<WETH>() == 25, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 40, 0);
        //// repay
        repay<UNI>(depositor, 40);
        assert!(stability_pool::total_borrowed<WETH>() == 25, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
        repay<WETH>(depositor, 25);
        assert!(stability_pool::total_borrowed<WETH>() == 0, 0);
        assert!(stability_pool::total_borrowed<UNI>() == 0, 0);
    }

    // rebalance shadow
    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_rebalance_shadow(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        initializer::register<WETH>(account1);
        initializer::register<UNI>(account1);
        initializer::register<USDZ>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        usdz::mint_for_test(account1_addr, 1000000);

        deposit_for_internal<WETH>(account1, account1_addr, 100000, false);
        deposit_for_internal<UNI>(account1, account1_addr, 100000, false);
        assert!(deposited<WETH>() == 100000, 0);
        assert!(deposited<UNI>() == 100000, 0);

        rebalance_shadow<WETH,UNI>(10000, false);
        assert!(deposited<WETH>() == 90000, 0);
        assert!(deposited<UNI>() == 110000, 0);
    }
    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_and_rebalance(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        initializer::register<USDZ>(owner);
        initializer::register<USDZ>(account1);
        usdz::mint_for_test(owner_addr, 1000000);
        usdz::mint_for_test(account1_addr, 1000000);

        // execute
        //// prepares
        deposit_for_internal<WETH>(owner, owner_addr, 100000, false);
        deposit_for_internal<UNI>(account1, account1_addr, 100000, false);
        borrow_for<WETH>(account1_addr, account1_addr, 50000);
        assert!(borrowed<WETH>() == 50000, 0);
        assert!(deposited<UNI>() == 100000, 0);

        borrow_and_rebalance<WETH,UNI>(10000, false);
        assert!(borrowed<WETH>() == 60000, 0);
        assert!(deposited<UNI>() == 110000, 0);
    }

    // for common validations
    //// `amount` arg
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_cannot_deposit_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_cannot_withdraw_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal<WETH>(owner_address, owner_address, 0, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_cannot_borrow_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_address = signer::address_of(owner);
        borrow_for<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_cannot_repay_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        repay<WETH>(owner, 0);
    }
    //// control pool status
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_deposit_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::pause_pool<WETH>(owner);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_withdraw_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::pause_pool<WETH>(owner);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal<WETH>(owner_address, owner_address, 0, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_borrow_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::pause_pool<WETH>(owner);
        let owner_address = signer::address_of(owner);
        borrow_for<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_repay_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::pause_pool<WETH>(owner);
        repay<WETH>(owner, 0);
    }
}