/// Main point of interaction with Leizd Protocol
/// Users can:
/// # Deposit
/// # Withdraw
/// # Borrow
/// # Repay
/// # Liquidate
/// # Rebalance
module leizd::asset_pool {

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
        assert!(pool_status::is_available<C>(), 0);

        let storage_ref = borrow_global_mut<Storage<C>>(@leizd);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        coin::merge(&mut pool_ref.asset, coin::withdraw<C>(account, amount));
        storage_ref.total_deposited = storage_ref.total_deposited + (amount as u128);
        if (is_collateral_only) {
            storage_ref.total_conly_deposited = storage_ref.total_conly_deposited + (amount as u128);
        };
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).deposit_event,
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
        receiver_addr: address,
        amount: u64,
        is_collateral_only: bool
    ): u64 acquires Pool, Storage, PoolEventHandle {
        withdraw_for_internal<C>(
            receiver_addr,
            amount,
            is_collateral_only,
            0
        )
    }

    fun withdraw_for_internal<C>(
        reciever_addr: address,
        amount: u64,
        is_collateral_only: bool,
        liquidation_fee: u64,
    ): u64 acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::is_available<C>(), 0);

        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C>>(@leizd);

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

        // TODO: assert!(is_asset_solvent<C>(signer::address_of(depositor)),0);
        
        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).withdraw_event,
            WithdrawEvent {
                caller: reciever_addr,
                depositor: reciever_addr,
                receiver: reciever_addr,
                amount,
                is_collateral_only,
                is_shadow: false
            },
        );
        (withdrawn_amount as u64)
    }

    /// Borrows an asset or a shadow from the pool.
    public(friend) fun borrow_for<C,P>(
        account: &signer,
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
    ) acquires Pool, Storage, PoolEventHandle {
        borrow_for_internal<C,P>(account, borrower_addr, receiver_addr, amount);
    }

    fun borrow_for_internal<C,P>(
        account: &signer,
        borrower_addr: address,
        receiver_addr: address,
        amount: u64,
    ) acquires Pool, Storage, PoolEventHandle {
        assert!(pool_status::is_available<C>(), 0);

        // borrow_asset<C>(borrower_addr, receiver_addr, amount);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        let fee = calculate_entry_fee(amount);
        collect_asset_fee<C>(pool_ref, fee);

        let deposited = coin::extract(&mut pool_ref.asset, amount);
        coin::deposit<C>(receiver_addr, deposited);
        storage_ref.total_borrowed = storage_ref.total_borrowed + (amount as u128) + (fee as u128);
        // TODO: assert!(is_asset_solvent<C>(borrower_addr),0);
        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).borrow_event,
            BorrowEvent {
                caller: signer::address_of(account),
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
        assert!(pool_status::is_available<C>(), 0);

        let account_addr = signer::address_of(account);
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global_mut<Storage<C>>(@leizd);

        accrue_interest<C,Asset>(storage_ref);

        let debt_amount = account_position::borrowed_shadow<C>(account_addr);
        let repaid_amount = if (amount >= debt_amount) debt_amount else amount;
        storage_ref.total_borrowed = storage_ref.total_borrowed - (repaid_amount as u128);
        let withdrawn = coin::withdraw<C>(account, repaid_amount);
        coin::merge(&mut pool_ref.asset, withdrawn);

        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).repay_event,
            RepayEvent {
                caller: signer::address_of(account),
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
    //         &mut borrow_global_mut<PoolEventHandle<C>>(@leizd).liquidate_event,
    //         LiquidateEvent {
    //             caller: signer::address_of(account),
    //             target: target_addr,
    //             is_shadow
    //         }
    //     )
    // }

    public fun is_pool_initialized<C>(): bool {
        exists<Pool<C>>(@leizd)
    }

    // public entry fun is_asset_solvent<C>(account_addr: address): bool {
    //     is_solvent<C,Asset,Shadow>(account_addr)
    // }

    // public entry fun is_shadow_solvent<C>(account_addr: address): bool {
    //     is_solvent<C,Shadow,Asset>(account_addr)
    // }

    // fun is_solvent<COIN,COL,DEBT>(account_addr: address): bool {
    //     let user_ltv = user_ltv<COIN,COL,DEBT>(account_addr);
    //     user_ltv <= risk_factor::lt<COIN>() / constant::e18_u64()
    // }

    // public fun user_ltv<COIN,COL,DEBT>(account_addr: address): u64 {
    //     let collateral = collateral::balance_of<COIN,COL>(account_addr) + collateral_only::balance_of<COIN,COL>(account_addr);
    //     let collateral_value = collateral * price_oracle::price<COIN>();
    //     let debt = debt::balance_of<COIN,DEBT>(account_addr);
    //     let debt_value = debt * price_oracle::price<COIN>();

    //     let user_ltv = if (debt_value == 0) 0 else collateral_value / debt_value;
    //     user_ltv
    // }

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

    public entry fun liquidity<C>(): u128 acquires Storage, Pool {
        let pool_ref = borrow_global_mut<Pool<C>>(@leizd);
        let storage_ref = borrow_global<Storage<C>>(@leizd);
        (coin::value(&pool_ref.asset) as u128) - storage_ref.total_conly_deposited
    }

    public entry fun total_deposited<C,P>(): u128 acquires Storage {
        borrow_global<Storage<C>>(@leizd).total_deposited
    }

    public entry fun total_conly_deposited<C,P>(): u128 acquires Storage {
        borrow_global<Storage<C>>(@leizd).total_conly_deposited
    }

    public entry fun total_borrowed<C,P>(): u128 acquires Storage {
        borrow_global<Storage<C>>(@leizd).total_borrowed
    }

    public entry fun last_updated<C,P>(): u64 acquires Storage {
        borrow_global<Storage<C>>(@leizd).last_updated
    }

    // #[test_only]
    // use aptos_std::debug;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::test_coin::{Self,USDC,USDT,WETH,UNI};
    #[test_only]
    use leizd::dummy;
    // #[test_only]
    // use leizd::usdz;
    #[test_only]
    use leizd::test_initializer;
    #[test_only]
    use leizd::price_oracle;
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
        assert!(total_deposited<WETH,Asset>() == 800000, 0);
        assert!(total_conly_deposited<WETH,Asset>() == 0, 0);

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
        assert!(total_deposited<WETH,Asset>() == 1000000, 0);
        assert!(total_conly_deposited<WETH,Asset>() == 0, 0);
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
        assert!(total_deposited<WETH,Asset>() == 800000, 0);
        assert!(total_conly_deposited<WETH,Asset>() == 0, 0);
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
        assert!(total_deposited<WETH,Asset>() == 1000000, 0);
        assert!(total_conly_deposited<WETH,Asset>() == 0, 0);
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
        assert!(total_deposited<WETH,Asset>() == 800000, 0);
        assert!(total_conly_deposited<WETH,Asset>() == 800000, 0);
    }

    // #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    // public entry fun test_deposit_with_all_patterns(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     let account_addr = signer::address_of(account);
    //     account::create_account_for_test(account_addr);
    //     managed_coin::register<WETH>(account);
    //     managed_coin::register<USDZ>(account);

    //     managed_coin::mint<WETH>(owner, account_addr, 10);
    //     usdz::mint_for_test(account_addr, 10);

    //     deposit_for_internal<WETH,Asset>(account, account_addr, 1, false);
    //     deposit_for_internal<WETH,Asset>(account, account_addr, 2, true);
    //     deposit_for_internal<WETH,Shadow>(account, account_addr, 3, false);
    //     deposit_for_internal<WETH,Shadow>(account, account_addr, 4, true);

    //     assert!(coin::balance<WETH>(account_addr) == 7, 0);
    //     assert!(coin::balance<USDZ>(account_addr) == 3, 0);
    //     assert!(total_deposited<WETH,Asset>() == 1, 0);
    //     assert!(total_conly_deposited<WETH,Asset>() == 2, 0);
    //     assert!(total_deposited<WETH,Shadow>() == 3, 0);
    //     assert!(total_conly_deposited<WETH,Shadow>() == 4, 0);
    //     // assert!(liquidity<WETH>(false) == 1, 0);
    //     // assert!(liquidity<WETH>(true) == 3, 0);
    //     assert!(collateral::balance_of<WETH, Asset>(account_addr) == 1, 0);
    //     assert!(collateral_only::balance_of<WETH, Asset>(account_addr) == 2, 0);
    //     assert!(collateral::balance_of<WETH, Shadow>(account_addr) == 3, 0);
    //     assert!(collateral_only::balance_of<WETH, Shadow>(account_addr) == 4, 0);

    //     let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
    //     assert!(event::counter<DepositEvent>(&event_handle.deposit_event) == 4, 0);
    // }

    // for withdraw
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_weth(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        // price_oracle::initialize_oracle_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 1000000);
        assert!(coin::balance<WETH>(account_addr) == 1000000, 0);

        deposit_for_internal<WETH>(account, account_addr, 700000, false);
        withdraw_for_internal<WETH>(account_addr, 600000, false, 0);

        assert!(coin::balance<WETH>(account_addr) == 900000, 0);
        assert!(total_deposited<WETH,Asset>() == 100000, 0);

        let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
        assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 1, 0);
    }
    #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_with_same_as_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
        setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
        price_oracle::initialize_oracle_for_test(owner);

        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<WETH>(account);
        managed_coin::mint<WETH>(owner, account_addr, 100);

        deposit_for_internal<WETH>(account, account_addr, 30, false);
        withdraw_for_internal<WETH>(account_addr, 30, false, 0);

        assert!(coin::balance<WETH>(account_addr) == 100, 0);
        // assert!(collateral::balance_of<WETH, Asset>(account_addr) == 0, 0);
        assert!(total_deposited<WETH,Asset>() == 0, 0);
    }
    // #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    // #[expected_failure(abort_code = 65542)]
    // public entry fun test_withdraw_with_more_than_deposited_amount(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     price_oracle::initialize_oracle_for_test(owner);

    //     let account_addr = signer::address_of(account);
    //     account::create_account_for_test(account_addr);
    //     managed_coin::register<WETH>(account);
    //     managed_coin::mint<WETH>(owner, account_addr, 100);

    //     deposit_for_internal<WETH,Asset>(account, account_addr, 50, false);
    //     withdraw_for_internal<WETH,Asset>(account, account_addr, 51, false);
    // }
    // #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    // public entry fun test_withdraw_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     price_oracle::initialize_oracle_for_test(owner);

    //     let account_addr = signer::address_of(account);
    //     account::create_account_for_test(account_addr);
    //     managed_coin::register<WETH>(account);
    //     managed_coin::register<USDZ>(account);
    //     managed_coin::mint<WETH>(owner, account_addr, 1000000);

    //     deposit_for_internal<WETH,Asset>(account, account_addr, 700000, true);
    //     withdraw_for_internal<WETH,Asset>(account, account_addr, 600000, true);

    //     assert!(coin::balance<WETH>(account_addr) == 900000, 0);
    //     assert!(total_deposited<WETH,Asset>() == 0, 0);
    //     assert!(total_conly_deposited<WETH,Asset>() == 100000, 0);
    //     assert!(collateral::balance_of<WETH, Asset>(account_addr) == 0, 0);
    //     assert!(collateral_only::balance_of<WETH, Asset>(account_addr) == 100000, 0);
    // }
    // #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    // public entry fun test_withdraw_shadow(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     price_oracle::initialize_oracle_for_test(owner);

    //     let account_addr = signer::address_of(account);
    //     account::create_account_for_test(account_addr);
    //     managed_coin::register<WETH>(account);
    //     managed_coin::register<USDZ>(account);
    //     usdz::mint_for_test(account_addr, 1000000);

    //     deposit_for_internal<WETH,Shadow>(account, account_addr, 700000, false);
    //     withdraw_for_internal<WETH,Shadow>(account, account_addr, 600000, false);

    //     assert!(coin::balance<WETH>(account_addr) == 0, 0);
    //     assert!(coin::balance<USDZ>(account_addr) == 900000, 0);
    //     assert!(total_deposited<WETH,Shadow>() == 100000, 0);
    //     assert!(total_conly_deposited<WETH,Shadow>() == 0, 0);
    //     assert!(collateral::balance_of<WETH, Shadow>(account_addr) == 100000, 0);
    //     assert!(collateral_only::balance_of<WETH, Shadow>(account_addr) == 0, 0);
    // }
    // #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    // public entry fun test_withdraw_shadow_for_only_collateral(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     price_oracle::initialize_oracle_for_test(owner);

    //     let account_addr = signer::address_of(account);
    //     account::create_account_for_test(account_addr);
    //     managed_coin::register<WETH>(account);
    //     managed_coin::register<USDZ>(account);
    //     usdz::mint_for_test(account_addr, 1000000);

    //     deposit_for_internal<WETH,Shadow>(account, account_addr, 700000, true);
    //     withdraw_for_internal<WETH,Shadow>(account, account_addr, 600000, true);

    //     assert!(coin::balance<WETH>(account_addr) == 0, 0);
    //     assert!(coin::balance<USDZ>(account_addr) == 900000, 0);
    //     assert!(total_deposited<WETH,Asset>() == 0, 0);
    //     assert!(total_deposited<WETH,Shadow>() == 0, 0);
    //     assert!(total_conly_deposited<WETH,Asset>() == 0, 0);
    //     assert!(total_conly_deposited<WETH,Shadow>() == 100000, 0);
    //     assert!(collateral::balance_of<WETH, Shadow>(account_addr) == 0, 0);
    //     assert!(collateral_only::balance_of<WETH, Shadow>(account_addr) == 100000, 0);
    // }
    // #[test(owner=@leizd,account=@0x111,aptos_framework=@aptos_framework)]
    // public entry fun test_withdraw_with_all_patterns(owner: &signer, account: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     price_oracle::initialize_oracle_for_test(owner);

    //     let account_addr = signer::address_of(account);
    //     account::create_account_for_test(account_addr);
    //     managed_coin::register<WETH>(account);
    //     managed_coin::register<USDZ>(account);

    //     managed_coin::mint<WETH>(owner, account_addr, 20);
    //     usdz::mint_for_test(account_addr, 20);

    //     deposit_for_internal<WETH,Asset>(account, account_addr, 10, false);
    //     deposit_for_internal<WETH,Asset>(account, account_addr, 10, true);
    //     deposit_for_internal<WETH,Shadow>(account, account_addr, 10, false);
    //     deposit_for_internal<WETH,Shadow>(account, account_addr, 10, true);

    //     withdraw_for_internal<WETH,Asset>(account, account_addr, 1, false);
    //     withdraw_for_internal<WETH,Asset>(account, account_addr, 2, true);
    //     withdraw_for_internal<WETH,Shadow>(account, account_addr, 3, false);
    //     withdraw_for_internal<WETH,Shadow>(account, account_addr, 4, true);

    //     assert!(coin::balance<WETH>(account_addr) == 3, 0);
    //     assert!(coin::balance<USDZ>(account_addr) == 7, 0);
    //     assert!(total_deposited<WETH,Asset>() == 9, 0);
    //     assert!(total_conly_deposited<WETH,Asset>() == 8, 0);
    //     assert!(total_deposited<WETH,Shadow>() == 7, 0);
    //     assert!(total_conly_deposited<WETH,Shadow>() == 6, 0);
    //     // assert!(liquidity<WETH>(false) == 9, 0);
    //     // assert!(liquidity<WETH>(true) == 7, 0);

    //     assert!(collateral::balance_of<WETH, Asset>(account_addr) == 9, 0);
    //     assert!(collateral_only::balance_of<WETH, Asset>(account_addr) == 8, 0);
    //     assert!(collateral::balance_of<WETH, Shadow>(account_addr) == 7, 0);
    //     assert!(collateral_only::balance_of<WETH, Shadow>(account_addr) == 6, 0);

    //     let event_handle = borrow_global<PoolEventHandle<WETH>>(signer::address_of(owner));
    //     assert!(event::counter<WithdrawEvent>(&event_handle.withdraw_event) == 4, 0);
    // }

    // // for borrow
    // #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_borrow_uni(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     price_oracle::initialize_oracle_for_test(owner);

    //     let account1_addr = signer::address_of(account1);
    //     let account2_addr = signer::address_of(account2);
    //     account::create_account_for_test(account1_addr);
    //     account::create_account_for_test(account2_addr);
    //     managed_coin::register<WETH>(account1);
    //     managed_coin::register<UNI>(account1);
    //     managed_coin::register<USDZ>(account1);
    //     managed_coin::register<WETH>(account2);
    //     managed_coin::register<UNI>(account2);
    //     managed_coin::register<USDZ>(account2);

    //     managed_coin::mint<UNI>(owner, account1_addr, 1000000);
    //     usdz::mint_for_test(account1_addr, 1000000);

    //     managed_coin::mint<WETH>(owner, account2_addr, 1000000);

    //     // Lender: 
    //     // deposit USDZ for WETH
    //     // deposit UNI
    //     deposit_for_internal<WETH,Shadow>(account1, account1_addr, 800000, false);
    //     deposit_for_internal<UNI,Asset>(account1, account1_addr, 800000, false);

    //     // Borrower:
    //     // deposit WETH
    //     // borrow  USDZ
    //     deposit_for_internal<WETH,Asset>(account2, account2_addr, 600000, false);
    //     borrow_for_internal<WETH,Shadow>(account2, account2_addr, account2_addr, 300000);
    //     assert!(coin::balance<WETH>(account2_addr) == 400000, 0);
    //     assert!(coin::balance<USDZ>(account2_addr) == 300000, 0);

    //     // Borrower:
    //     // deposit USDZ for UNI
    //     // borrow UNI
    //     deposit_for_internal<UNI,Shadow>(account2, account2_addr, 200000, false);
    //     borrow_for_internal<UNI,Asset>(account2, account2_addr, account2_addr, 100000);
    //     assert!(coin::balance<UNI>(account2_addr) == 100000, 0);
    //     assert!(coin::balance<USDZ>(account2_addr) == 100000, 0);

    //     // check about fee
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
    //     assert!(debt::balance_of<WETH,Shadow>(account2_addr) == 301500, 0);
    //     assert!(debt::balance_of<UNI,Asset>(account2_addr) == 100500, 0);
    //     assert!(treasury::balance_of_shadow<WETH>() == 1500, 0);
    //     assert!(treasury::balance_of_asset<UNI>() == 500, 0);
    // }
    // #[test(owner=@leizd,lender=@0x111,borrower=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_borrow_(owner: &signer, aptos_framework: &signer) {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    // }

    // // for repay
    // #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    // public entry fun test_repay_uni(owner: &signer, account1: &signer, account2: &signer, aptos_framework: &signer) acquires Pool, Storage, PoolEventHandle {
    //     setup_for_test_to_initialize_coins_and_pools(owner, aptos_framework);
    //     price_oracle::initialize_oracle_for_test(owner);

    //     let account1_addr = signer::address_of(account1);
    //     let account2_addr = signer::address_of(account2);
    //     account::create_account_for_test(account1_addr);
    //     account::create_account_for_test(account2_addr);
    //     managed_coin::register<WETH>(account1);
    //     managed_coin::register<UNI>(account1);
    //     managed_coin::register<USDZ>(account1);
    //     managed_coin::register<WETH>(account2);
    //     managed_coin::register<UNI>(account2);
    //     managed_coin::register<USDZ>(account2);

    //     usdz::mint_for_test(account1_addr, 1000000);
    //     managed_coin::mint<UNI>(owner, account1_addr, 1000000);
    //     managed_coin::mint<WETH>(owner, account2_addr, 1000000);

    //     // Lender: 
    //     // deposit USDZ for WETH
    //     // deposit UNI
    //     deposit_for_internal<WETH,Shadow>(account1, account1_addr, 800000, false);
    //     deposit_for_internal<UNI,Asset>(account1, account1_addr, 800000, false);

    //     // Borrower:
    //     // deposit WETH
    //     // borrow  USDZ
    //     deposit_for_internal<WETH,Asset>(account2, account2_addr, 600000, false);
    //     borrow_for_internal<WETH,Shadow>(account2, account2_addr, account2_addr, 300000);

    //     // Borrower:
    //     // deposit USDZ for UNI
    //     // borrow UNI
    //     deposit_for_internal<UNI,Shadow>(account2, account2_addr, 200000, false);
    //     borrow_for_internal<UNI,Asset>(account2, account2_addr, account2_addr, 100000);

    //     // Check status before repay
    //     assert!(risk_factor::entry_fee() == risk_factor::default_entry_fee(), 0);
    //     assert!(debt::balance_of<WETH,Shadow>(account2_addr) == 301500, 0);
    //     assert!(debt::balance_of<UNI,Asset>(account2_addr) == 100500, 0);
        
    //     // Borrower:
    //     // repay UNI
    //     repay_internal<UNI,Asset>(account2, 100000);
    //     assert!(coin::balance<UNI>(account2_addr) == 0, 0);
    //     assert!(coin::balance<USDZ>(account2_addr) == 100000, 0);
    //     assert!(debt::balance_of<UNI,Asset>(account2_addr) == 500, 0); // TODO: 0.5% entry fee + 0.0% interest

    //     // Borrower:
    //     // repay USDZ

    //     // withdraw<UNI>(account2, 200000, false, true); // TODO: error in position#update_position (EKEY_ALREADY_EXISTS)
    //     // repay<WETH>(account2, 300000, true);
    //     // assert!(coin::balance<USDZ>(account2_addr) == 0, 0);
    //     // assert!(debt::balance_of<WETH,Shadow>(account2_addr) == 1500, 0);
    // }
}