module leizd::stability_pool {

    use std::error;
    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use leizd::usdz::{USDZ};
    use leizd::stb_usdz;
    use leizd::permission;

    friend leizd::asset_pool;
    friend leizd::shadow_pool;

    const PRECISION: u64 = 1000000000;
    const STABILITY_FEE: u64 = 1000000000 * 5 / 1000; // 0.5%

    const EALREADY_INITIALIZED: u64 = 1;
    const EINVALID_AMOUNT: u64 = 2;
    const EEXCEED_REMAINING_AMOUNT: u64 = 3;

    struct StabilityPool has key {
        left: coin::Coin<USDZ>,
        total_deposited: u128,
        collected_fee: coin::Coin<USDZ>,
    }

    struct Balance<phantom C> has key {
        total_borrowed: u128,
        uncollected_fee: u64,
    }

    struct DistributionConfig has key {
        emission_per_sec: u64,
        last_updated: u64,
        index: u64,
    }

    struct UserDistribution has key {
        index: u64,
        unclaimed: u64,
        deposited: u64,
    }

    // events
    struct DepositEvent has store, drop {
        caller: address,
        target_account: address,
        amount: u64
    }
    struct WithdrawEvent has store, drop {
        caller: address,
        target_account: address,
        amount: u64
    }
    struct BorrowEvent has store, drop {
        caller: address,
        target_account: address,
        amount: u64
    }
    struct RepayEvent has store, drop {
        caller: address,
        target_account: address,
        amount: u64
    }
    struct StabilityPoolEventHandle has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
    }

    public entry fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        assert!(!is_pool_initialized(), error::invalid_state(EALREADY_INITIALIZED));

        stb_usdz::initialize(owner);
        move_to(owner, StabilityPool {
            left: coin::zero<USDZ>(),
            total_deposited: 0,
            collected_fee: coin::zero<USDZ>(),
        });
        move_to(owner, DistributionConfig {
            emission_per_sec: 0,
            last_updated: 0,
            index: 0,
        });
        move_to(owner, StabilityPoolEventHandle {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
        });
    }

    public fun is_pool_initialized(): bool {
        exists<StabilityPool>(permission::owner_address())
    }

    public(friend) fun init_pool<C>(owner: &signer) {
        move_to(owner, Balance<C> {
            total_borrowed: 0,
            uncollected_fee: 0
        });
    }

    public entry fun deposit(account: &signer, amount: u64) acquires StabilityPool, StabilityPoolEventHandle {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        if (!exists<UserDistribution>(signer::address_of(account))) {
            move_to(account, UserDistribution { 
                index: 0, 
                unclaimed: 0,
                deposited: 0,
            });
        };

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);

        pool_ref.total_deposited = pool_ref.total_deposited + (amount as u128);

        coin::merge(&mut pool_ref.left, coin::withdraw<USDZ>(account, amount));
        let account_addr = signer::address_of(account);
        if (!stb_usdz::is_account_registered(account_addr)) {
            stb_usdz::register(account);
        };
        stb_usdz::mint(account_addr, amount);
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(owner_address).deposit_event,
            DepositEvent {
                caller: account_addr,
                target_account: account_addr,
                amount
            }
        );
    }

    public entry fun withdraw(account: &signer, amount: u64) acquires StabilityPool, StabilityPoolEventHandle {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);
        assert!(pool_ref.total_deposited >= (amount as u128), error::invalid_argument(EEXCEED_REMAINING_AMOUNT));

        pool_ref.total_deposited = pool_ref.total_deposited - (amount as u128);
        let account_addr = signer::address_of(account);
        coin::deposit(account_addr, coin::extract(&mut pool_ref.left, amount));
        stb_usdz::burn(account, amount);
        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(owner_address).withdraw_event,
            WithdrawEvent {
                caller: account_addr,
                target_account: account_addr,
                amount
            }
        );
    }

    public(friend) entry fun borrow<C>(addr: address, amount: u64): coin::Coin<USDZ> acquires StabilityPool, Balance, StabilityPoolEventHandle {
        // TODO: 
        // if (!exists<UserDistribution>(signer::address_of(account))) {
        //     move_to(account, UserDistribution { index: 0 });
        // };
        let borrowed = borrow_internal<C>(amount);
        event::emit_event<BorrowEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(permission::owner_address()).borrow_event,
            BorrowEvent {
                caller: addr,
                target_account: addr,
                amount
            }
        );
        borrowed
    }
    fun borrow_internal<C>(amount: u64): coin::Coin<USDZ> acquires StabilityPool, Balance {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);
        let balance_ref = borrow_global_mut<Balance<C>>(owner_address);
        assert!(coin::value<USDZ>(&pool_ref.left) >= amount, error::invalid_argument(EEXCEED_REMAINING_AMOUNT));

        let fee = stability_fee_amount(amount);
        balance_ref.total_borrowed = balance_ref.total_borrowed + (amount as u128) + (fee as u128);
        balance_ref.uncollected_fee = balance_ref.uncollected_fee + fee;
        coin::extract<USDZ>(&mut pool_ref.left, amount)
    }
    public fun stability_fee_amount(borrow_amount: u64): u64 {
        borrow_amount * STABILITY_FEE / PRECISION
    }

    public(friend) entry fun repay<C>(account: &signer, amount: u64) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        repay_internal<C>(account, amount);
        let account_addr = signer::address_of(account);
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(permission::owner_address()).repay_event,
            RepayEvent {
                caller: account_addr,
                target_account: account_addr,
                amount: amount
            }
        );
    }
    fun repay_internal<C>(account: &signer, amount: u64) acquires StabilityPool, Balance {
        assert!(amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        let owner_address = permission::owner_address();
        let balance_ref = borrow_global_mut<Balance<C>>(owner_address);
        assert!((amount as u128) <= balance_ref.total_borrowed, error::invalid_argument(EINVALID_AMOUNT));

        balance_ref.total_borrowed = balance_ref.total_borrowed - (amount as u128);
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);
        if (balance_ref.uncollected_fee > 0) {
            // collect as fees at first
            if (balance_ref.uncollected_fee >= amount) {
                // all amount to fee
                balance_ref.uncollected_fee = balance_ref.uncollected_fee - amount;
                coin::merge<USDZ>(&mut pool_ref.collected_fee, coin::withdraw<USDZ>(account, amount));
            } else {
                // complete uncollected fee, and remaining amount to left
                let to_fee = balance_ref.uncollected_fee;
                let to_left = amount - to_fee;
                balance_ref.uncollected_fee = 0;
                coin::merge<USDZ>(&mut pool_ref.collected_fee, coin::withdraw<USDZ>(account, to_fee));
                coin::merge<USDZ>(&mut pool_ref.left, coin::withdraw<USDZ>(account, to_left));
            }
        } else {
            // all amount to left
            coin::merge<USDZ>(&mut pool_ref.left, coin::withdraw<USDZ>(account, amount));
        };
    }

    public entry fun claim_reward(account: &signer, amount: u64) acquires DistributionConfig, UserDistribution, StabilityPool {
        let pool_ref = borrow_global_mut<StabilityPool>(permission::owner_address());
        let user_ref = borrow_global<UserDistribution>(signer::address_of(account));
        let unclaimed_reward = user_ref.unclaimed;

        let staked_by_user = user_ref.deposited;
        let total_staked = pool_ref.total_deposited;
        let accrued_reward = update_user_asset(signer::address_of(account), staked_by_user, (total_staked as u64));
        if (accrued_reward != 0) {
            unclaimed_reward = unclaimed_reward + accrued_reward;
        };
        assert!(unclaimed_reward != 0, 0); // no claimable amount

        let amount_to_claim = if (amount > unclaimed_reward) unclaimed_reward else amount;
        let user_mut_ref = borrow_global_mut<UserDistribution>(signer::address_of(account));
        user_mut_ref.unclaimed = user_mut_ref.unclaimed - amount_to_claim;

        coin::deposit<USDZ>(signer::address_of(account), coin::extract(&mut pool_ref.collected_fee, amount_to_claim));
        // TODO: emit claim event
    }
    fun update_user_asset(addr: address, staked_by_user: u64, total_staked: u64): u64 acquires DistributionConfig, UserDistribution {
        let config_ref = borrow_global_mut<DistributionConfig>(permission::owner_address());
        let user_ref = borrow_global_mut<UserDistribution>(addr);
        let accrued_reward = 0;
        let new_index = update_asset_state(config_ref, total_staked);
        if (user_ref.index != new_index) {
            accrued_reward = rewards(staked_by_user, new_index, user_ref.index);
        };
        user_ref.index = new_index;
        accrued_reward
    }
    fun update_asset_state(config_ref: &mut DistributionConfig, total_staked: u64): u64 {        
        let old_index = config_ref.index;
        let last_updated = config_ref.last_updated;
        let now = timestamp::now_microseconds();
        if (now == last_updated) {
            return old_index
        };

        let new_index = asset_index(old_index, config_ref.emission_per_sec, last_updated, total_staked);
        if (new_index != old_index) {
            config_ref.index = new_index;
            // TODO: emit event
        };
        config_ref.last_updated = now;
        new_index
    }
    fun asset_index(current_index: u64, emission_per_sec: u64, last_updated: u64, total_balance: u64): u64 {
        let current_timestamp = timestamp::now_microseconds();
        let time_delta = current_timestamp - last_updated;
        emission_per_sec * time_delta * PRECISION / total_balance + current_index
    }
    fun rewards(user_balance: u64, reserve_index: u64, user_index: u64): u64 {
         user_balance * (reserve_index - user_index) / PRECISION
    }

    public fun left(): u128 acquires StabilityPool {
        (coin::value<USDZ>(&borrow_global<StabilityPool>(permission::owner_address()).left) as u128)
    }

    public fun collected_fee(): u64 acquires StabilityPool {
        coin::value<USDZ>(&borrow_global<StabilityPool>(permission::owner_address()).collected_fee)
    }


    public fun total_deposited(): u128 acquires StabilityPool {
        borrow_global<StabilityPool>(permission::owner_address()).total_deposited
    }

    public fun total_borrowed<C>(): u128 acquires Balance {
        borrow_global<Balance<C>>(permission::owner_address()).total_borrowed
    }

    public fun uncollected_fee<C>(): u64 acquires Balance {
        borrow_global<Balance<C>>(permission::owner_address()).uncollected_fee
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::test_coin::{Self,WETH};
    #[test_only]
    use leizd::usdz;
    #[test_only]
    use leizd::trove_manager;
    #[test(owner=@leizd)]
    public entry fun test_initialize(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        trove_manager::initialize(owner);

        initialize(owner);
        assert!(exists<StabilityPool>(owner_addr), 0);
        assert!(exists<DistributionConfig>(owner_addr), 0);
    }
    #[test(owner=@leizd)]
    #[expected_failure(abort_code = 196609)]
    public entry fun test_initialize_twice(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        trove_manager::initialize(owner);

        initialize(owner);
        initialize(owner);
    }
    #[test(account=@0x111)]
    #[expected_failure(abort_code = 1)]
    public entry fun test_initialize_without_owner(account: &signer) {
        initialize(account);
    }

    #[test_only]
    fun initialize_for_test_to_use_coin(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);

        trove_manager::initialize(owner);
        initialize(owner);

        test_coin::init_weth(owner);
        init_pool<WETH>(owner);
    }
    // for deposit
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_deposit_to_stability_pool(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);
                
        deposit(account, 400000);
        assert!(left() == 400000, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(usdz::balance_of(account_addr) == 600000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 400000, 0);

        assert!(event::counter<DepositEvent>(&borrow_global<StabilityPoolEventHandle>(signer::address_of(owner)).deposit_event) == 1, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    #[expected_failure(abort_code = 65538)]
    public entry fun test_deposit_to_stability_pool_with_no_amount(owner: &signer, account1: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);

        deposit(account1, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_deposit_to_stability_pool_with_not_enough_coin(owner: &signer, account1: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000);

        deposit(account1, 1001);
    }

    // for withdraw
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_from_stability_pool(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 1000000);
                
        deposit(account, 400000);

        withdraw(account, 300000);
        assert!(left() == 100000, 0);
        assert!(total_deposited() == 100000, 0);
        assert!(usdz::balance_of(account_addr) == 900000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 100000, 0);

        assert!(event::counter<WithdrawEvent>(&borrow_global<StabilityPoolEventHandle>(signer::address_of(owner)).withdraw_event) == 1, 0);
    }
    #[test(owner=@leizd,account1=@0x111)]
    #[expected_failure(abort_code = 65538)]
    public entry fun test_withdraw_from_stability_pool_with_no_amount(owner: &signer, account1: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(account1_addr);

        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);

        deposit(account1, 400000);
        withdraw(account1, 0);
    }
    #[test(owner=@leizd,account1=@0x111,account2=@0x222)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_withdraw_without_any_deposit(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        managed_coin::register<USDZ>(account1);
        managed_coin::register<USDZ>(account2);
        stb_usdz::register(account2);
        usdz::mint_for_test(account1_addr, 400000);
                
        deposit(account1, 400000);
        withdraw(account2, 300000);
    }
    #[test(owner=@leizd,account=@0x111)]
    public entry fun test_withdraw_with_amount_is_total_deposited(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 300000);

        deposit(account, 300000);
        withdraw(account, 300000);

        assert!(usdz::balance_of(account_addr) == 300000, 0);
        assert!(stb_usdz::balance_of(account_addr) == 0, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_withdraw_with_amount_is_greater_than_total_deposited(owner: &signer, account: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);

        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(account_addr, 300000);

        deposit(account, 300000);
        withdraw(account, 300001);
    }

    // for borrow
    #[test(owner=@leizd,account1=@0x111,account2=@0x222)]
    public entry fun test_borrow_from_stability_pool(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);
        managed_coin::register<USDZ>(account2);

        // check prerequisite
        assert!(stability_fee_amount(1000) == 5, 0); // 5%

        // execute
        deposit(account1, 400000);
        let borrowed = borrow<WETH>(account1_addr, 300000);
        coin::deposit(account2_addr, borrowed);

        // assertions
        assert!(total_deposited() == 400000, 0);
        assert!(left() == 100000, 0);
        assert!(total_borrowed<WETH>() == ((300000 + stability_fee_amount(300000)) as u128), 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
        assert!(usdz::balance_of(account2_addr) == 300000, 0);
        //// event
        assert!(event::counter<BorrowEvent>(&borrow_global<StabilityPoolEventHandle>(signer::address_of(owner)).borrow_event) == 1, 0);
    }
    #[test(owner=@leizd, account=@0x111)]
    #[expected_failure(abort_code = 65538)]
    public entry fun test_borrow_from_stability_pool_with_no_amount(owner: &signer, account: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);

        let coin = borrow<WETH>(account_addr, 0);

        // post_process
        coin::deposit(account_addr, coin);
    }
    #[test(owner=@leizd, account=@0x111)]
    #[expected_failure(abort_code = 65539)]
    public entry fun test_borrow_from_stability_pool_with_amount_is_greater_than_left(owner: &signer, account: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(account);

        let coin = borrow<WETH>(account_addr, 1001);

        // post_process
        coin::deposit(account_addr, coin);
    }

    // for repay
    #[test(owner=@leizd,account1=@0x111,account2=@0x222)]
    public entry fun test_repay_to_stability_pool(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);
        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);
        managed_coin::register<USDZ>(account2);

        // check prerequisite
        assert!(stability_fee_amount(1000) == 5, 0); // 5%

        // execute
        deposit(account1, 400000);
        let borrowed = borrow_internal<WETH>(300000);
        coin::deposit(account2_addr, borrowed);
        repay<WETH>(account2, 200000);

        // check
        assert!(left() == 298500, 0);
        assert!(collected_fee() == 1500, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(total_borrowed<WETH>() == 101500, 0);
        assert!(usdz::balance_of(account2_addr) == 100000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
        //// event
        assert!(event::counter<RepayEvent>(&borrow_global<StabilityPoolEventHandle>(signer::address_of(owner)).repay_event) == 1, 0);
    }
    //// validations
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65538)]
    public entry fun test_repay_with_zero_amount(owner: &signer, account: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        repay<WETH>(account, 0);
    }
    #[test(owner=@leizd,account=@0x111)]
    #[expected_failure(abort_code = 65538)]
    public entry fun test_repay_with_amount_is_greater_than_total_borrowed(owner: &signer, account: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let owner_addr = signer::address_of(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(account_addr);
        managed_coin::register<USDZ>(owner);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(owner_addr, 100);

        // execute
        deposit(owner, 50);
        let borrowed = borrow<WETH>(owner_addr, 50);
        repay<WETH>(account, 51);

        // post_process
        coin::deposit(owner_addr, borrowed);
    }
    //// calcuration
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222)]
    public entry fun test_repay_for_confirming_priority(owner: &signer, depositor: &signer, borrower: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        usdz::mint_for_test(depositor_addr, 10000);
        managed_coin::register<USDZ>(borrower);

        // check prerequisite
        assert!(stability_fee_amount(1000) == 5, 0); // 5%

        // execute
        //// add liquidity & borrow
        deposit(depositor, 10000);
        let borrowed = borrow_internal<WETH>(10000);
        coin::deposit(borrower_addr, borrowed);
        assert!(total_deposited() == 10000, 0);
        assert!(left() == 0, 0);
        assert!(collected_fee() == 0, 0);
        assert!(total_borrowed<WETH>() == 10050, 0);
        assert!(uncollected_fee<WETH>() == 50, 0);
        assert!(stb_usdz::balance_of(depositor_addr) == 10000, 0);
        assert!(usdz::balance_of(borrower_addr) == 10000, 0);
        //// repay (take a priority to uncollected_fee)
        repay_internal<WETH>(borrower, 49);
        assert!(left() == 0, 0);
        assert!(collected_fee() == 49, 0);
        assert!(total_borrowed<WETH>() == 10001, 0);
        assert!(uncollected_fee<WETH>() == 1, 0);
        assert!(usdz::balance_of(borrower_addr) == 9951, 0);
        ////// repay to remained uncollected_fee
        repay_internal<WETH>(borrower, 1);
        assert!(left() == 0, 0);
        assert!(collected_fee() == 50, 0);
        assert!(total_borrowed<WETH>() == 10000, 0);
        assert!(uncollected_fee<WETH>() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 9950, 0);
        //// repay to total_borrowed
        repay_internal<WETH>(borrower, 9900);
        assert!(left() == 9900, 0);
        assert!(collected_fee() == 50, 0);
        assert!(total_borrowed<WETH>() == 100, 0);
        assert!(uncollected_fee<WETH>() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 50, 0);
        ////// repay to remained total_borrowed
        usdz::mint_for_test(borrower_addr, 50);
        repay_internal<WETH>(borrower, 100);
        assert!(left() == 10000, 0);
        assert!(collected_fee() == 50, 0);
        assert!(total_borrowed<WETH>() == 0, 0);
        assert!(uncollected_fee<WETH>() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 0, 0);
    }
    #[test(owner=@leizd,depositor=@0x111,borrower=@0x222)]
    public entry fun test_repay_with_amount_between_total_borrowed_and_uncollected_fee(owner: &signer, depositor: &signer, borrower: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        initialize_for_test_to_use_coin(owner);
        let depositor_addr = signer::address_of(depositor);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(depositor_addr);
        account::create_account_for_test(borrower_addr);
        managed_coin::register<USDZ>(depositor);
        usdz::mint_for_test(depositor_addr, 10000);
        managed_coin::register<USDZ>(borrower);

        // check prerequisite
        assert!(stability_fee_amount(1000) == 5, 0); // 5%

        // execute
        //// add liquidity & borrow
        deposit(depositor, 10000);
        let borrowed = borrow_internal<WETH>(10000);
        coin::deposit(borrower_addr, borrowed);
        assert!(total_deposited() == 10000, 0);
        assert!(left() == 0, 0);
        assert!(collected_fee() == 0, 0);
        assert!(total_borrowed<WETH>() == 10050, 0);
        assert!(uncollected_fee<WETH>() == 50, 0);
        assert!(usdz::balance_of(borrower_addr) == 10000, 0);
        //// repay
        repay_internal<WETH>(borrower, 100);
        assert!(left() == 50, 0);
        assert!(collected_fee() == 50, 0);
        assert!(total_borrowed<WETH>() == 9950, 0);
        assert!(uncollected_fee<WETH>() == 0, 0);
        assert!(usdz::balance_of(borrower_addr) == 9900, 0);
    }

    // for related configuration
    #[test]
    fun test_stability_fee_amount() {
        assert!(stability_fee_amount(1000) == 5, 0);
        assert!(stability_fee_amount(543200) == 2716, 0);
        assert!(stability_fee_amount(100) == 0, 0); // TODO: round up
    }
}