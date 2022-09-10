module leizd::shadow_pool {

    use std::error;
    use std::signer;
    use std::string::{String};
    use aptos_std::simple_map;
    use aptos_std::event;
    use aptos_framework::coin;
    use aptos_framework::type_info;
    use aptos_framework::account;
    use leizd::usdz::{USDZ};
    use leizd::permission;
    use leizd::constant;
    use leizd::treasury;
    use leizd::stability_pool;
    use leizd::risk_factor;
    use leizd::account_position;
    use leizd::pool_status;
    use leizd::interest_rate;

    friend leizd::money_market;

    const E_NOT_AVAILABLE_STATUS: u64 = 4;
    const E_AMOUNT_ARG_IS_ZERO: u64 = 5;

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

        if (storage_ref.total_deposited - storage_ref.total_conly_deposited < (amount as u128)) {
            // check the staiblity left
            let left = stability_pool::left();
            assert!(left >= (amount as u128), 0);
            borrow_shadow_from_stability_pool<C>(receiver_addr, amount);
            fee = fee + stability_pool::stability_fee_amount(amount);
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

        let account_addr = signer::address_of(account);
        let debt_amount = account_position::borrowed_shadow<C>(account_addr);
        let repaid_amount = if (amount >= debt_amount) debt_amount else amount;

        let withdrawn = coin::withdraw<USDZ>(account, repaid_amount);
        coin::merge(&mut pool_ref.shadow, withdrawn);

        storage_ref.total_borrowed = storage_ref.total_borrowed - (repaid_amount as u128);

        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<PoolEventHandle>(owner_address).repay_event,
            RepayEvent {
                caller: account_addr,
                repayer: account_addr,
                amount,
                is_shadow: false
            },
        );
        repaid_amount
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

    fun borrow_shadow_from_stability_pool<C>(receiver_addr: address, amount: u64) {
        let borrowed = stability_pool::borrow<C>(receiver_addr, amount);
        coin::deposit(receiver_addr, borrowed);
    }

    /// Repays the shadow to the stability pool if someone has already borrowed from the pool.
    /// @return repaid amount
    fun repay_to_stability_pool<C>(account: &signer, amount: u64): u64 {
        let left = stability_pool::left();
        if (left == 0) {
            return 0
        } else if (left >= (amount as u128)) {
            stability_pool::repay<C>(account, amount);
            return amount
        } else {
            stability_pool::repay<C>(account, (left as u64));
            return (left as u64)
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
        let key = generate_coin_key<C>();
        let deposited = borrow_global<Storage>(permission::owner_address()).deposited;
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
        let key = generate_coin_key<C>();
        let borrowed = borrow_global<Storage>(permission::owner_address()).borrowed;
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
    use aptos_framework::timestamp;
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
    public entry fun test_deposit_more_than_once_sequentially(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        initializer::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 10, false);
        deposit_for_internal<WETH>(account, account_addr, 20, false);
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
    public entry fun test_withdraw_more_than_once_sequentially(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 100, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 10, false, 0);
        withdraw_for_internal<WETH>(account_addr, account_addr, 20, false, 0);
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

    // for repay
    // public entry fun test_repay // TODO

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

        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);
        initializer::register<WETH>(account1);
        initializer::register<UNI>(account1);
        initializer::register<USDZ>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        usdz::mint_for_test(account1_addr, 1000000);

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