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
    use leizd_aptos_common::permission;
    use leizd_aptos_lib::constant;
    use leizd_aptos_trove::usdz::{USDZ};
    use leizd::treasury;
    use leizd::stability_pool;
    use leizd::risk_factor;
    use leizd::pool_status;
    use leizd::interest_rate;

    friend leizd::money_market;

    const E_NOT_AVAILABLE_STATUS: u64 = 4;
    const E_NOT_INITIALIZED_COIN: u64 = 5;
    const E_AMOUNT_ARG_IS_ZERO: u64 = 11;
    const E_EXCEED_BORROWABLE_AMOUNT: u64 = 12;

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
        receiver: address,
        amount: u64,
        is_collateral_only: bool,
    }

    struct WithdrawEvent has store, drop {
        caller: address,
        receiver: address,
        amount: u64,
        is_collateral_only: bool,
    }

    struct BorrowEvent has store, drop {
        caller: address,
        borrower: address,
        receiver: address,
        amount: u64,
    }

    struct RepayEvent has store, drop {
        caller: address,
        repay_target: address,
        amount: u64,
    }

    struct LiquidateEvent has store, drop {
        caller: address,
        target: address,
        amount: u64,
    }

    struct RebalanceEvent has store, drop {
        // caller: address, // TODO: judge use or not use
        from: String,
        to: String,
        amount: u64,
        is_collateral_only_from: bool,
        is_collateral_only_to: bool,
        with_borrow: bool,
    }

    struct PoolEventHandle has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
        liquidate_event: event::EventHandle<LiquidateEvent>,
        rebalance_event: event::EventHandle<RebalanceEvent>,
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
            rebalance_event: account::new_event_handle<RebalanceEvent>(owner),
        })
    }

    public(friend) fun deposit_for<C>(
        account: &signer,
        for_address: address, // TODO: use to control target deposited
        amount: u64,
        is_collateral_only: bool
    ) acquires Pool, Storage, PoolEventHandle {
        deposit_for_internal<C>(account, for_address, amount, is_collateral_only);
    }

    fun deposit_for_internal<C>(
        account: &signer,
        for_address: address,
        amount: u64,
        is_collateral_only: bool
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_deposit<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
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
                receiver: for_address,
                amount,
                is_collateral_only,
            },
        );
    }

    public(friend) fun rebalance_shadow<C1,C2>(
        amount: u64,
        is_collateral_only_C1: bool,
        is_collateral_only_C2: bool
    ) acquires Storage, PoolEventHandle {
        let key_from = generate_coin_key<C1>();
        let key_to = generate_coin_key<C2>();
        let owner_addr = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_addr);
        assert!(simple_map::contains_key<String,u64>(&storage_ref.deposited, &key_from), error::invalid_argument(E_NOT_INITIALIZED_COIN));
        assert!(simple_map::contains_key<String,u64>(&storage_ref.deposited, &key_to), error::invalid_argument(E_NOT_INITIALIZED_COIN));

        let deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.deposited, &key_from);
        *deposited = *deposited - amount;
        let deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.deposited, &key_to);
        *deposited = *deposited + amount;

        if (is_collateral_only_C1) {
            let conly_deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.conly_deposited, &key_from);
            *conly_deposited = *conly_deposited - amount;
        };
        if (is_collateral_only_C2) {
            let conly_deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.conly_deposited, &key_to);
            *conly_deposited = *conly_deposited + amount;
        };

        event::emit_event<RebalanceEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_addr).rebalance_event,
            RebalanceEvent {
                from: key_from,
                to: key_to,
                amount,
                is_collateral_only_from: is_collateral_only_C1,
                is_collateral_only_to: is_collateral_only_C2,
                with_borrow: false,
            },
        );
    }

    public(friend) fun borrow_and_rebalance<C1,C2>(amount: u64, is_collateral_only: bool) acquires Storage, PoolEventHandle {
        let key_from = generate_coin_key<C1>();
        let key_to = generate_coin_key<C2>();
        let owner_addr = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_addr);
        assert!(simple_map::contains_key<String,u64>(&storage_ref.borrowed, &key_from), 0);
        assert!(simple_map::contains_key<String,u64>(&storage_ref.deposited, &key_to), 0);

        // TODO: consider fee
        let borrowed = simple_map::borrow_mut<String,u64>(&mut storage_ref.borrowed, &key_from);
        *borrowed = *borrowed + amount;
        let deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.deposited, &key_to);
        *deposited = *deposited + amount;

        if (is_collateral_only) {
            let conly_deposited = simple_map::borrow_mut<String,u64>(&mut storage_ref.conly_deposited, &key_to);
            *conly_deposited = *conly_deposited + amount;
        };

        event::emit_event<RebalanceEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_addr).rebalance_event,
            RebalanceEvent {
                from: key_from,
                to: key_to,
                amount,
                is_collateral_only_from: is_collateral_only,
                is_collateral_only_to: false,
                with_borrow: true,
            },
        );
    }

    public(friend) fun withdraw_for<C>(
        depositor_addr: address,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64
    ): u64 acquires Pool, Storage, PoolEventHandle {
        withdraw_for_internal<C>(
            depositor_addr,
            receiver_addr,
            amount,
            is_collateral_only,
            liquidation_fee
        )
    }

    fun withdraw_for_internal<C>(
        depositor_addr: address,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64
    ): u64 acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_withdraw<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool>(owner_address);
        let storage_ref = borrow_global_mut<Storage>(owner_address);

        accrue_interest<C>(storage_ref);
        collect_shadow_fee<C>(pool_ref, liquidation_fee);

        let amount_to_transfer = amount - liquidation_fee;
        coin::deposit<USDZ>(receiver_addr, coin::extract(&mut pool_ref.shadow, amount_to_transfer));
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
                receiver: receiver_addr,
                amount,
                is_collateral_only,
            },
        );
        (withdrawn_amount as u64)
    }

    public(friend) fun borrow_for<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_borrow<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool>(owner_address);
        let storage_ref = borrow_global_mut<Storage>(owner_address);

        accrue_interest<C>(storage_ref);

        let entry_fee = risk_factor::calculate_entry_fee(amount);
        let total_fee = entry_fee;
        let amount_with_entry_fee = amount + entry_fee;
        let total_liquidity = total_liquidity_internal(pool_ref, storage_ref);

        // check liquidity
        if (stability_pool::is_supported<C>()) {
            assert!((amount_with_entry_fee as u128) <= total_liquidity + stability_pool::left(), error::invalid_argument(E_EXCEED_BORROWABLE_AMOUNT));
        } else {
            assert!((amount_with_entry_fee as u128) <= total_liquidity, error::invalid_argument(E_EXCEED_BORROWABLE_AMOUNT));
        };

        if ((amount_with_entry_fee as u128) > total_liquidity) {
            // use stability pool
            if (total_liquidity > 0) {
                // extract all from shadow_pool, supply the shortage to borrow from stability pool
                let extracted = coin::extract_all(&mut pool_ref.shadow);
                let borrowing_value_from_stability = amount_with_entry_fee - coin::value(&extracted);
                let borrowed_from_stability = borrow_from_stability_pool<C>(receiver_addr, borrowing_value_from_stability);

                // merge coins extracted & distribute calculated values to receiver & shadow_pool
                coin::merge(&mut extracted, borrowed_from_stability);
                let for_entry_fee = coin::extract(&mut extracted, entry_fee);
                coin::deposit<USDZ>(receiver_addr, extracted); // to receiver
                treasury::collect_shadow_fee<C>(for_entry_fee); // to treasury (collected fee)

                total_fee = total_fee + stability_pool::calculate_entry_fee(borrowing_value_from_stability);
            } else {
                // when no liquidity in pool, borrow all from stability pool
                let borrowed_from_stability = borrow_from_stability_pool<C>(receiver_addr, amount_with_entry_fee);
                let for_entry_fee = coin::extract(&mut borrowed_from_stability, entry_fee);
                coin::deposit<USDZ>(receiver_addr, borrowed_from_stability); // to receiver
                treasury::collect_shadow_fee<C>(for_entry_fee); // to treasury (collected fee)

                total_fee = total_fee + stability_pool::calculate_entry_fee(amount_with_entry_fee);
            }
        } else {
            // not use stability pool
            let extracted = coin::extract(&mut pool_ref.shadow, amount);
            coin::deposit<USDZ>(receiver_addr, extracted);
            collect_shadow_fee<C>(pool_ref, entry_fee); // fee to treasury
        };

        // update borrowed stats
        let key = generate_coin_key<C>();
        let amount_with_total_fee = amount + total_fee;
        storage_ref.total_borrowed = storage_ref.total_borrowed + (amount_with_total_fee as u128);
        if (simple_map::contains_key<String,u64>(&storage_ref.borrowed, &key)) {
            let borrowed = simple_map::borrow_mut<String,u64>(&mut storage_ref.borrowed, &key);
            *borrowed = *borrowed + amount_with_total_fee;
        } else {
            simple_map::add<String,u64>(&mut storage_ref.borrowed, key, amount_with_total_fee);
        };

        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).borrow_event,
            BorrowEvent {
                caller: borrower_addr,
                borrower: borrower_addr,
                receiver: receiver_addr,
                amount,
            },
        );
    }

    public(friend) fun repay<C>(
        account: &signer,
        amount: u64
    ): u64 acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_repay<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
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
                repay_target: account_addr,
                amount,
            },
        );
        amount
    }

   public(friend) fun liquidate<C>(
        liquidator_addr: address,
        target_addr: address,
        liquidated: u64,
        is_collateral_only: bool,
    ) acquires Pool, Storage, PoolEventHandle {
        liquidate_internal<C>(liquidator_addr, target_addr, liquidated, is_collateral_only);
    }

    fun liquidate_internal<C>(
        liquidator_addr: address,
        target_addr: address,
        liquidated: u64,
        is_collateral_only: bool,
    ) acquires Pool, Storage, PoolEventHandle {
        let liquidation_fee = risk_factor::calculate_liquidation_fee(liquidated);
        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage>(owner_address);
        accrue_interest<C>(storage_ref);
        withdraw_for_internal<C>(liquidator_addr, target_addr, liquidated, is_collateral_only, liquidation_fee);

        event::emit_event<LiquidateEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).liquidate_event,
            LiquidateEvent {
                caller: liquidator_addr,
                target: target_addr,
                amount: liquidated
            }
        );
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
    fun borrow_from_stability_pool<C>(caller_addr: address, amount: u64): coin::Coin<USDZ> {
        stability_pool::borrow<C>(caller_addr, amount)
    }

    /// Repays the shadow to the stability pool
    /// use when shadow has already borrowed from this pool.
    /// @return repaid amount
    fun repay_to_stability_pool<C>(account: &signer, amount: u64): u64 {
        let borrowed = stability_pool::borrowed<C>();
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

    public entry fun total_deposited(): u128 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).total_deposited
    }

    public entry fun total_liquidity(): u128 acquires Pool, Storage {
        let owner_addr = permission::owner_address();
        let pool_ref = borrow_global<Pool>(owner_addr);
        let storage_ref = borrow_global<Storage>(owner_addr);
        total_liquidity_internal(pool_ref, storage_ref)
    }
    fun total_liquidity_internal(pool: &Pool, storage: &Storage): u128 {
        (coin::value(&pool.shadow) as u128) - storage.total_conly_deposited
    }

    public entry fun total_conly_deposited(): u128 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).total_conly_deposited
    }

    public entry fun total_borrowed(): u128 acquires Storage {
        borrow_global<Storage>(permission::owner_address()).total_borrowed
    }

    public entry fun deposited<C>(): u64 acquires Storage {
        let storage_ref = borrow_global<Storage>(permission::owner_address());
        deposited_internal(generate_coin_key<C>(), storage_ref)
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
        let storage_ref = borrow_global<Storage>(permission::owner_address());
        conly_deposit_internal(generate_coin_key<C>(), storage_ref)
    }
    fun conly_deposit_internal(key: String, storage: &Storage): u64 {
        let conly_deposited = storage.conly_deposited;
        if (simple_map::contains_key<String,u64>(&conly_deposited, &key)) {
            *simple_map::borrow<String,u64>(&conly_deposited, &key)
        } else {
            0
        }
    }

    public entry fun borrowed<C>(): u64 acquires Storage {
        let storage_ref = borrow_global<Storage>(permission::owner_address());
        borrowed_internal(generate_coin_key<C>(), storage_ref)
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
    use leizd_aptos_trove::usdz;
    #[test_only]
    use leizd::initializer;
    #[test_only]
    use leizd::pool_manager;
    #[test_only]
    use leizd::system_administrator;
    #[test_only]
    use leizd::test_coin::{Self,WETH,UNI};
    #[test_only]
    use leizd::test_initializer;
    #[test_only]
    fun setup_for_test_to_initialize_coins_and_pools(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initializer::initialize(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        init_pool_internal(owner);
        pool_manager::add_pool<WETH>(owner);
        pool_manager::add_pool<UNI>(owner);
    }

    // for deposit
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);

        usdz::mint_for_test(account_addr, 1000000);
        assert!(coin::balance<USDZ>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH>(account, account_addr, 800000, false);
        assert!(coin::balance<USDZ>(account_addr) == 200000, 0);
        assert!(total_deposited() == 800000, 0);
        assert!(deposited<WETH>() == 800000, 0);
        assert!(total_liquidity() == 800000, 0);
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
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 100, false);
        assert!(coin::balance<USDZ>(account_addr) == 0, 0);
        assert!(total_deposited() == 100, 0);
        assert!(deposited<WETH>() == 100, 0);
        assert!(total_liquidity() == 100, 0);
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
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 101, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_more_than_once_sequentially_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
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
        assert!(total_liquidity() == 60, 0);
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
        managed_coin::register<WETH>(account);
        managed_coin::register<USDZ>(account);

        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 800000, true);
        assert!(coin::balance<USDZ>(account_addr) == 200000, 0);
        assert!(total_deposited() == 800000, 0);
        assert!(deposited<WETH>() == 800000, 0);
        assert!(total_liquidity() == 0, 0);
        assert!(total_conly_deposited() == 800000, 0);
        assert!(conly_deposited<WETH>() == 800000, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 700000, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 600000, false, 0);

        assert!(coin::balance<USDZ>(account_addr) == 900000, 0);
        assert!(total_deposited() == 100000, 0);
        assert!(deposited<WETH>() == 100000, 0);
        assert!(total_liquidity() == 100000, 0);
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
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 100, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 100, false, 0);

        assert!(coin::balance<USDZ>(account_addr) == 100, 0);
        assert!(total_deposited() == 0, 0);
        assert!(deposited<WETH>() == 0, 0);
        assert!(total_liquidity() == 0, 0);
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<WETH>() == 0, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        assert!(total_liquidity() == 40, 0);
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<WETH>() == 0, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 700000, true);
        withdraw_for_internal<WETH>(account_addr, account_addr, 600000, true, 0);

        assert!(coin::balance<USDZ>(account_addr) == 900000, 0);
        assert!(total_deposited() == 100000, 0);
        assert!(deposited<WETH>() == 100000, 0);
        assert!(total_liquidity() == 0, 0);
        assert!(total_conly_deposited() == 100000, 0);
        assert!(conly_deposited<WETH>() == 100000, 0);
        assert!(total_borrowed() == 0, 0);
        assert!(borrowed<WETH>() == 0, 0);
    }

    // for borrow
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        assert!(total_liquidity() == 800000 - (100000 + 500), 0);
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<UNI>() == 0, 0);
        assert!(total_borrowed() == 100500, 0);
        assert!(borrowed<UNI>() == 100500, 0);

        // check about fee
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(treasury::balance_of_shadow<UNI>() == 500, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<BorrowEvent>(&event_handle.borrow_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_with_same_as_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        assert!(total_liquidity() == 0, 0);
        assert!(total_conly_deposited() == 0, 0);
        assert!(conly_deposited<UNI>() == 0, 0);
        assert!(total_borrowed() == 1005, 0);
        assert!(borrowed<UNI>() == 1005, 0);

        // check about fee
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(treasury::balance_of_shadow<UNI>() == 5, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    public entry fun test_borrow_with_more_than_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 10000 + 5 * 10);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        //// deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 10000 + 5 * 10, false);
        //// borrow UNI
        borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(coin::balance<USDZ>(borrower_addr) == 1000, 0);
        assert!(borrowed<UNI>() == 1000 + 5 * 1, 0);
        borrow_for<UNI>(borrower_addr, borrower_addr, 2000);
        assert!(coin::balance<USDZ>(borrower_addr) == 3000, 0);
        assert!(borrowed<UNI>() == 3000 + 5 * 3, 0);
        borrow_for<UNI>(borrower_addr, borrower_addr, 3000);
        assert!(coin::balance<USDZ>(borrower_addr) == 6000, 0);
        assert!(borrowed<UNI>() == 6000 + 5 * 6, 0);
        borrow_for<UNI>(borrower_addr, borrower_addr, 4000);
        assert!(coin::balance<USDZ>(borrower_addr) == 10000, 0);
        assert!(borrowed<UNI>() == 10000 + 5 * 10, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 10000 + 50);

        let initial_sec = 1648738800; // 20220401T00:00:00
        // deposit UNI
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 10000 + 50, false);
        // borrow UNI
        timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(coin::balance<USDZ>(borrower_addr) == 1000, 0);
        assert!(borrowed<UNI>() == 1000 + 5 * 1, 0);
        timestamp::update_global_time_for_test((initial_sec + 500) * 1000 * 1000); // + 250 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 2000);
        assert!(coin::balance<USDZ>(borrower_addr) == 3000, 0);
        assert!(borrowed<UNI>() == 3000 + 5 * 3, 0);
        // timestamp::update_global_time_for_test((initial_sec + 750) * 1000 * 1000); // + 250 sec // TODO: fail here because of ARITHMETIC_ERROR in interest_rate::update_interest_rate
        // borrow_for<UNI>(borrower_addr, borrower_addr, 3000);
        // assert!(coin::balance<USDZ>(borrower_addr) == 6000, 0);
        // assert!(borrowed<UNI>() == 6000 + 5 * 6, 0);
        // timestamp::update_global_time_for_test((initial_sec + 1000) * 1000 * 1000); // + 250 sec
        // borrow_for<UNI>(borrower_addr, borrower_addr, 4000);
        // assert!(coin::balance<USDZ>(borrower_addr) == 10000, 0);
        // assert!(borrowed<UNI>() == 10000 + 5 * 10, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    fun test_borrow_to_not_borrow_collateral_only(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 150);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        deposit_for_internal<UNI>(depositor, depositor_addr, 50, true);
        // borrow UNI
        borrow_for<UNI>(borrower_addr, borrower_addr, 120);
    }

    // for repay
    #[test_only]
    fun pool_shadow_value(addr: address): u64 acquires Pool {
        coin::value(&borrow_global<Pool>(addr).shadow)
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 10050);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit_for_internal<UNI>(depositor, depositor_addr, 10050, false);
        assert!(pool_shadow_value(owner_address) == 10050, 0);
        assert!(borrowed<UNI>() == 0, 0);
        borrow_for<UNI>(borrower_addr, borrower_addr, 5000);
        assert!(pool_shadow_value(owner_address) == 10050 - (5000 + 25), 0);
        assert!(borrowed<UNI>() == 5025, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 5000, 0);
        let repaid_amount = repay<UNI>(borrower, 2000);
        assert!(repaid_amount == 2000, 0);
        assert!(pool_shadow_value(owner_address) == 7025, 0);
        assert!(borrowed<UNI>() == 3025, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 3000, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_with_same_as_total_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        usdz::mint_for_test(borrower_addr, 5);
        let repaid_amount = repay<UNI>(borrower, 1005);
        assert!(repaid_amount == 1005, 0);
        assert!(pool_shadow_value(owner_address) == 1005, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_repay_with_more_than_total_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 10050);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        deposit_for_internal<UNI>(depositor, depositor_addr, 10050, false);
        assert!(pool_shadow_value(owner_address) == 10050, 0);
        borrow_for<UNI>(borrower_addr, borrower_addr, 10000);
        assert!(pool_shadow_value(owner_address) == 0, 0);
        let repaid_amount = repay<UNI>(borrower, 1000);
        assert!(repaid_amount == 1000, 0);
        assert!(pool_shadow_value(owner_address) == 1000, 0);
        assert!(borrowed<UNI>() == 9050, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 9000, 0);
        let repaid_amount = repay<UNI>(borrower, 2000);
        assert!(repaid_amount == 2000, 0);
        assert!(pool_shadow_value(owner_address) == 3000, 0);
        assert!(borrowed<UNI>() == 7050, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 7000, 0);
        let repaid_amount = repay<UNI>(borrower, 3000);
        assert!(repaid_amount == 3000, 0);
        assert!(pool_shadow_value(owner_address) == 6000, 0);
        assert!(borrowed<UNI>() == 4050, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 4000, 0);
        let repaid_amount = repay<UNI>(borrower, 4000);
        assert!(repaid_amount == 4000, 0);
        assert!(pool_shadow_value(owner_address) == 10000, 0);
        assert!(borrowed<UNI>() == 50, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 4, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        usdz::mint_for_test(depositor_addr, 10050);
        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 10050, false);
        assert!(pool_shadow_value(owner_address) == 10050, 0);
        timestamp::update_global_time_for_test((initial_sec + 80) * 1000 * 1000); // + 80 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 10000);
        assert!(pool_shadow_value(owner_address) == 0, 0);

        timestamp::update_global_time_for_test((initial_sec + 160) * 1000 * 1000); // + 80 sec
        let repaid_amount = repay<UNI>(borrower, 1000);
        assert!(repaid_amount == 1000, 0);
        assert!(pool_shadow_value(owner_address) == 1000, 0);
        assert!(borrowed<UNI>() == 9050, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 9000, 0);
        timestamp::update_global_time_for_test((initial_sec + 240) * 1000 * 1000); // + 80 sec
        let repaid_amount = repay<UNI>(borrower, 2000);
        assert!(repaid_amount == 2000, 0);
        assert!(pool_shadow_value(owner_address) == 3000, 0);
        assert!(borrowed<UNI>() == 7050, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 7000, 0);
        timestamp::update_global_time_for_test((initial_sec + 320) * 1000 * 1000); // + 80 sec
        let repaid_amount = repay<UNI>(borrower, 3000);
        assert!(repaid_amount == 3000, 0);
        assert!(pool_shadow_value(owner_address) == 6000, 0);
        assert!(borrowed<UNI>() == 4050, 0);
        assert!(coin::balance<USDZ>(borrower_addr) == 4000, 0);
        timestamp::update_global_time_for_test((initial_sec + 400) * 1000 * 1000); // + 80 sec
        // let repaid_amount = repay<UNI>(borrower, 4000); // TODO: fail here because of ARITHMETIC_ERROR in accrue_interest (Cannot cast u128 to u64)
        // assert!(repaid_amount == 4000, 0);
        // assert!(pool_shadow_value(owner_address) == 10000, 0);
        // assert!(borrowed<UNI>() == 50, 0);
        // assert!(coin::balance<USDZ>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<RepayEvent>(&event_handle.repay_event) == 3, 0);
    }

    // for liquidation
    #[test(owner=@leizd,depositor=@0x111,liquidator=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_liquidate(owner: &signer, depositor: &signer, liquidator: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_address = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let liquidator_addr = signer::address_of(liquidator);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(liquidator_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(liquidator);
        usdz::mint_for_test(depositor_addr, 1001);

        deposit_for_internal<WETH>(depositor, depositor_addr, 1001, false);
        assert!(pool_shadow_value(owner_address) == 1001, 0);
        assert!(total_deposited() == 1001, 0);
        assert!(total_conly_deposited() == 0, 0);
        assert!(coin::balance<USDZ>(depositor_addr) == 0, 0);
        assert!(coin::balance<USDZ>(liquidator_addr) == 0, 0);

        liquidate_internal<WETH>(liquidator_addr, liquidator_addr, 1001, false);
        assert!(pool_shadow_value(owner_address) == 0, 0);
        assert!(total_deposited() == 0, 0);
        assert!(total_conly_deposited() == 0, 0);
        assert!(coin::balance<USDZ>(depositor_addr) == 0, 0);
        assert!(coin::balance<USDZ>(liquidator_addr) == 995, 0);
        assert!(treasury::balance_of_shadow<WETH>() == 6, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<LiquidateEvent>(&event_handle.liquidate_event) == 1, 0);
    }

    // for with stability_pool
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_borrow(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 100000);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 50000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 10000 + 50, false);
        assert!(pool_shadow_value(owner_addr) == 10050, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 50000, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
        //// from only shadow_pool
        borrow_for<UNI>(borrower_addr, borrower_addr, 5000);
        assert!(pool_shadow_value(owner_addr) == 10050 - (5000 + 25), 0);
        assert!(borrowed<UNI>() == 5025, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 50000, 0);
        assert!(usdz::balance_of(borrower_addr) == 5000, 0);
        //// from both
        borrow_for<UNI>(borrower_addr, borrower_addr, 10000);
        let from_shadow = 5025;
        let from_stability = 10050 - from_shadow;
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(stability_pool::borrowed<UNI>() == (from_shadow + 26 as u128), 0); // from_shadow + fee calculated by from_shadow
        assert!(stability_pool::left() == (50000 - from_shadow as u128) , 0);
        assert!(borrowed<UNI>() == 5025 + from_shadow + from_stability + 26, 0);
        assert!(usdz::balance_of(borrower_addr) == 15000, 0);
        //// from only stability_pool
        borrow_for<UNI>(borrower_addr, borrower_addr, 15000);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == 15101 + ((15000 + 75) + 76), 0); // (borrowed + fee) + fee calculated by (borrowed + fee)
        assert!(stability_pool::borrowed<UNI>() == 5051 + ((15000 + 75) + 76), 0); // previous + this time
        assert!(stability_pool::left() == (50000 - 5025 - 15075 as u128), 0); // initial - previous - this time
        assert!(usdz::balance_of(borrower_addr) == 30000, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    public entry fun test_with_stability_pool_to_borrow_when_not_supported(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 100000);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 50000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 10000 + 50, false);
        assert!(pool_shadow_value(owner_addr) == 10050, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 50000, 0);
        // borrow the amount more than internal_liquidity even though stability pool does not support UNI
        borrow_for<UNI>(borrower_addr, borrower_addr, 20000);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    public entry fun test_with_stability_pool_to_borrow_with_cannot_borrowed_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);

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
    public entry fun test_with_stability_pool_to_borrow_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 100000);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        let initial_sec = 1648738800; // 20220401T00:00:00
        //// prepares
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        stability_pool::deposit(depositor, 50000);
        timestamp::update_global_time_for_test((initial_sec + 24) * 1000 * 1000); // + 24 sec
        deposit_for_internal<UNI>(depositor, depositor_addr, 10000 + 50, false);
        assert!(pool_shadow_value(owner_addr) == 10050, 0);
        assert!(borrowed<UNI>() == 0, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 50000, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
        //// from only shadow_pool
        timestamp::update_global_time_for_test((initial_sec + 48) * 1000 * 1000); // + 24 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 5000);
        assert!(pool_shadow_value(owner_addr) == 10050 - (5000 + 25), 0);
        assert!(borrowed<UNI>() == 5025, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 50000, 0);
        assert!(usdz::balance_of(borrower_addr) == 5000, 0);
        //// from both
        timestamp::update_global_time_for_test((initial_sec + 72) * 1000 * 1000); // + 24 sec
        // borrow_for<UNI>(borrower_addr, borrower_addr, 100); // TODO: fail here because of ARITHMETIC_ERROR in interest_rate::update_interest_rate
        // assert!(pool_shadow_value(owner_addr) == 0, 0);
        // assert!(borrowed<UNI>() == 150, 0);
        // assert!(stability_pool::borrowed<UNI>() == 50, 0);
        // assert!(stability_pool::left() == 450, 0);
        // assert!(usdz::balance_of(borrower_addr) == 150, 0);
        // //// from only stability_pool
        // timestamp::update_global_time_for_test((initial_sec + 96) * 1000 * 1000); // + 24 sec
        // borrow_for<UNI>(borrower_addr, borrower_addr, 150);
        // assert!(pool_shadow_value(owner_addr) == 0, 0);
        // assert!(borrowed<UNI>() == 300, 0);
        // assert!(stability_pool::borrowed<UNI>() == 200, 0);
        // assert!(stability_pool::left() == 300, 0);
        // assert!(usdz::balance_of(borrower_addr) == 300, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_repay(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 10000);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 5000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1000, false);
        borrow_for<UNI>(borrower_addr, borrower_addr, 3000);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == (1000 + 5) + (2000 + 10 + 11), 0);
        assert!(stability_pool::borrowed<UNI>() == 5 + 2000 + 10 + 11, 0);
        assert!(stability_pool::left() == 5000 - (5 + 2000 + 10), 0);
        assert!(usdz::balance_of(borrower_addr) == 3000, 0);
        //// from only stability_pool
        repay<UNI>(borrower, 1800);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == ((1000 + 5) + (2000 + 10 + 11)) - 1800, 0);
        assert!(stability_pool::borrowed<UNI>() == (5 + 2000 + 10 + 11) - 1800, 0);
        assert!(stability_pool::left() == 5000 - (5 + 2000 + 10) + (1800 - 11), 0);
        assert!(usdz::balance_of(borrower_addr) == 1200, 0);
        //// from both
        repay<UNI>(borrower, 1000);
        assert!(pool_shadow_value(owner_addr) == 1000 - 226, 0);
        assert!(borrowed<UNI>() == ((1000 + 5) + (2000 + 10 + 11)) - 1800 - 1000, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 5000, 0);
        assert!(usdz::balance_of(borrower_addr) == 200, 0);
        //// from only shadow_pool
        repay<UNI>(borrower, 200);
        assert!(pool_shadow_value(owner_addr) == 1000 - 26, 0);
        assert!(borrowed<UNI>() == 5 + 10 + 11, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 5000, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_repay_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);

        let owner_addr = signer::address_of(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 10000);

        // execute
        let initial_sec = 1648738800; // 20220401T00:00:00
        //// prepares
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        stability_pool::deposit(depositor, 5000);
        timestamp::update_global_time_for_test((initial_sec + 11) * 1000 * 1000); // + 11 sec
        deposit_for_internal<UNI>(depositor, depositor_addr, 1000, false);
        timestamp::update_global_time_for_test((initial_sec + 22) * 1000 * 1000); // + 11 sec
        timestamp::update_global_time_for_test((initial_sec + 33) * 1000 * 1000); // + 11 sec
        borrow_for<UNI>(borrower_addr, borrower_addr, 3000);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == (1000 + 5) + (2000 + 10 + 11), 0);
        assert!(stability_pool::borrowed<UNI>() == 5 + 2000 + 10 + 11, 0);
        assert!(stability_pool::left() == 5000 - (5 + 2000 + 10), 0);
        assert!(usdz::balance_of(borrower_addr) == 3000, 0);
        //// from only stability_pool
        timestamp::update_global_time_for_test((initial_sec + 44) * 1000 * 1000); // + 11 sec
        repay<UNI>(borrower, 1800);
        assert!(pool_shadow_value(owner_addr) == 0, 0);
        assert!(borrowed<UNI>() == ((1000 + 5) + (2000 + 10 + 11)) - 1800, 0);
        assert!(stability_pool::borrowed<UNI>() == (5 + 2000 + 10 + 11) - 1800, 0);
        assert!(stability_pool::left() == 5000 - (5 + 2000 + 10) + (1800 - 11), 0);
        assert!(usdz::balance_of(borrower_addr) == 1200, 0);
        //// from both
        timestamp::update_global_time_for_test((initial_sec + 55) * 1000 * 1000); // + 11 sec
        repay<UNI>(borrower, 1000);
        assert!(pool_shadow_value(owner_addr) == 1000 - 226, 0);
        assert!(borrowed<UNI>() == ((1000 + 5) + (2000 + 10 + 11)) - 1800 - 1000, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 5000, 0);
        assert!(usdz::balance_of(borrower_addr) == 200, 0);
        //// from only shadow_pool
        timestamp::update_global_time_for_test((initial_sec + 66) * 1000 * 1000); // + 11 sec
        repay<UNI>(borrower, 200);
        assert!(pool_shadow_value(owner_addr) == 1000 - 26, 0);
        assert!(borrowed<UNI>() == 5 + 10 + 11, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        assert!(stability_pool::left() == 5000, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_open_position_more_than_once(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower);
        usdz::mint_for_test(depositor_addr, 100000);

        // check prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(stability_pool::entry_fee() == stability_pool::default_entry_fee(), 0);

        // execute
        //// prepares
        stability_pool::deposit(depositor, 50000);
        //// 1st
        borrow_for<UNI>(borrower_addr, borrower_addr, 5000);
        usdz::mint_for_test(borrower_addr, 25 + 26); // fee in shadow + fee in stability
        repay<UNI>(borrower, 5000 + 25 + 26);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        assert!(stability_pool::uncollected_fee<UNI>() == 0, 0);
        //// 2nd
        borrow_for<UNI>(borrower_addr, borrower_addr, 10000);
        borrow_for<UNI>(borrower_addr, borrower_addr, 20000);
        usdz::mint_for_test(borrower_addr, 100 + 101); // fee in shadow + fee in stability for 20000
        usdz::mint_for_test(borrower_addr, 50 + 51); // fee in shadow + fee in stability for 10000
        repay<UNI>(borrower, 20000 + 100 + 101);
        repay<UNI>(borrower, 10000 + 50 + 51);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        //// 3rd
        borrow_for<UNI>(borrower_addr, borrower_addr, 10);
        repay<UNI>(borrower, 10);
        borrow_for<UNI>(borrower_addr, borrower_addr, 20);
        repay<UNI>(borrower, 20);
        borrow_for<UNI>(borrower_addr, borrower_addr, 50);
        repay<UNI>(borrower, 40);
        repay<UNI>(borrower, 10);
        usdz::mint_for_test(borrower_addr, 6);
        repay<UNI>(borrower, 6);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        //// still open position
        borrow_for<UNI>(borrower_addr, borrower_addr, 5000);
        assert!(stability_pool::borrowed<UNI>() == 5051, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower1=@0x222,borrower2=@0x333,aptos_framework=@aptos_framework)]
    public entry fun test_with_stability_pool_to_open_multi_position(owner: &signer, depositor: &signer, borrower1: &signer, borrower2: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);
        stability_pool::add_supported_pool<UNI>(owner);
        stability_pool::add_supported_pool<WETH>(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower1_addr = signer::address_of(borrower1);
        let borrower2_addr = signer::address_of(borrower2);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower1_addr);
        account::create_account_for_test(borrower2_addr);
        managed_coin::register<USDZ>(depositor);
        managed_coin::register<USDZ>(borrower1);
        managed_coin::register<USDZ>(borrower2);
        usdz::mint_for_test(depositor_addr, 20000);

        // execute
        stability_pool::deposit(depositor, 10000);
        deposit_for_internal<WETH>(depositor, depositor_addr, 2500, false);
        //// borrow
        borrow_for<WETH>(borrower1_addr, borrower1_addr, 3000);
        assert!(stability_pool::left() == 10000 - (500 + 15), 0);
        assert!(stability_pool::borrowed<WETH>() == (500 + 15) + 3, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        borrow_for<WETH>(borrower2_addr, borrower2_addr, 2000);
        assert!(stability_pool::left() == 10000 - (500 + 15) - (2000 + 10), 0);
        assert!(stability_pool::borrowed<WETH>() == (500 + 15) + 3 + (2000 + 10) + 11, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        borrow_for<UNI>(borrower2_addr, borrower2_addr, 4000);
        assert!(stability_pool::left() == 10000 - (500 + 15) - (2000 + 10) - (4000 + 20), 0);
        assert!(stability_pool::borrowed<WETH>() == (500 + 15) + 3 + (2000 + 10) + 11, 0);
        assert!(stability_pool::borrowed<UNI>() == (4000 + 20) + 21, 0);
        //// repay
        repay<UNI>(depositor, 4041);
        assert!(stability_pool::borrowed<WETH>() == (500 + 15) + 3 + (2000 + 10) + 11, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
        repay<WETH>(depositor, 2539);
        assert!(stability_pool::borrowed<WETH>() == 0, 0);
        assert!(stability_pool::borrowed<UNI>() == 0, 0);
    }

    // rebalance shadow
    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_rebalance_shadow(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        managed_coin::register<WETH>(account1);
        managed_coin::register<UNI>(account1);
        managed_coin::register<USDZ>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        usdz::mint_for_test(account1_addr, 1000000);

        deposit_for_internal<WETH>(account1, account1_addr, 100000, false);
        deposit_for_internal<UNI>(account1, account1_addr, 100000, false);
        assert!(deposited<WETH>() == 100000, 0);
        assert!(deposited<UNI>() == 100000, 0);

        rebalance_shadow<WETH,UNI>(10000, false, false);
        assert!(deposited<WETH>() == 90000, 0);
        assert!(deposited<UNI>() == 110000, 0);

        let event_handle = borrow_global<PoolEventHandle>(signer::address_of(owner));
        assert!(event::counter<RebalanceEvent>(&event_handle.rebalance_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_rebalance_shadow_with_all_pattern(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::register<UNI>(account);
        managed_coin::register<USDZ>(account);

        usdz::mint_for_test(account_addr, 50000);
        deposit_for_internal<WETH>(account, account_addr, 10000, false);
        deposit_for_internal<WETH>(account, account_addr, 10000, true);
        deposit_for_internal<UNI>(account, account_addr, 10000, false);
        deposit_for_internal<UNI>(account, account_addr, 10000, true);
        assert!(deposited<WETH>() == 20000, 0);
        assert!(conly_deposited<WETH>() == 10000, 0);
        assert!(deposited<UNI>() == 20000, 0);
        assert!(conly_deposited<UNI>() == 10000, 0);

        // borrowable & borrowable
        rebalance_shadow<WETH,UNI>(5000, false, false);
        assert!(deposited<WETH>() == 15000, 0);
        assert!(conly_deposited<WETH>() == 10000, 0);
        assert!(deposited<UNI>() == 25000, 0);
        assert!(conly_deposited<UNI>() == 10000, 0);

        // collateral only & collateral only
        rebalance_shadow<WETH,UNI>(5000, true, true);
        assert!(deposited<WETH>() == 10000, 0);
        assert!(conly_deposited<WETH>() == 5000, 0);
        assert!(deposited<UNI>() == 30000, 0);
        assert!(conly_deposited<UNI>() == 15000, 0);

        // borrowable & collateral only
        rebalance_shadow<WETH,UNI>(5000, false, true);
        assert!(deposited<WETH>() == 5000, 0);
        assert!(conly_deposited<WETH>() == 5000, 0);
        assert!(deposited<UNI>() == 35000, 0);
        assert!(conly_deposited<UNI>() == 20000, 0);

        // collateral only & borrowable
        rebalance_shadow<WETH,UNI>(5000, true, false);
        assert!(deposited<WETH>() == 0, 0);
        assert!(conly_deposited<WETH>() == 0, 0);
        assert!(deposited<UNI>() == 40000, 0);
        assert!(conly_deposited<UNI>() == 20000, 0);
    }
    #[test(owner=@leizd,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_rebalance_shadow_to_set_not_added_coin_key_to_from(owner: &signer, aptos_framework: &signer) acquires Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initializer::initialize(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        init_pool_internal(owner);
        pool_manager::add_pool<WETH>(owner);

        rebalance_shadow<UNI,WETH>(5000, true, true);
    }
    #[test(owner=@leizd,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_rebalance_shadow_to_set_not_added_coin_key_to_to(owner: &signer, aptos_framework: &signer) acquires Storage, PoolEventHandle {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initializer::initialize(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        init_pool_internal(owner);
        pool_manager::add_pool<WETH>(owner);

        rebalance_shadow<WETH,UNI>(5000, true, true);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_and_rebalance(owner: &signer, account1: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        managed_coin::register<USDZ>(owner);
        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(owner_addr, 1000000);
        usdz::mint_for_test(account1_addr, 1000000);

        // execute
        //// prepares
        deposit_for_internal<WETH>(owner, owner_addr, 100000, false);
        deposit_for_internal<UNI>(account1, account1_addr, 100000, false);
        borrow_for<WETH>(account1_addr, account1_addr, 50000);
        assert!(borrowed<WETH>() == 50000 + 250, 0);
        assert!(deposited<UNI>() == 100000, 0);

        borrow_and_rebalance<WETH,UNI>(10000, false);
        assert!(borrowed<WETH>() == 60000 + 250, 0); // TODO: check to charge fee in rebalance (maybe 300)
        assert!(deposited<UNI>() == 110000, 0);

        let event_handle = borrow_global<PoolEventHandle>(owner_addr);
        assert!(event::counter<RebalanceEvent>(&event_handle.rebalance_event) == 1, 0);
    }

    // for common validations
    //// `amount` arg
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_deposit_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_withdraw_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal<WETH>(owner_address, owner_address, 0, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_borrow_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let owner_address = signer::address_of(owner);
        borrow_for<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_repay_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        repay<WETH>(owner, 0);
    }
    //// control pool status
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_deposit_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::deactivate_pool<WETH>(owner);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_deposit_when_froze(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::freeze_pool<WETH>(owner);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_withdraw_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::deactivate_pool<WETH>(owner);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal<WETH>(owner_address, owner_address, 0, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_borrow_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::deactivate_pool<WETH>(owner);
        let owner_address = signer::address_of(owner);
        borrow_for<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_borrow_when_frozen(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::freeze_pool<WETH>(owner);
        let owner_address = signer::address_of(owner);
        borrow_for<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_repay_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        system_administrator::deactivate_pool<WETH>(owner);
        repay<WETH>(owner, 0);
    }
}
