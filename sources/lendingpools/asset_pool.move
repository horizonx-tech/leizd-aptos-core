/// Main point of interaction with Leizd Protocol
/// Users can:
/// # Deposit
/// # Withdraw
/// # Borrow
/// # Repay
/// # Liquidate
/// # Rebalance
module leizd::asset_pool {

    use std::error;
    use std::signer;
    use aptos_std::event;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use leizd::risk_factor;
    use leizd::pool_type::{Asset};
    use leizd::permission;
    use leizd::treasury;
    use leizd::interest_rate;
    use leizd::pool_status;
    use leizd::constant;
    use leizd::dex_facade;
    use leizd::account_position;
    use leizd::stability_pool;

    friend leizd::money_market;

    const E_IS_ALREADY_EXISTED: u64 = 1;
    const E_IS_NOT_EXISTED: u64 = 2;
    const E_DEX_DOES_NOT_HAVE_LIQUIDITY: u64 = 3;
    const E_NOT_AVAILABLE_STATUS: u64 = 4;
    const E_AMOUNT_ARG_IS_ZERO: u64 = 5;

    /// Asset Pool where users can deposit and borrow.
    /// Each asset is separately deposited into a pool.
    struct Pool<phantom C> has key {
        asset: coin::Coin<C>,
        is_active: bool,
    }

    // TODO: vector<Pool>

    /// The total deposit amount and total borrowed amount can be updated
    /// in this struct. The collateral only asset is separately managed
    /// to calculate the borrowable amount in the pool.
    /// C: The coin type of the pool e.g. WETH / APT / USDC
    struct Storage<phantom C> has key {
        total_deposited: u128,
        total_conly_deposited: u128, // collateral only
        total_borrowed: u128,
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
    
    struct PoolEventHandle<phantom C> has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
        liquidate_event: event::EventHandle<LiquidateEvent>,
    }

    /// Initializes a pool with the coin the owner specifies.
    /// The caller is only owner and creates not only a pool but also other resources
    /// such as a treasury for the coin, an interest rate model, and coins of collaterals and debts.
    public fun init_pool<C>(owner: &signer) {
        init_pool_internal<C>(owner);
    }

    fun init_pool_internal<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        assert!(!is_pool_initialized<C>(), E_IS_ALREADY_EXISTED);
        assert!(dex_facade::has_liquidity<C>(), E_DEX_DOES_NOT_HAVE_LIQUIDITY);

        treasury::initialize<C>(owner);
        risk_factor::new_asset<C>(owner);
        interest_rate::initialize<C>(owner);
        stability_pool::init_pool<C>(owner);
        pool_status::initialize<C>(owner);
        
        move_to(owner, Pool<C> {
            asset: coin::zero<C>(),
            is_active: true
        });
        move_to(owner, default_storage<C,Asset>());
        move_to(owner, PoolEventHandle<C> {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
            liquidate_event: account::new_event_handle<LiquidateEvent>(owner),
        });
    }

    /// Deposits an asset or a shadow to the pool.
    /// If a user wants to protect the asset, it's possible that it can be used only for the collateral.
    /// C is a pool type and a user should select which pool to use.
    /// e.g. Deposit USDZ for WETH Pool -> deposit_for<WETH,Shadow>(x,x,x,x)
    /// e.g. Deposit WBTC for WBTC Pool -> deposit_for<WBTC,Asset>(x,x,x,x)
    public(friend) fun deposit_for<C>(
        account: &signer,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool,
    ) acquires Pool, Storage, PoolEventHandle {
        deposit_for_internal<C>(
            account,
            depositor_addr,
            amount,
            is_collateral_only
        );
    }

    fun deposit_for_internal<C>(
        account: &signer,
        depositor_addr: address,
        amount: u64,
        is_collateral_only: bool,
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::is_available<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage<C>>(owner_address);
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);

        accrue_interest<C,Asset>(storage_ref);

        coin::merge(&mut pool_ref.asset, coin::withdraw<C>(account, amount));
        storage_ref.total_deposited = storage_ref.total_deposited + (amount as u128);
        if (is_collateral_only) {
            storage_ref.total_conly_deposited = storage_ref.total_conly_deposited + (amount as u128);
        };
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).deposit_event,
            DepositEvent {
                caller: signer::address_of(account),
                depositor: depositor_addr,
                amount,
                is_collateral_only,
                is_shadow: false,
            },
        );
    }

    /// Withdraws an asset or a shadow from the pool.
    public(friend) fun withdraw_for<C>(
        deopsitor_addr: address,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool
    ): u64 acquires Pool, Storage, PoolEventHandle {
        withdraw_for_internal<C>(
            deopsitor_addr,
            receiver_addr,
            amount,
            is_collateral_only,
            0
        )
    }

    fun withdraw_for_internal<C>(
        deopsitor_addr: address,
        reciever_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64,
    ): u64 acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::is_available<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let storage_ref = borrow_global_mut<Storage<C>>(owner_address);

        accrue_interest<C,Asset>(storage_ref);
        collect_asset_fee<C>(pool_ref, liquidation_fee);

        let amount_to_transfer = amount - liquidation_fee;
        coin::deposit<C>(reciever_addr, coin::extract(&mut pool_ref.asset, amount_to_transfer));
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
        if (is_collateral_only) {
            storage_ref.total_conly_deposited = storage_ref.total_conly_deposited - (withdrawn_amount as u128);
        };

        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).withdraw_event,
            WithdrawEvent {
                caller: deopsitor_addr,
                depositor: deopsitor_addr,
                receiver: reciever_addr,
                amount,
                is_collateral_only,
                is_shadow: false
            },
        );
        (withdrawn_amount as u64)
    }

    /// Borrows an asset or a shadow from the pool.
    public(friend) fun borrow_for<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
    ) acquires Pool, Storage, PoolEventHandle {
        borrow_for_internal<C>(borrower_addr, receiver_addr, amount);
    }

    fun borrow_for_internal<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::is_available<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let storage_ref = borrow_global_mut<Storage<C>>(owner_address);

        accrue_interest<C,Asset>(storage_ref);

        let fee = calculate_entry_fee(amount);
        collect_asset_fee<C>(pool_ref, fee);

        let deposited = coin::extract(&mut pool_ref.asset, amount);
        coin::deposit<C>(receiver_addr, deposited);
        storage_ref.total_borrowed = storage_ref.total_borrowed + (amount as u128) + (fee as u128);
        
        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).borrow_event,
            BorrowEvent {
                caller: borrower_addr,
                borrower: borrower_addr,
                receiver: receiver_addr,
                amount,
                is_shadow: false
            },
        );
    }

    /// Repays an asset or a shadow for the borrowed position.
    public entry fun repay<C>(
        account: &signer,
        amount: u64,
    ): u64 acquires Pool, Storage, PoolEventHandle {
        repay_internal<C>(account, amount)
    }


    fun repay_internal<C>(
        account: &signer,
        amount: u64,
    ): u64 acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::is_available<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let storage_ref = borrow_global_mut<Storage<C>>(owner_address);

        accrue_interest<C,Asset>(storage_ref);

        let account_addr = signer::address_of(account);
        let debt_amount = account_position::borrowed_shadow<C>(account_addr);
        let repaid_amount = if (amount >= debt_amount) debt_amount else amount;
        storage_ref.total_borrowed = storage_ref.total_borrowed - (repaid_amount as u128);
        let withdrawn = coin::withdraw<C>(account, repaid_amount);
        coin::merge(&mut pool_ref.asset, withdrawn);

        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).repay_event,
            RepayEvent {
                caller: account_addr,
                repayer: account_addr,
                amount,
                is_shadow: false
            },
        );
        repaid_amount
    }

    // public entry fun liquidate<C>(
    //     account: &signer,
    //     target_addr: address,
    //     is_shadow: bool
    // ) acquires Pool, Storage, PoolEventHandle {
    //     let liquidation_fee = risk_factor::liquidation_fee();
    //     if (is_shadow) {
    //         assert!(is_shadow_solvent<C>(target_addr), 0);
    //         withdraw_shadow<C>(account, target_addr, constant::u64_max(), true, liquidation_fee);
    //         withdraw_shadow<C>(account, target_addr, constant::u64_max(), false, liquidation_fee);
    //     } else {
    //         assert!(is_asset_solvent<C>(target_addr), 0);
    //         withdraw_asset<C>(account, target_addr, constant::u64_max(), true, liquidation_fee);
    //         withdraw_asset<C>(account, target_addr, constant::u64_max(), false, liquidation_fee);
    //     };
    //     event::emit_event<LiquidateEvent>(
    //         &mut borrow_global_mut<PoolEventHandle<C>>(permission::owner_address()).liquidate_event,
    //         LiquidateEvent {
    //             caller: signer::address_of(account),
    //             target: target_addr,
    //             is_shadow
    //         }
    //     )
    // }

    public fun is_pool_initialized<C>(): bool {
        exists<Pool<C>>(permission::owner_address())
    }

    /// This function is called on every user action.
    fun accrue_interest<C,P>(storage_ref: &mut Storage<C>) {
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

    fun collect_asset_fee<C>(pool_ref: &mut Pool<C>, liquidation_fee: u64) {
        let fee_extracted = coin::extract(&mut pool_ref.asset, liquidation_fee);
        treasury::collect_asset_fee<C>(fee_extracted);
    }

    fun default_storage<C,P>(): Storage<C> {
        Storage<C>{
            total_deposited: 0,
            total_conly_deposited: 0,
            total_borrowed: 0,
            last_updated: 0,
            protocol_fees: 0,
        }
    }

    fun calculate_entry_fee(value: u64): u64 {
        value * risk_factor::entry_fee() / risk_factor::precision() // TODO: rounded up
    }

    fun calculate_share_fee(value: u64): u64 {
        value * risk_factor::share_fee() / risk_factor::precision() // TODO: rounded up
    }

    fun calculate_liquidation_fee(value: u64): u64 {
        value * risk_factor::liquidation_fee() / risk_factor::precision() // TODO: rounded up
    }

    public entry fun total_deposited<C>(): u128 acquires Storage {
        borrow_global<Storage<C>>(permission::owner_address()).total_deposited
    }

    public entry fun liquidity<C>(): u128 acquires Storage {
        let storage_ref = borrow_global<Storage<C>>(permission::owner_address());
        storage_ref.total_deposited - storage_ref.total_conly_deposited
    }

    public entry fun total_conly_deposited<C>(): u128 acquires Storage {
        borrow_global<Storage<C>>(permission::owner_address()).total_conly_deposited
    }

    public entry fun total_borrowed<C>(): u128 acquires Storage {
        borrow_global<Storage<C>>(permission::owner_address()).total_borrowed
    }

    public entry fun last_updated<C>(): u64 acquires Storage {
        borrow_global<Storage<C>>(permission::owner_address()).last_updated
    }

    // #[test_only]
    // use aptos_std::debug;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::price_oracle;
    #[test_only]
    use leizd::usdz::{USDZ};
    #[test_only]
    use leizd::dummy;
    #[test_only]
    use leizd::test_coin::{Self,USDC,USDT,WETH,UNI};
    #[test_only]
    use leizd::test_initializer;

    #[test(owner=@leizd)]
    public entry fun test_init_pool(owner: &signer) acquires Pool {
        // Prerequisite
        let owner_address = signer::address_of(owner);
        account::create_account_for_test(owner_address);
        test_coin::init_weth(owner);
        test_initializer::initialize(owner);

        init_pool<WETH>(owner);

        assert!(exists<Pool<WETH>>(owner_address), 0);
        let pool = borrow_global<Pool<WETH>>(owner_address);
        assert!(pool.is_active, 0);
        assert!(coin::value<WETH>(&pool.asset) == 0, 0);
        assert!(pool_status::is_available<WETH>(), 0);
        assert!(is_pool_initialized<WETH>(), 0);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 1)]
    public entry fun test_init_pool_twice(owner: &signer) {
        // Prerequisite
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_weth(owner);
        test_initializer::initialize(owner);

        init_pool<WETH>(owner);
        init_pool<WETH>(owner);
    }

    #[test(owner=@leizd)]
    public entry fun test_is_pool_initialized(owner: &signer) {
        // Prerequisite
        let owner_address = signer::address_of(owner);
        account::create_account_for_test(owner_address);
        test_initializer::initialize(owner);
        //// init coin & pool
        test_coin::init_weth(owner);
        init_pool<WETH>(owner);
        test_coin::init_usdc(owner);
        init_pool<USDC>(owner);
        test_coin::init_usdt(owner);
        
        assert!(is_pool_initialized<WETH>(), 0);
        assert!(is_pool_initialized<USDC>(), 0);
        assert!(!is_pool_initialized<USDT>(), 0);
    }

    // for deposit
    #[test_only]
    fun setup_for_test_to_initialize_coins_and_pools(owner: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        test_initializer::initialize(owner);
        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);
        init_pool<USDC>(owner);
        init_pool<USDT>(owner);
        init_pool<WETH>(owner);
        init_pool<UNI>(owner);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH>(account, account_addr, 800000, false);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(total_deposited<WETH>() == 800000, 0);
        assert!(liquidity<WETH>() == 800000, 0);
        assert!(total_conly_deposited<WETH>() == 0, 0);
        assert!(total_borrowed<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<DepositEvent>(&event_handle.deposit_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_with_same_as_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 1000000, false);
        assert!(coin::balance<WETH>(account_addr) == 0, 0);
        assert!(total_deposited<WETH>() == 1000000, 0);
        assert!(total_conly_deposited<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_deposit_with_more_than_holding_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 1000001, false);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_twice_sequentially(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        timestamp::update_global_time_for_test(1662125899730897);
        deposit_for_internal<WETH>(account, account_addr, 400000, false);
        timestamp::update_global_time_for_test(1662125899830897);
        deposit_for_internal<WETH>(account, account_addr, 400000, false);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(total_deposited<WETH>() == 800000, 0);
        assert!(total_conly_deposited<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_by_two(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);
        managed_coin::register<WETH>(account1);
        managed_coin::register<WETH>(account2);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        managed_coin::mint<WETH>(owner, account2_addr, 1000000);

        deposit_for_internal<WETH>(account1, account1_addr, 800000, false);
        deposit_for_internal<WETH>(account2, account2_addr, 200000, false);
        assert!(coin::balance<WETH>(account1_addr) == 200000, 0);
        assert!(coin::balance<WETH>(account2_addr) == 800000, 0);
        assert!(total_deposited<WETH>() == 1000000, 0);
        assert!(total_conly_deposited<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 1)]
    public entry fun test_deposit_with_dummy_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        dummy::init_weth(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::register<dummy::WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        managed_coin::mint<dummy::WETH>(owner, account_addr, 1000000);

        deposit_for_internal<dummy::WETH>(account, account_addr, 800000, false);
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_weth_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH>(account, account_addr, 800000, true);
        assert!(coin::balance<WETH>(account_addr) == 200000, 0);
        assert!(total_deposited<WETH>() == 800000, 0);
        assert!(liquidity<WETH>() == 0, 0);
        assert!(total_conly_deposited<WETH>() == 800000, 0);
        assert!(total_borrowed<WETH>() == 0, 0);
    }

    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_with_all_patterns_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 10);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<WETH>(account, account_addr, 1, false);
        timestamp::update_global_time_for_test((initial_sec + 90) * 1000 * 1000); // + 90 sec
        deposit_for_internal<WETH>(account, account_addr, 2, true);

        assert!(total_deposited<WETH>() == 3, 0);
        assert!(liquidity<WETH>() == 1, 0);
        assert!(total_conly_deposited<WETH>() == 2, 0);
        assert!(total_borrowed<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<DepositEvent>(&event_handle.deposit_event) == 2, 0);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        // price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH>(account, account_addr, 700000, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 600000, false, 0);

        assert!(coin::balance<WETH>(account_addr) == 900000, 0);
        assert!(total_deposited<WETH>() == 100000, 0);
        assert!(liquidity<WETH>() == 100000, 0);
        assert!(total_conly_deposited<WETH>() == 0, 0);
        assert!(total_borrowed<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_same_as_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 30, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 30, false, 0);

        assert!(coin::balance<WETH>(account_addr) == 100, 0);
        assert!(total_deposited<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 50, false);
        withdraw_for_internal<WETH>(account_addr, account_addr, 51, false, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::register<USDZ>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);

        deposit_for_internal<WETH>(account, account_addr, 700000, true);
        withdraw_for_internal<WETH>(account_addr, account_addr, 600000, true, 0);

        assert!(coin::balance<WETH>(account_addr) == 900000, 0);
        assert!(total_deposited<WETH>() == 100000, 0);
        assert!(liquidity<WETH>() == 0, 0);
        assert!(total_conly_deposited<WETH>() == 100000, 0);
        assert!(total_borrowed<WETH>() == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_all_patterns_over_time(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 20);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<WETH>(account, account_addr, 10, false);
        timestamp::update_global_time_for_test((initial_sec + 150) * 1000 * 1000); // + 150 sec
        deposit_for_internal<WETH>(account, account_addr, 10, true);

        timestamp::update_global_time_for_test((initial_sec + 300) * 1000 * 1000); // + 150 sec
        withdraw_for_internal<WETH>(account_addr, account_addr, 1, false, 0);
        timestamp::update_global_time_for_test((initial_sec + 450) * 1000 * 1000); // + 150 sec
        withdraw_for_internal<WETH>(account_addr, account_addr, 2, true, 0);

        assert!(coin::balance<WETH>(account_addr) == 3, 0);
        assert!(total_deposited<WETH>() == 17, 0);
        assert!(liquidity<WETH>() == 9, 0);
        assert!(total_conly_deposited<WETH>() == 8, 0);
        assert!(total_borrowed<WETH>() == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 2, 0);
    }

    // for borrow
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_uni(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 1000000);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 800000, false);

        // borrow UNI
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 100000);
        assert!(coin::balance<UNI>(borrower_addr) == 100000, 0);
        assert!(total_deposited<UNI>() == 800000, 0);
        assert!(liquidity<UNI>() == 800000, 0);
        assert!(total_conly_deposited<UNI>() == 0, 0);
        assert!(total_borrowed<UNI>() == 100500, 0); // 100000 + 500

        // check about fee
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
        assert!(treasury::balance_of_asset<UNI>() == 500, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
        assert!(event::counter<BorrowEvent>(&event_handle.borrow_event) == 1, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_with_same_as_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 100);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        // borrow UNI
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 100);
        assert!(coin::balance<UNI>(borrower_addr) == 100, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65542)]
    fun test_borrow_with_more_than_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 100);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        // borrow UNI
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 101);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_more_than_once_sequentially(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 100);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        // borrow UNI
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 10);
        assert!(coin::balance<UNI>(borrower_addr) == 10, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 20);
        assert!(coin::balance<UNI>(borrower_addr) == 30, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 30);
        assert!(coin::balance<UNI>(borrower_addr) == 60, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 40);
        assert!(coin::balance<UNI>(borrower_addr) == 100, 0);
    }
    // TODO: pass this test
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // fun test_borrow_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     // TODO: consider HF
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     price_oracle::initialize_with_fixed_price_for_test(owner);

    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<UNI>(depositor);
    //     managed_coin::register<UNI>(borrower);
    //     managed_coin::mint<UNI>(owner, depositor_addr, 100);

    //     let initial_sec = 1648738800; // 20220401T00:00:00
    //     // deposit UNI
    //     timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
    //     deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
    //     // borrow UNI
    //     timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
    //     borrow_for_internal<UNI>(borrower_addr, borrower_addr, 10);
    //     assert!(coin::balance<UNI>(borrower_addr) == 10, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 500) * 1000 * 1000); // + 250 sec
    //     borrow_for_internal<UNI>(borrower_addr, borrower_addr, 20);
    //     assert!(coin::balance<UNI>(borrower_addr) == 30, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 750) * 1000 * 1000); // + 250 sec
    //     borrow_for_internal<UNI>(borrower_addr, borrower_addr, 30); // fail here
    //     assert!(coin::balance<UNI>(borrower_addr) == 60, 0);
    //     timestamp::update_global_time_for_test((initial_sec + 1000) * 1000 * 1000); // + 250 sec
    //     borrow_for_internal<UNI>(borrower_addr, borrower_addr, 40);
    //     assert!(coin::balance<UNI>(borrower_addr) == 100, 0);
    // }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_to_not_borrow_collateral_only(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        // TODO: consider HF
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 150);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        deposit_for_internal<UNI>(depositor, depositor_addr, 50, true);
        // borrow UNI
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 120);
        assert!(coin::balance<UNI>(borrower_addr) == 120, 0); // TODO: cannot borrow collateral_only
    }

    // for repay
    // #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_repay_uni(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     // TODO: consider HF
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     price_oracle::initialize_with_fixed_price_for_test(owner);

    //     let depositor_addr = signer::address_of(depositor);
    //     let borrower_addr = signer::address_of(borrower);
    //     account::create_account_for_test(depositor_addr);
    //     account::create_account_for_test(borrower_addr);
    //     managed_coin::register<UNI>(depositor);
    //     managed_coin::register<UNI>(borrower);
    //     managed_coin::mint<UNI>(owner, depositor_addr, 1000000);

    //     // Check status before repay
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

    //     deposit_for_internal<UNI>(depositor, depositor_addr, 1000000, false);
    //     borrow_for_internal<UNI>(borrower_addr, borrower_addr, 900000);
        
    //     debug::print(&coin::balance<UNI>(borrower_addr));
    //     account_position::initialize_if_necessary_for_test(borrower);
    //     let repaid_amount = repay_internal<UNI>(borrower, 900000);
    //     debug::print(&repaid_amount);
    //     debug::print(&coin::balance<UNI>(borrower_addr));
    //     // assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
    // }

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
        borrow_for_internal<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65541)]
    public entry fun test_cannot_repay_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        repay_internal<WETH>(owner, 0);
    }
    //// control pool status
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_deposit_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_status<WETH>(false);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_withdraw_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_status<WETH>(false);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal<WETH>(owner_address, owner_address, 0, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_borrow_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_status<WETH>(false);
        let owner_address = signer::address_of(owner);
        borrow_for_internal<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_repay_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_status<WETH>(false);
        repay_internal<WETH>(owner, 0);
    }
}