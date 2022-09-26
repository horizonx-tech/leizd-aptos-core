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
    use leizd_aptos_common::permission;
    use leizd_aptos_lib::constant;
    use leizd_aptos_external::dex_facade;
    use leizd::interest_rate;
    use leizd::pool_status;
    use leizd::risk_factor;
    use leizd::stability_pool;
    use leizd_aptos_treasury::treasury;

    friend leizd::money_market;
    friend leizd::pool_manager;

    const E_IS_ALREADY_EXISTED: u64 = 1;
    const E_IS_NOT_EXISTED: u64 = 2;
    const E_DEX_DOES_NOT_HAVE_LIQUIDITY: u64 = 3;
    const E_NOT_AVAILABLE_STATUS: u64 = 4;
    const E_AMOUNT_ARG_IS_ZERO: u64 = 11;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 12;

    /// Asset Pool where users can deposit and borrow.
    /// Each asset is separately deposited into a pool.
    struct Pool<phantom C> has key {
        asset: coin::Coin<C>,
    }

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
        rcomp: u128,
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
    public(friend) fun init_pool<C>(owner: &signer) {
        init_pool_internal<C>(owner);
    }

    fun init_pool_internal<C>(owner: &signer) {
        assert!(!is_pool_initialized<C>(), E_IS_ALREADY_EXISTED);
        assert!(dex_facade::has_liquidity<C>(), E_DEX_DOES_NOT_HAVE_LIQUIDITY);

        treasury::add_coin<C>(owner);
        risk_factor::new_asset<C>(owner);
        interest_rate::initialize<C>(owner);
        stability_pool::init_pool<C>(owner);
        pool_status::initialize<C>(owner);

        move_to(owner, Pool<C> {
            asset: coin::zero<C>()
        });
        move_to(owner, default_storage<C>());
        move_to(owner, PoolEventHandle<C> {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
            liquidate_event: account::new_event_handle<LiquidateEvent>(owner),
        });
    }
    fun default_storage<C>(): Storage<C> {
        Storage<C>{
            total_deposited: 0,
            total_conly_deposited: 0,
            total_borrowed: 0,
            last_updated: 0,
            protocol_fees: 0,
            rcomp: 0,
        }
    }

    /// Deposits an asset or a shadow to the pool.
    /// If a user wants to protect the asset, it's possible that it can be used only for the collateral.
    /// C is a pool type and a user should select which pool to use.
    /// e.g. Deposit USDZ for WETH Pool -> deposit_for<WETH,Shadow>(x,x,x,x)
    /// e.g. Deposit WBTC for WBTC Pool -> deposit_for<WBTC,Asset>(x,x,x,x)
    public(friend) fun deposit_for<C>(
        account: &signer,
        for_address: address,
        amount: u64,
        is_collateral_only: bool,
    ) acquires Pool, Storage, PoolEventHandle {
        deposit_for_internal<C>(
            account,
            for_address,
            amount,
            is_collateral_only
        );
    }

    fun deposit_for_internal<C>(
        account: &signer,
        for_address: address, // TODO: use to control target deposited
        amount: u64,
        is_collateral_only: bool,
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_deposit<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let storage_ref = borrow_global_mut<Storage<C>>(owner_address);
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);

        accrue_interest<C>(storage_ref);

        coin::merge(&mut pool_ref.asset, coin::withdraw<C>(account, amount));
        storage_ref.total_deposited = storage_ref.total_deposited + (amount as u128);
        if (is_collateral_only) {
            storage_ref.total_conly_deposited = storage_ref.total_conly_deposited + (amount as u128);
        };
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).deposit_event,
            DepositEvent {
                caller: signer::address_of(account),
                receiver: for_address,
                amount,
                is_collateral_only,
            },
        );
    }

    /// Withdraws an asset or a shadow from the pool.
    public(friend) fun withdraw_for<C>(
        caller_addr: address,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool
    ): u64 acquires Pool, Storage, PoolEventHandle {
        withdraw_for_internal<C>(
            caller_addr,
            receiver_addr,
            amount,
            is_collateral_only,
            0
        )
    }

    fun withdraw_for_internal<C>(
        caller_addr: address,
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64,
    ): u64 acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_withdraw<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let storage_ref = borrow_global_mut<Storage<C>>(owner_address);

        accrue_interest<C>(storage_ref);
        collect_asset_fee<C>(pool_ref, liquidation_fee);

        let amount_to_transfer = amount - liquidation_fee;
        coin::deposit<C>(receiver_addr, coin::extract(&mut pool_ref.asset, amount_to_transfer));
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
                caller: caller_addr,
                receiver: receiver_addr,
                amount,
                is_collateral_only,
            },
        );
        (withdrawn_amount as u64)
    }

    /// Borrows an asset or a shadow from the pool.
    public(friend) fun borrow_for<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
    ): u64 acquires Pool, Storage, PoolEventHandle {
        borrow_for_internal<C>(borrower_addr, receiver_addr, amount)
    }

    fun borrow_for_internal<C>(
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
    ): u64 acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_borrow<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let storage_ref = borrow_global_mut<Storage<C>>(owner_address);

        accrue_interest<C>(storage_ref);

        let fee = risk_factor::calculate_entry_fee(amount);
        let amount_with_fee = amount + fee;
        assert!((amount_with_fee as u128) <= liquidity_internal(pool_ref, storage_ref), error::invalid_argument(E_INSUFFICIENT_LIQUIDITY));

        collect_asset_fee<C>(pool_ref, fee);
        let borrowed = coin::extract(&mut pool_ref.asset, amount);
        coin::deposit<C>(receiver_addr, borrowed);

        storage_ref.total_borrowed = storage_ref.total_borrowed + (amount_with_fee as u128);

        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).borrow_event,
            BorrowEvent {
                caller: borrower_addr,
                borrower: borrower_addr,
                receiver: receiver_addr,
                amount: amount_with_fee,
            },
        );

        amount_with_fee
    }

    /// Repays an asset or a shadow for the borrowed position.
    public(friend) fun repay<C>(
        account: &signer,
        amount: u64,
    ): u64 acquires Pool, Storage, PoolEventHandle {
        repay_internal<C>(account, amount)
    }

    fun repay_internal<C>(
        account: &signer,
        amount: u64,
    ): u64 acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::can_repay<C>(), error::invalid_state(E_NOT_AVAILABLE_STATUS));
        assert!(amount > 0, error::invalid_argument(E_AMOUNT_ARG_IS_ZERO));

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<Pool<C>>(owner_address);
        let storage_ref = borrow_global_mut<Storage<C>>(owner_address);

        accrue_interest<C>(storage_ref);

        let account_addr = signer::address_of(account);
        storage_ref.total_borrowed = storage_ref.total_borrowed - (amount as u128);
        let withdrawn = coin::withdraw<C>(account, amount);
        coin::merge(&mut pool_ref.asset, withdrawn);

        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).repay_event,
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
        let storage_ref = borrow_global_mut<Storage<C>>(owner_address);
        accrue_interest<C>(storage_ref);
        withdraw_for_internal<C>(liquidator_addr, target_addr, liquidated, is_collateral_only, liquidation_fee);

        event::emit_event<LiquidateEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(owner_address).liquidate_event,
            LiquidateEvent {
                caller: liquidator_addr,
                target: target_addr,
                amount: liquidated
            }
        );
    }

    public fun is_pool_initialized<C>(): bool {
        exists<Pool<C>>(permission::owner_address())
    }

    /// This function is called on every user action.
    fun accrue_interest<C>(storage_ref: &mut Storage<C>) {
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
        storage_ref.rcomp = rcomp;
    }

    fun collect_asset_fee<C>(pool_ref: &mut Pool<C>, fee: u64) {
        if (fee > 0) {
            let fee_extracted = coin::extract(&mut pool_ref.asset, fee);
            treasury::collect_asset_fee<C>(fee_extracted);
        };
    }

    public entry fun total_deposited<C>(): u128 acquires Storage {
        borrow_global<Storage<C>>(permission::owner_address()).total_deposited
    }

    public entry fun liquidity<C>(): u128 acquires Pool, Storage {
        let owner_addr = permission::owner_address();
        let pool_ref = borrow_global<Pool<C>>(owner_addr);
        let storage_ref = borrow_global<Storage<C>>(owner_addr);
        liquidity_internal(pool_ref, storage_ref)
    }
    fun liquidity_internal<C>(pool: &Pool<C>, storage: &Storage<C>): u128 {
        (coin::value(&pool.asset) as u128) - storage.total_conly_deposited
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
    use leizd_aptos_trove::usdz::{USDZ};
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
        assert!(coin::value<WETH>(&pool.asset) == 0, 0);
        assert!(pool_status::can_deposit<WETH>(), 0);
        assert!(pool_status::can_withdraw<WETH>(), 0);
        assert!(pool_status::can_borrow<WETH>(), 0);
        assert!(pool_status::can_repay<WETH>(), 0);
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
    #[expected_failure(abort_code = 393217)]
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
        // test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        let borrowed = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 100000);
        assert!(borrowed == 100500, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 100000, 0);
        assert!(total_deposited<UNI>() == 800000, 0);
        assert!(liquidity<UNI>() == 699500, 0);
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
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 1000 + 5);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        //// deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 1000 + 5, false);
        //// borrow UNI
        let borrowed = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(borrowed == 1005, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 1000, 0);
        assert!(treasury::balance_of_asset<UNI>() == 5, 0);
        assert!(pool_asset_value<UNI>(signer::address_of(owner)) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65548)]
    fun test_borrow_with_more_than_deposited_amount(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

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
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 10000 + 5 * 10);

        // Prerequisite
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        //// deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 10000 + 5 * 10, false);
        //// borrow UNI
        let borrowed = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(borrowed == 1005, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 1000, 0);
        assert!(total_borrowed<UNI>() == 1000 + 5 * 1, 0);
        let borrowed = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 2000);
        assert!(borrowed == 2010, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 3000, 0);
        assert!(total_borrowed<UNI>() == 3000 + 5 * 3, 0);
        let borrowed = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 3000);
        assert!(borrowed == 3015, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 6000, 0);
        assert!(total_borrowed<UNI>() == 6000 + 5 * 6, 0);
        let borrowed = borrow_for_internal<UNI>(borrower_addr, borrower_addr, 4000);
        assert!(borrowed == 4020, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 10000, 0);
        assert!(total_borrowed<UNI>() == 10000 + 5 * 10, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    fun test_borrow_more_than_once_sequentially_over_time(owner: &signer, depositor: &signer, borrower: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        test_initializer::initialize_price_oracle_with_fixed_price_for_test(owner);

        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 100);

        let initial_sec = 1648738800; // 20220401T00:00:00
        // deposit UNI
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        // borrow UNI
        timestamp::update_global_time_for_test((initial_sec + 250) * 1000 * 1000); // + 250 sec
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 10);
        assert!(coin::balance<UNI>(borrower_addr) == 10, 0);
        timestamp::update_global_time_for_test((initial_sec + 500) * 1000 * 1000); // + 250 sec
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 20);
        assert!(coin::balance<UNI>(borrower_addr) == 30, 0);
        // timestamp::update_global_time_for_test((initial_sec + 750) * 1000 * 1000); // + 250 sec
        // borrow_for_internal<UNI>(borrower_addr, borrower_addr, 30); // TODO: fail here
        // assert!(coin::balance<UNI>(borrower_addr) == 60, 0);
        // timestamp::update_global_time_for_test((initial_sec + 1000) * 1000 * 1000); // + 250 sec
        // borrow_for_internal<UNI>(borrower_addr, borrower_addr, 40);
        // assert!(coin::balance<UNI>(borrower_addr) == 100, 0);
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
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);
        managed_coin::mint<UNI>(owner, depositor_addr, 150);

        // deposit UNI
        deposit_for_internal<UNI>(depositor, depositor_addr, 100, false);
        deposit_for_internal<UNI>(depositor, depositor_addr, 50, true);
        // borrow UNI
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 120);
    }

    // for repay
    #[test_only]
    fun pool_asset_value<C>(addr: address): u64 acquires Pool {
        coin::value(&borrow_global<Pool<C>>(addr).asset)
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
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        assert!(pool_asset_value<UNI>(owner_address) == 1005, 0);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        assert!(pool_asset_value<UNI>(owner_address) == 0, 0);
        let repaid_amount = repay_internal<UNI>(borrower, 900);
        assert!(repaid_amount == 900, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 900, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 100, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
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
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        let repaid_amount = repay_internal<UNI>(borrower, 1000);
        assert!(repaid_amount == 1000, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 1000, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);
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
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        repay_internal<UNI>(borrower, 1001);
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
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 1005);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);
        let repaid_amount = repay_internal<UNI>(borrower, 100);
        assert!(repaid_amount == 100, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 100, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 900, 0);
        let repaid_amount = repay_internal<UNI>(borrower, 200);
        assert!(repaid_amount == 200, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 300, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 700, 0);
        let repaid_amount = repay_internal<UNI>(borrower, 300);
        assert!(repaid_amount == 300, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 600, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 400, 0);
        let repaid_amount = repay_internal<UNI>(borrower, 400);
        assert!(repaid_amount == 400, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 1000, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
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
        managed_coin::register<UNI>(depositor);
        managed_coin::register<UNI>(borrower);

        // Check status before repay
        assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);

        // execute
        managed_coin::mint<UNI>(owner, depositor_addr, 1005);

        let initial_sec = 1648738800; // 20220401T00:00:00
        timestamp::update_global_time_for_test(initial_sec * 1000 * 1000);
        deposit_for_internal<UNI>(depositor, depositor_addr, 1005, false);
        timestamp::update_global_time_for_test((initial_sec + 80) * 1000 * 1000); // + 80 sec
        borrow_for_internal<UNI>(borrower_addr, borrower_addr, 1000);

        timestamp::update_global_time_for_test((initial_sec + 160) * 1000 * 1000); // + 80 sec
        let repaid_amount = repay_internal<UNI>(borrower, 100);
        assert!(repaid_amount == 100, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 100, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 900, 0);
        timestamp::update_global_time_for_test((initial_sec + 240) * 1000 * 1000); // + 80 sec
        let repaid_amount = repay_internal<UNI>(borrower, 200);
        assert!(repaid_amount == 200, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 300, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 700, 0);
        timestamp::update_global_time_for_test((initial_sec + 320) * 1000 * 1000); // + 80 sec
        let repaid_amount = repay_internal<UNI>(borrower, 300);
        assert!(repaid_amount == 300, 0);
        assert!(pool_asset_value<UNI>(owner_address) == 600, 0);
        assert!(coin::balance<UNI>(borrower_addr) == 400, 0);

        // timestamp::update_global_time_for_test((initial_sec + 400) * 1000 * 1000); // + 80 sec
        // let repaid_amount = repay_internal<UNI>(borrower, 400); // TODO: fail here
        // assert!(repaid_amount == 400, 0);
        // assert!(pool_asset_value<UNI>(owner_address) == 1000, 0);
        // assert!(coin::balance<UNI>(borrower_addr) == 0, 0);

        let event_handle = borrow_global<PoolEventHandle<UNI>>(signer::address_of(owner));
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
        managed_coin::register<WETH>(depositor);
        managed_coin::register<WETH>(liquidator);
        managed_coin::mint<WETH>(owner, depositor_addr, 1001);

        deposit_for_internal<WETH>(depositor, depositor_addr, 1001, false);
        assert!(pool_asset_value<WETH>(owner_address) == 1001, 0);
        assert!(total_deposited<WETH>() == 1001, 0);
        assert!(total_conly_deposited<WETH>() == 0, 0);
        assert!(coin::balance<WETH>(depositor_addr) == 0, 0);
        assert!(coin::balance<WETH>(liquidator_addr) == 0, 0);

        liquidate_internal<WETH>(liquidator_addr, liquidator_addr, 1001, false);
        assert!(pool_asset_value<WETH>(owner_address) == 0, 0);
        assert!(total_deposited<WETH>() == 0, 0);
        assert!(total_conly_deposited<WETH>() == 0, 0);
        assert!(coin::balance<WETH>(depositor_addr) == 0, 0);
        assert!(coin::balance<WETH>(liquidator_addr) == 995, 0);
        assert!(treasury::balance_of_asset<WETH>() == 6, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<LiquidateEvent>(&event_handle.liquidate_event) == 1, 0);
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
        borrow_for_internal<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65547)]
    public entry fun test_cannot_repay_when_amount_is_zero(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        repay_internal<WETH>(owner, 0);
    }
    //// control pool status
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_deposit_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_deposit_status<WETH>(false);
        deposit_for_internal<WETH>(owner, signer::address_of(owner), 0, false);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_withdraw_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_withdraw_status<WETH>(false);
        let owner_address = signer::address_of(owner);
        withdraw_for_internal<WETH>(owner_address, owner_address, 0, false, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_borrow_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_borrow_status<WETH>(false);
        let owner_address = signer::address_of(owner);
        borrow_for_internal<WETH>(owner_address, owner_address, 0);
    }
    #[test(owner=@leizd, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 196612)]
    public entry fun test_cannot_repay_when_not_available(owner: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        pool_status::update_repay_status<WETH>(false);
        repay_internal<WETH>(owner, 0);
    }
}
