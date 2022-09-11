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

    struct DepositEvent has store, drop {
        caller: address,
        depositor: address,
        amount: u64
    }

    struct WithdrawEvent has store, drop {
        caller: address,
        depositor: address,
        amount: u64
    }

    struct BorrowEvent has store, drop {
        caller: address,
        borrower: address,
        amount: u64
    }

    struct RepayEvent has store, drop {
        caller: address,
        repayer: address,
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
        if (!exists<UserDistribution>(signer::address_of(account))) {
            move_to(account, UserDistribution { 
                index: 0, 
                unclaimed: 0,
                deposited: 0,
            });
        };

        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);
        
        coin::merge(&mut pool_ref.left, coin::withdraw<USDZ>(account, amount));
        pool_ref.total_deposited = pool_ref.total_deposited + (amount as u128);
        if (!stb_usdz::is_account_registered(signer::address_of(account))) {
            stb_usdz::register(account);
        };
        stb_usdz::mint(signer::address_of(account), amount);
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(owner_address).deposit_event,
            DepositEvent {
                caller: signer::address_of(account),
                depositor: signer::address_of(account),
                amount
            }
        );
    }

    public entry fun withdraw(account: &signer, amount: u64) acquires StabilityPool, StabilityPoolEventHandle {
        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);

        coin::deposit(signer::address_of(account), coin::extract(&mut pool_ref.left, amount));
        pool_ref.total_deposited = pool_ref.total_deposited - (amount as u128);
        stb_usdz::burn(account, amount);
        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(owner_address).withdraw_event,
            WithdrawEvent {
                caller: signer::address_of(account),
                depositor: signer::address_of(account),
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
        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(permission::owner_address()).withdraw_event,
            WithdrawEvent {
                caller: addr,
                depositor: addr,
                amount
            }
        );
        borrowed
    }

    public fun stability_fee_amount(borrow_amount: u64): u64 {
        borrow_amount * STABILITY_FEE / PRECISION
    }

    fun borrow_internal<C>(amount: u64): coin::Coin<USDZ> acquires StabilityPool, Balance {
        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);
        let balance_ref = borrow_global_mut<Balance<C>>(owner_address);
        assert!(coin::value<USDZ>(&pool_ref.left) >= amount, 0);

        let fee = stability_fee_amount(amount);
        balance_ref.total_borrowed = balance_ref.total_borrowed + (amount as u128) + (fee as u128);
        balance_ref.uncollected_fee = balance_ref.uncollected_fee + fee;
        coin::extract<USDZ>(&mut pool_ref.left, amount)
    }

    public(friend) entry fun repay<C>(account: &signer, amount: u64) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        repay_internal<C>(account, amount);
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(permission::owner_address()).repay_event,
            RepayEvent {
                caller: signer::address_of(account),
                repayer: signer::address_of(account),
                amount: amount
            }
        );
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

    fun repay_internal<C>(account: &signer, amount: u64) acquires StabilityPool, Balance {
        let owner_address = permission::owner_address();
        let pool_ref = borrow_global_mut<StabilityPool>(owner_address);
        let balance_ref = borrow_global_mut<Balance<C>>(owner_address);

        if (balance_ref.uncollected_fee > 0) {
            // collect as fees at first
            if (balance_ref.uncollected_fee >= amount) {
                balance_ref.total_borrowed = balance_ref.total_borrowed - (amount as u128);
                balance_ref.uncollected_fee = balance_ref.uncollected_fee - amount;
                coin::merge<USDZ>(&mut pool_ref.collected_fee, coin::withdraw<USDZ>(account, amount));
            } else {
                let to_fee = balance_ref.uncollected_fee;
                let to_left = amount - to_fee;
                balance_ref.total_borrowed = balance_ref.total_borrowed - (amount as u128);
                balance_ref.uncollected_fee = 0;
                coin::merge<USDZ>(&mut pool_ref.collected_fee, coin::withdraw<USDZ>(account, to_fee));
                coin::merge<USDZ>(&mut pool_ref.left, coin::withdraw<USDZ>(account, to_left));
            }
        } else {
            balance_ref.total_borrowed = balance_ref.total_borrowed - (amount as u128);
            coin::merge<USDZ>(&mut pool_ref.left, coin::withdraw<USDZ>(account, amount));
        };
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
    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_to_stability_pool(owner: &signer, account1: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);

        test_coin::init_weth(owner);
        trove_manager::initialize(owner);
        managed_coin::register<WETH>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);

        initialize(owner); // stability pool
        init_pool<WETH>(owner);
                
        deposit(account1, 400000);
        assert!(left() == 400000, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(usdz::balance_of(account1_addr) == 600000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_from_stability_pool(owner: &signer, account1: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);

        test_coin::init_weth(owner);
        trove_manager::initialize(owner);
        managed_coin::register<WETH>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);

        initialize(owner); // stability pool
        init_pool<WETH>(owner);
                
        deposit(account1, 400000);

        withdraw(account1, 300000);
        assert!(left() == 100000, 0);
        assert!(total_deposited() == 100000, 0);
        assert!(usdz::balance_of(account1_addr) == 900000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 100000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure]
    public entry fun test_withdraw_without_any_deposit(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        test_coin::init_weth(owner);
        trove_manager::initialize(owner);
        managed_coin::register<WETH>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);

        initialize(owner); // stability pool
        init_pool<WETH>(owner);
                
        deposit(account1, 400000);
        withdraw(account2, 300000);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_from_stability_pool(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        test_coin::init_weth(owner);
        trove_manager::initialize(owner);
        managed_coin::register<WETH>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        managed_coin::register<WETH>(account2);
        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);
        managed_coin::register<USDZ>(account2);

        initialize(owner); // stability pool
        init_pool<WETH>(owner);
                
        deposit(account1, 400000);
        let borrowed = borrow_internal<WETH>(300000);
        coin::deposit(account2_addr, borrowed);
        assert!(left() == 100000, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(total_borrowed<WETH>() == 301500, 0);
        assert!(usdz::balance_of(account2_addr) == 300000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_to_stability_pool(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        test_coin::init_weth(owner);
        trove_manager::initialize(owner);
        managed_coin::register<WETH>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        managed_coin::register<WETH>(account2);
        managed_coin::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);
        managed_coin::register<USDZ>(account2);

        initialize(owner); // stability pool
        init_pool<WETH>(owner);
                
        deposit(account1, 400000);
        let borrowed = borrow_internal<WETH>(300000);
        coin::deposit(account2_addr, borrowed);
        // let repayed = coin::withdraw<USDZ>(&account2, 200000);
        repay_internal<WETH>(account2, 200000);
        assert!(left() == 298500, 0);
        assert!(collected_fee() == 1500, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(total_borrowed<WETH>() == 101500, 0);
        assert!(usdz::balance_of(account2_addr) == 100000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
    }
}